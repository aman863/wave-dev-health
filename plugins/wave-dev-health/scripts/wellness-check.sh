#!/bin/bash
# Wave Dev Health — Background wellness checker
# Runs on EVERY UserPromptSubmit. Stdout is injected as system context to Claude.
#
# SIGNALS WE READ (every prompt):
#   1. STDIN        — user's prompt text (mood, frustration, debugging keywords)
#   2. Clock        — time of day, day of week, date
#   3. State files  — session history, streaks, last nudge, breaks
#   4. Environment  — CLAUDE_PROJECT_DIR (project switching detection)
#   5. Prompt meta  — length, velocity, gaps between prompts
#
# WHAT WE OUTPUT (when nudge fires):
#   A structured [WAVE_HEALTH_NUDGE] block injected into Claude's context.
#   Claude reads it and weaves the nudge into its response.

set -euo pipefail

STATE_DIR="$HOME/.wave-dev-health"
STATE_FILE="$STATE_DIR/state.json"
TIPS_FILE="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$0")")}/src/tips.json"
ENERGY_FILE="$STATE_DIR/energy.json"
CONFIG_FILE="$STATE_DIR/config.json"
STREAK_FILE="$STATE_DIR/streak.json"
MOOD_FILE="$STATE_DIR/mood_log.jsonl"

# ── Tier intervals ───────────────────────────────────────────────
TIER1_INTERVAL=1200   # 20 min — eyes, breathing (micro)
TIER2_INTERVAL=2100   # 35 min — hydration, posture (light)
TIER3_INTERVAL=3000   # 50 min — stretch, movement (full)
TIER4_INTERVAL=5400   # 90 min — full break (stand up, walk)

TODAY=$(date +%Y-%m-%d)
NOW=$(date +%s)
HOUR=$(date +%H)
DOW=$(date +%u)  # 1=Mon, 7=Sun

mkdir -p "$STATE_DIR/sessions"

# ── Read user's prompt from stdin ────────────────────────────────
# The hook receives the user's prompt text via stdin.
PROMPT_TEXT=""
if [ -t 0 ]; then
  PROMPT_TEXT=""
else
  PROMPT_TEXT=$(head -c 2000 2>/dev/null || true)  # Cap at 2KB for speed
fi
PROMPT_LEN=${#PROMPT_TEXT}
PROMPT_LOWER=$(echo "$PROMPT_TEXT" | tr '[:upper:]' '[:lower:]')

# ── Analyze prompt for mood signals ──────────────────────────────
MOOD="neutral"
FRUSTRATION_SCORE=0
IS_DEBUGGING="false"
IS_STUCK="false"

# Frustration signals (from actual session analysis patterns)
if echo "$PROMPT_LOWER" | grep -qE '(not working|still broken|same error|why is|what.s wrong|can.t figure|still not|keeps failing|again!|wtf|ugh|help me)'; then
  FRUSTRATION_SCORE=3
  MOOD="frustrated"
fi
if echo "$PROMPT_LOWER" | grep -qE '(error|bug|broken|crash|fails|failing|exception|undefined|null|typeerror|referenceerror)'; then
  FRUSTRATION_SCORE=$((FRUSTRATION_SCORE + 1))
  IS_DEBUGGING="true"
  if [ "$MOOD" = "neutral" ]; then MOOD="debugging"; fi
fi
if echo "$PROMPT_LOWER" | grep -qE '(tried everything|no idea|stuck|confused|lost|going in circles|been at this)'; then
  FRUSTRATION_SCORE=$((FRUSTRATION_SCORE + 2))
  IS_STUCK="true"
  MOOD="stuck"
fi

# Positive signals
if echo "$PROMPT_LOWER" | grep -qE '(ship|deploy|push|commit|merge|looks good|works|done|perfect|great|let.s go)'; then
  if [ "$MOOD" = "neutral" ]; then MOOD="shipping"; fi
fi
if echo "$PROMPT_LOWER" | grep -qE '(add|create|implement|build|new feature|write|generate|design)'; then
  if [ "$MOOD" = "neutral" ]; then MOOD="building"; fi
fi

# Short terse prompts after long session = possible frustration
if [ "$PROMPT_LEN" -lt 20 ] && [ "$PROMPT_LEN" -gt 0 ]; then
  FRUSTRATION_SCORE=$((FRUSTRATION_SCORE + 1))
fi

# ── Read config ──────────────────────────────────────────────────
DISABLED="false"
CUSTOM_INTERVAL=""
if [ -f "$CONFIG_FILE" ]; then
  DISABLED=$(grep -o '"disabled":[a-z]*' "$CONFIG_FILE" 2>/dev/null | grep -o 'true' || echo "false")
  CUSTOM_INTERVAL=$(grep -o '"nudge_interval":[0-9]*' "$CONFIG_FILE" 2>/dev/null | grep -o '[0-9]*' || true)
fi
if [ "$DISABLED" = "true" ]; then exit 0; fi
if [ -n "$CUSTOM_INTERVAL" ] && [ "$CUSTOM_INTERVAL" -gt 0 ] 2>/dev/null; then
  TIER3_INTERVAL=$CUSTOM_INTERVAL
fi

# ── Read state ───────────────────────────────────────────────────
LAST_NUDGE=0; LAST_TIP_INDEX=0; LAST_NUDGE_DATE=""; SESSION_START=0
LAST_BREAK=0; TODAY_NUDGES=0; TODAY_BREAKS=0; PROMPT_COUNT=0
LAST_PROJECT=""; LAST_PROMPT_TS=0; CONSECUTIVE_DAYS=0
FRUSTRATED_STREAK=0; TOTAL_SESSIONS=0

if [ -f "$STATE_FILE" ]; then
  LAST_NUDGE=$(grep -o '"last_nudge":[0-9]*' "$STATE_FILE" 2>/dev/null | grep -o '[0-9]*' || echo "0")
  LAST_TIP_INDEX=$(grep -o '"last_tip_index":[0-9]*' "$STATE_FILE" 2>/dev/null | grep -o '[0-9]*' || echo "0")
  LAST_NUDGE_DATE=$(grep -o '"last_nudge_date":"[^"]*"' "$STATE_FILE" 2>/dev/null | grep -o '"[^"]*"$' | tr -d '"' || echo "")
  SESSION_START=$(grep -o '"session_start":[0-9]*' "$STATE_FILE" 2>/dev/null | grep -o '[0-9]*' || echo "0")
  LAST_BREAK=$(grep -o '"last_break":[0-9]*' "$STATE_FILE" 2>/dev/null | grep -o '[0-9]*' || echo "0")
  PROMPT_COUNT=$(grep -o '"prompt_count":[0-9]*' "$STATE_FILE" 2>/dev/null | grep -o '[0-9]*' || echo "0")
  LAST_PROJECT=$(grep -o '"last_project":"[^"]*"' "$STATE_FILE" 2>/dev/null | grep -o '"[^"]*"$' | tr -d '"' || echo "")
  LAST_PROMPT_TS=$(grep -o '"last_prompt_ts":[0-9]*' "$STATE_FILE" 2>/dev/null | grep -o '[0-9]*' || echo "0")
  FRUSTRATED_STREAK=$(grep -o '"frustrated_streak":[0-9]*' "$STATE_FILE" 2>/dev/null | grep -o '[0-9]*' || echo "0")
  if [ "$LAST_NUDGE_DATE" = "$TODAY" ]; then
    TODAY_NUDGES=$(grep -o '"today_nudges":[0-9]*' "$STATE_FILE" 2>/dev/null | grep -o '[0-9]*' || echo "0")
    TODAY_BREAKS=$(grep -o '"today_breaks":[0-9]*' "$STATE_FILE" 2>/dev/null | grep -o '[0-9]*' || echo "0")
  fi
fi

if [ "$SESSION_START" -eq 0 ]; then SESSION_START=$NOW; fi
PROMPT_COUNT=$((PROMPT_COUNT + 1))

# ── Derived signals ──────────────────────────────────────────────
ELAPSED_SINCE_NUDGE=$((NOW - LAST_NUDGE))
ELAPSED_SINCE_BREAK=$((NOW - LAST_BREAK))
SESSION_MINUTES=$(( (NOW - SESSION_START) / 60 ))

# Prompt gap (time since last prompt)
PROMPT_GAP=0
if [ "$LAST_PROMPT_TS" -gt 0 ]; then
  PROMPT_GAP=$((NOW - LAST_PROMPT_TS))
fi

# Project switching detection
CURRENT_PROJECT="${CLAUDE_PROJECT_DIR:-unknown}"
PROJECT_SWITCHED="false"
if [ -n "$LAST_PROJECT" ] && [ "$LAST_PROJECT" != "$CURRENT_PROJECT" ] && [ "$LAST_PROJECT" != "unknown" ]; then
  PROJECT_SWITCHED="true"
fi

# Consecutive days tracking
if [ -f "$STREAK_FILE" ]; then
  CONSECUTIVE_DAYS=$(grep -o '"consecutive_days":[0-9]*' "$STREAK_FILE" 2>/dev/null | grep -o '[0-9]*' || echo "0")
  LAST_ACTIVE_DATE=$(grep -o '"last_active_date":"[^"]*"' "$STREAK_FILE" 2>/dev/null | grep -o '"[^"]*"$' | tr -d '"' || echo "")
  if [ "$LAST_ACTIVE_DATE" = "$TODAY" ]; then
    : # already counted today
  else
    # Check if yesterday was active
    YESTERDAY=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d "yesterday" +%Y-%m-%d 2>/dev/null || echo "")
    if [ "$LAST_ACTIVE_DATE" = "$YESTERDAY" ]; then
      CONSECUTIVE_DAYS=$((CONSECUTIVE_DAYS + 1))
    else
      CONSECUTIVE_DAYS=1  # streak broken
    fi
    # Update streak file
    TMPFILE=$(mktemp "$STATE_DIR/streak.XXXXXX")
    echo "{\"consecutive_days\":$CONSECUTIVE_DAYS,\"last_active_date\":\"$TODAY\"}" > "$TMPFILE"
    mv "$TMPFILE" "$STREAK_FILE"
  fi
else
  CONSECUTIVE_DAYS=1
  echo "{\"consecutive_days\":1,\"last_active_date\":\"$TODAY\"}" > "$STREAK_FILE"
fi

# Frustrated streak (consecutive frustrated prompts)
if [ "$FRUSTRATION_SCORE" -ge 2 ]; then
  FRUSTRATED_STREAK=$((FRUSTRATED_STREAK + 1))
else
  FRUSTRATED_STREAK=0
fi

# Session returned after long gap (>30 min gap = "welcome back")
RETURNING_AFTER_BREAK="false"
if [ "$PROMPT_GAP" -ge 1800 ] && [ "$PROMPT_GAP" -lt 28800 ]; then
  RETURNING_AFTER_BREAK="true"
fi

# ── Log mood (append-only, for profile analysis) ─────────────────
# Only log every 5th prompt to keep file small
if [ $((PROMPT_COUNT % 5)) -eq 0 ] && [ "$PROMPT_LEN" -gt 0 ]; then
  echo "{\"ts\":$NOW,\"mood\":\"$MOOD\",\"frust\":$FRUSTRATION_SCORE,\"len\":$PROMPT_LEN,\"proj\":\"$(basename "$CURRENT_PROJECT")\"}" >> "$MOOD_FILE" 2>/dev/null || true
  # Rotate mood log (keep last 500 entries)
  if [ -f "$MOOD_FILE" ]; then
    LINES=$(wc -l < "$MOOD_FILE" 2>/dev/null | tr -d ' ')
    if [ "$LINES" -gt 500 ]; then
      tail -300 "$MOOD_FILE" > "$MOOD_FILE.tmp" && mv "$MOOD_FILE.tmp" "$MOOD_FILE"
    fi
  fi
fi

# ── Smart nudge decision ─────────────────────────────────────────
SHOULD_NUDGE="false"
NUDGE_REASON=""
NUDGE_TIER=0

# ── Tier selection: highest due tier wins ─────────────────────────

# Tier 4: Full break (90 min without any break)
if [ "$ELAPSED_SINCE_BREAK" -ge "$TIER4_INTERVAL" ] && [ "$ELAPSED_SINCE_NUDGE" -ge "$TIER1_INTERVAL" ]; then
  SHOULD_NUDGE="true"; NUDGE_TIER=4; NUDGE_REASON="full_break"
fi

# Tier 3: Full nudge (50 min since last nudge)
if [ "$NUDGE_TIER" -lt 3 ] && [ "$ELAPSED_SINCE_NUDGE" -ge "$TIER3_INTERVAL" ]; then
  SHOULD_NUDGE="true"; NUDGE_TIER=3; NUDGE_REASON="regular_interval"
fi

# Tier 2: Light nudge (35 min)
if [ "$NUDGE_TIER" -lt 2 ] && [ "$ELAPSED_SINCE_NUDGE" -ge "$TIER2_INTERVAL" ]; then
  SHOULD_NUDGE="true"; NUDGE_TIER=2; NUDGE_REASON="light_reminder"
fi

# Tier 1: Micro-nudge (20 min)
if [ "$NUDGE_TIER" -lt 1 ] && [ "$ELAPSED_SINCE_NUDGE" -ge "$TIER1_INTERVAL" ]; then
  SHOULD_NUDGE="true"; NUDGE_TIER=1; NUDGE_REASON="micro_nudge"
fi

# ── Context signals: promote tier or trigger early ────────────────

# Frustration detected — if frustrated for 3+ consecutive prompts, promote
if [ "$FRUSTRATED_STREAK" -ge 3 ] && [ "$ELAPSED_SINCE_NUDGE" -ge "$TIER1_INTERVAL" ]; then
  SHOULD_NUDGE="true"
  if [ "$NUDGE_TIER" -lt 3 ]; then NUDGE_TIER=3; fi
  NUDGE_REASON="frustration_detected"
fi

# Stuck signal — user explicitly says they're stuck
if [ "$IS_STUCK" = "true" ] && [ "$ELAPSED_SINCE_NUDGE" -ge "$TIER1_INTERVAL" ]; then
  SHOULD_NUDGE="true"
  if [ "$NUDGE_TIER" -lt 3 ]; then NUDGE_TIER=3; fi
  NUDGE_REASON="user_stuck"
fi

# High intensity (30+ prompts since last nudge)
if [ "$PROMPT_COUNT" -ge 30 ] && [ "$ELAPSED_SINCE_NUDGE" -ge "$TIER1_INTERVAL" ]; then
  SHOULD_NUDGE="true"
  if [ "$NUDGE_TIER" -lt 2 ]; then NUDGE_TIER=2; fi
  NUDGE_REASON="high_intensity"
fi

# Late night (after 11pm or before 5am)
if [ "$HOUR" -ge 23 ] || [ "$HOUR" -lt 5 ]; then
  if [ "$ELAPSED_SINCE_NUDGE" -ge "$TIER1_INTERVAL" ] && [ "$NUDGE_TIER" -ge 1 ]; then
    if [ "$NUDGE_TIER" -lt 2 ]; then NUDGE_TIER=2; fi
    NUDGE_REASON="late_night"
  fi
fi

# Deep night (2am-4am) — always promote to Tier 3
if [ "$HOUR" -ge 2 ] && [ "$HOUR" -lt 5 ]; then
  if [ "$ELAPSED_SINCE_NUDGE" -ge "$TIER1_INTERVAL" ] && [ "$NUDGE_TIER" -ge 1 ]; then
    if [ "$NUDGE_TIER" -lt 3 ]; then NUDGE_TIER=3; fi
    NUDGE_REASON="deep_night"
  fi
fi

# Break deficit (3+ nudges, 0 breaks today)
if [ "$TODAY_NUDGES" -ge 3 ] && [ "$TODAY_BREAKS" -eq 0 ] && [ "$ELAPSED_SINCE_NUDGE" -ge "$TIER1_INTERVAL" ]; then
  SHOULD_NUDGE="true"
  if [ "$NUDGE_TIER" -lt 3 ]; then NUDGE_TIER=3; fi
  NUDGE_REASON="break_deficit"
fi

# Burnout signal: 7+ consecutive coding days
BURNOUT_WARNING="false"
if [ "$CONSECUTIVE_DAYS" -ge 7 ] && [ "$TODAY_NUDGES" -eq 0 ]; then
  BURNOUT_WARNING="true"
fi

# Project switch detected — always worth a micro-nudge
if [ "$PROJECT_SWITCHED" = "true" ] && [ "$ELAPSED_SINCE_NUDGE" -ge "$TIER1_INTERVAL" ]; then
  SHOULD_NUDGE="true"
  if [ "$NUDGE_TIER" -lt 1 ]; then NUDGE_TIER=1; fi
  NUDGE_REASON="project_switch"
fi

# ── Not time yet? Update state and exit ──────────────────────────
if [ "$SHOULD_NUDGE" = "false" ]; then
  TMPFILE=$(mktemp "$STATE_DIR/state.XXXXXX")
  cat > "$TMPFILE" <<EOJSON
{"version":2,"last_nudge":$LAST_NUDGE,"last_tip_index":$LAST_TIP_INDEX,"last_nudge_date":"$LAST_NUDGE_DATE","session_start":$SESSION_START,"today_nudges":$TODAY_NUDGES,"today_breaks":$TODAY_BREAKS,"last_break":$LAST_BREAK,"prompt_count":$PROMPT_COUNT,"last_project":"$CURRENT_PROJECT","last_prompt_ts":$NOW,"frustrated_streak":$FRUSTRATED_STREAK}
EOJSON
  mv "$TMPFILE" "$STATE_FILE"
  exit 0
fi

# ── Select tip matching tier ─────────────────────────────────────
TIP_RESULT=$(python3 -c "
import json, random
try:
    tips = json.load(open('$TIPS_FILE'))
    tier_tips = [t for t in tips if t.get('tier', 3) == $NUDGE_TIER]
    if not tier_tips:
        tier_tips = tips
    tip = random.choice(tier_tips)
    print(tip['text'])
    print('---SEP---')
    print(tip.get('category', 'general'))
except:
    print('Take a moment to stretch and breathe. Your body will thank you.')
    print('---SEP---')
    print('general')
" 2>/dev/null || echo "Take a moment to stretch and breathe. Your body will thank you.
---SEP---
general")

TIP_TEXT=$(echo "$TIP_RESULT" | head -1)
TIP_CATEGORY=$(echo "$TIP_RESULT" | tail -1)

TODAY_NUDGES=$((TODAY_NUDGES + 1))

# ── Build output ─────────────────────────────────────────────────
OUTPUT="[WAVE_HEALTH_NUDGE]
tier: ${NUDGE_TIER}
session_duration_min: ${SESSION_MINUTES}
nudge_reason: ${NUDGE_REASON}
mood: ${MOOD}
tip_category: ${TIP_CATEGORY}
tip: ${TIP_TEXT}
today_nudges: ${TODAY_NUDGES}
today_breaks: ${TODAY_BREAKS}
consecutive_coding_days: ${CONSECUTIVE_DAYS}
prompt_count_since_nudge: ${PROMPT_COUNT}"

# Conditional fields
if [ "$FRUSTRATION_SCORE" -ge 2 ]; then
  OUTPUT="${OUTPUT}
frustration_level: high
frustrated_prompts_in_row: ${FRUSTRATED_STREAK}"
fi

if [ "$IS_STUCK" = "true" ]; then
  OUTPUT="${OUTPUT}
user_is_stuck: true"
fi

if [ "$PROJECT_SWITCHED" = "true" ]; then
  OUTPUT="${OUTPUT}
project_switched: true
previous_project: $(basename "$LAST_PROJECT")
current_project: $(basename "$CURRENT_PROJECT")"
fi

if [ "$RETURNING_AFTER_BREAK" = "true" ]; then
  BREAK_DURATION_MIN=$((PROMPT_GAP / 60))
  OUTPUT="${OUTPUT}
returning_after_break: true
break_duration_min: ${BREAK_DURATION_MIN}"
fi

if [ "$BURNOUT_WARNING" = "true" ]; then
  OUTPUT="${OUTPUT}
burnout_warning: true
consecutive_days: ${CONSECUTIVE_DAYS}"
fi

# Energy prompt (first nudge of new day)
if [ "$LAST_NUDGE_DATE" != "$TODAY" ]; then
  HAS_ENERGY_TODAY="false"
  if [ -f "$ENERGY_FILE" ]; then
    HAS_ENERGY_TODAY=$(grep -c "\"$TODAY\"" "$ENERGY_FILE" 2>/dev/null | grep -v '^0$' > /dev/null 2>&1 && echo "true" || echo "false")
  fi
  if [ "$HAS_ENERGY_TODAY" = "false" ]; then
    OUTPUT="${OUTPUT}
energy_prompt: true"
  fi
fi

OUTPUT="${OUTPUT}
snooze_command: /pulse snooze 15m
break_command: /pulse break
[/WAVE_HEALTH_NUDGE]"

echo "$OUTPUT"

# ── Update state ─────────────────────────────────────────────────
TMPFILE=$(mktemp "$STATE_DIR/state.XXXXXX")
cat > "$TMPFILE" <<EOJSON
{"version":2,"last_nudge":$NOW,"last_tip_index":$LAST_TIP_INDEX,"last_nudge_date":"$TODAY","session_start":$SESSION_START,"today_nudges":$TODAY_NUDGES,"today_breaks":$TODAY_BREAKS,"last_break":$LAST_BREAK,"prompt_count":0,"last_project":"$CURRENT_PROJECT","last_prompt_ts":$NOW,"frustrated_streak":$FRUSTRATED_STREAK}
EOJSON
mv "$TMPFILE" "$STATE_FILE"

exit 0
