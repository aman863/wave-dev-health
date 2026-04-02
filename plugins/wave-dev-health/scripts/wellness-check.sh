#!/bin/bash
# Wave Dev Health — Wellness checker + companion
# Runs on EVERY UserPromptSubmit. Stdout injected as system context to Claude.
#
# OUTPUT MODES (priority order):
#   1. [WAVE_HEALTH_NUDGE] — Timer-based health tip (shows FIRST in response)
#   2. [WAVE_COMPANION]    — Lightweight emotional/session touch (1-2 lines, shows FIRST)
#   3. Silent              — No output (most prompts)

set -euo pipefail

STATE_DIR="$HOME/.wave-dev-health"
STATE_FILE="$STATE_DIR/state.json"
TIPS_FILE="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$0")")}/src/tips.json"
ENERGY_FILE="$STATE_DIR/energy.json"
CONFIG_FILE="$STATE_DIR/config.json"
STREAK_FILE="$STATE_DIR/streak.json"
MOOD_FILE="$STATE_DIR/mood_log.jsonl"

# ── Tier intervals ───────────────────────────────────────────────
# ── Debug mode ───────────────────────────────────────────────────
# To test:  touch ~/.wave-dev-health/debug
# To stop:  rm ~/.wave-dev-health/debug
# Compresses all timers to seconds so nudges fire on every 2nd-5th prompt.
DEBUG_MODE="false"
if [ -f "$STATE_DIR/debug" ]; then
  DEBUG_MODE="true"
fi

if [ "$DEBUG_MODE" = "true" ]; then
  TIER1_INTERVAL=5      # 5 sec
  TIER2_INTERVAL=10     # 10 sec
  TIER3_INTERVAL=15     # 15 sec
  TIER4_INTERVAL=20     # 20 sec
  COMPANION_COOLDOWN=3
  MOOD_SUPPORT_COOLDOWN=5
  SUCCESS_COOLDOWN=3
else
  TIER1_INTERVAL=1200   # 20 min — eyes, breathing (micro)
  TIER2_INTERVAL=2100   # 35 min — hydration, posture (light)
  TIER3_INTERVAL=3000   # 50 min — stretch, movement (full)
  TIER4_INTERVAL=5400   # 90 min — full break (stand up, walk)
  COMPANION_COOLDOWN=300       # 5 min between companion touches
  MOOD_SUPPORT_COOLDOWN=600    # 10 min between frustration support
  SUCCESS_COOLDOWN=300         # 5 min between success celebrations
fi

TODAY=$(date +%Y-%m-%d)
NOW=$(date +%s)
HOUR=$(date +%H)
DOW=$(date +%u)  # 1=Mon, 7=Sun

mkdir -p "$STATE_DIR/sessions"

# ── Read user's prompt from stdin ────────────────────────────────
PROMPT_TEXT=""
if [ -t 0 ]; then
  PROMPT_TEXT=""
else
  PROMPT_TEXT=$(head -c 2000 2>/dev/null || true)
fi
PROMPT_LEN=${#PROMPT_TEXT}
PROMPT_LOWER=$(echo "$PROMPT_TEXT" | tr '[:upper:]' '[:lower:]')

# ── Analyze prompt for mood signals ──────────────────────────────
MOOD="neutral"
FRUSTRATION_SCORE=0
IS_DEBUGGING="false"
IS_STUCK="false"
IS_SUCCESS="false"

# Frustration signals
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

# Success signals
if echo "$PROMPT_LOWER" | grep -qE '(it works|fixed|nailed it|tests pass|all green|shipped|deployed|merged|done!|perfect|looks good|let.s go|lgtm|nice)'; then
  IS_SUCCESS="true"
  if [ "$MOOD" = "neutral" ]; then MOOD="shipping"; fi
fi
if echo "$PROMPT_LOWER" | grep -qE '(add|create|implement|build|new feature|write|generate|design)'; then
  if [ "$MOOD" = "neutral" ]; then MOOD="building"; fi
fi

# Short terse prompts after long session = possible frustration
if [ "$PROMPT_LEN" -lt 20 ] && [ "$PROMPT_LEN" -gt 0 ]; then
  FRUSTRATION_SCORE=$((FRUSTRATION_SCORE + 1))
fi

# ── Activity detection ───────────────────────────────────────────
ACTIVITY="general"
BODY_FOCUS="general"

if echo "$PROMPT_LOWER" | grep -qE '(test|spec|assert|expect|coverage|mock|fixture|jest|vitest|bats|pytest)'; then
  ACTIVITY="testing"; BODY_FOCUS="eyes"
fi
if echo "$PROMPT_LOWER" | grep -qE '(review|read|check|look at|what does|explain|understand|diff|pr )'; then
  ACTIVITY="reviewing"; BODY_FOCUS="eyes"
fi
if echo "$PROMPT_LOWER" | grep -qE '(write|implement|create|add.*function|add.*component|refactor|rename|extract|move)'; then
  ACTIVITY="writing"; BODY_FOCUS="wrists"
fi
if [ "$IS_DEBUGGING" = "true" ] || echo "$PROMPT_LOWER" | grep -qE '(debug|fix|trace|log|inspect|stack|breakpoint|print)'; then
  ACTIVITY="debugging"; BODY_FOCUS="eyes"
fi
if echo "$PROMPT_LOWER" | grep -qE '(deploy|docker|kubernetes|ci|cd|pipeline|build|config|env|nginx|server|aws|terraform)'; then
  ACTIVITY="devops"; BODY_FOCUS="back"
fi
if echo "$PROMPT_LOWER" | grep -qE '(css|style|design|layout|color|font|padding|margin|responsive|animation|ui|ux)'; then
  ACTIVITY="design"; BODY_FOCUS="neck"
fi
if echo "$PROMPT_LOWER" | grep -qE '(database|query|sql|migration|schema|table|data|csv|json|api|fetch|request)'; then
  ACTIVITY="data"; BODY_FOCUS="eyes"
fi

# ── Rolling activity window ──────────────────────────────────────
ACTIVITY_LOG="$STATE_DIR/activity.log"
if [ "$PROMPT_LEN" -gt 0 ]; then
  echo "$NOW $ACTIVITY $BODY_FOCUS" >> "$ACTIVITY_LOG" 2>/dev/null || true
  if [ -f "$ACTIVITY_LOG" ]; then
    ALINES=$(wc -l < "$ACTIVITY_LOG" 2>/dev/null | tr -d ' ')
    if [ "$ALINES" -gt 20 ]; then
      tail -20 "$ACTIVITY_LOG" > "$ACTIVITY_LOG.tmp" && mv "$ACTIVITY_LOG.tmp" "$ACTIVITY_LOG"
    fi
  fi
fi

DOMINANT_FOCUS=""
if [ -f "$ACTIVITY_LOG" ]; then
  DOMINANT_FOCUS=$(tail -5 "$ACTIVITY_LOG" 2>/dev/null | awk '{print $3}' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
fi
if [ -n "$DOMINANT_FOCUS" ] && [ "$DOMINANT_FOCUS" != "" ]; then
  BODY_FOCUS="$DOMINANT_FOCUS"
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

# ── Read state (single Python call, handles any JSON format) ─────
LAST_NUDGE=0; LAST_TIP_INDEX=0; LAST_NUDGE_DATE=""; SESSION_START=0
LAST_BREAK=0; TODAY_NUDGES=0; TODAY_BREAKS=0; PROMPT_COUNT=0
LAST_PROJECT=""; LAST_PROMPT_TS=0; FRUSTRATED_STREAK=0
LAST_BODY_AREA=""; CLAUDE_DONE_TS=0
SESSION_GREETED="false"; LAST_COMPANION_TS=0; LAST_MILESTONE_MIN=0
LAST_LATE_HOUR=-1; LAST_SUCCESS_TS=0; LAST_MOOD_SUPPORT_TS=0
STREAK_SHOWN=0; PREV_MOOD=""

if [ -f "$STATE_FILE" ]; then
  eval "$(python3 -c "
import json, sys
today = '$TODAY'
try:
    d = json.load(open('$STATE_FILE'))
except:
    sys.exit(0)

def p(var, val):
    if isinstance(val, bool):
        print(f\"{var}={'true' if val else 'false'}\")
    elif isinstance(val, str):
        safe = val.replace('\\\\', '').replace('\"', '').replace('\`', '').replace('\$', '')
        print(f'{var}=\"{safe}\"')
    else:
        print(f'{var}={val}')

p('LAST_NUDGE', d.get('last_nudge', 0))
p('LAST_TIP_INDEX', d.get('last_tip_index', 0))
p('LAST_NUDGE_DATE', d.get('last_nudge_date', ''))
p('SESSION_START', d.get('session_start', 0))
p('LAST_BREAK', d.get('last_break', 0))
p('PROMPT_COUNT', d.get('prompt_count', 0))
p('LAST_PROJECT', d.get('last_project', ''))
p('LAST_PROMPT_TS', d.get('last_prompt_ts', 0))
p('FRUSTRATED_STREAK', d.get('frustrated_streak', 0))
p('LAST_BODY_AREA', d.get('last_body_area', ''))
p('CLAUDE_DONE_TS', d.get('claude_done_ts', 0))
p('SESSION_GREETED', d.get('session_greeted', False))
p('LAST_COMPANION_TS', d.get('last_companion_ts', 0))
p('LAST_MILESTONE_MIN', d.get('last_milestone_min', 0))
p('LAST_LATE_HOUR', d.get('last_late_hour', -1))
p('LAST_SUCCESS_TS', d.get('last_success_ts', 0))
p('LAST_MOOD_SUPPORT_TS', d.get('last_mood_support_ts', 0))
p('STREAK_SHOWN', d.get('streak_shown', 0))
p('PREV_MOOD', d.get('prev_mood', ''))

# Daily counters: only carry forward if same day
nd = d.get('last_nudge_date', '')
if nd == today:
    p('TODAY_NUDGES', d.get('today_nudges', 0))
    p('TODAY_BREAKS', d.get('today_breaks', 0))
" 2>/dev/null)" || true
fi

# Safety: ensure all numeric vars are valid integers (guards against corrupt state)
LAST_NUDGE=${LAST_NUDGE:-0}; SESSION_START=${SESSION_START:-0}
LAST_BREAK=${LAST_BREAK:-0}; TODAY_NUDGES=${TODAY_NUDGES:-0}
TODAY_BREAKS=${TODAY_BREAKS:-0}; PROMPT_COUNT=${PROMPT_COUNT:-0}
LAST_PROMPT_TS=${LAST_PROMPT_TS:-0}; FRUSTRATED_STREAK=${FRUSTRATED_STREAK:-0}
CLAUDE_DONE_TS=${CLAUDE_DONE_TS:-0}; LAST_COMPANION_TS=${LAST_COMPANION_TS:-0}
LAST_MILESTONE_MIN=${LAST_MILESTONE_MIN:-0}; LAST_LATE_HOUR=${LAST_LATE_HOUR:--1}
LAST_SUCCESS_TS=${LAST_SUCCESS_TS:-0}; LAST_MOOD_SUPPORT_TS=${LAST_MOOD_SUPPORT_TS:-0}
STREAK_SHOWN=${STREAK_SHOWN:-0}; CONSECUTIVE_DAYS=${CONSECUTIVE_DAYS:-1}

# ── Compute ACTUAL idle time (excludes Claude processing) ────────
# Must run BEFORE session detection since session reset depends on idle time.
# Real idle = now - when Claude FINISHED its last response.
IDLE_REFERENCE=$LAST_PROMPT_TS
if [ "$CLAUDE_DONE_TS" -gt "$LAST_PROMPT_TS" ]; then
  IDLE_REFERENCE=$CLAUDE_DONE_TS
fi

IDLE_TIME=0
if [ "$IDLE_REFERENCE" -gt 0 ]; then
  IDLE_TIME=$((NOW - IDLE_REFERENCE))
fi

# ── Detect new Claude Code session ───────────────────────────────
# If idle > 30 min, treat as new session. Resets session_start, prompt_count,
# milestone tracking, and greeting so metrics don't pile up across sessions.
if [ "$SESSION_START" -eq 0 ]; then
  SESSION_START=$NOW
elif [ "$IDLE_TIME" -ge 1800 ]; then
  # 30+ min real idle = new session
  SESSION_START=$NOW
  PROMPT_COUNT=0
  SESSION_GREETED="false"
  LAST_MILESTONE_MIN=0
  FRUSTRATED_STREAK=0
  LAST_LATE_HOUR=-1
elif [ "$IDLE_REFERENCE" -eq 0 ] && [ "$LAST_PROMPT_TS" -gt 0 ] && [ "$((NOW - LAST_PROMPT_TS))" -ge 1800 ]; then
  # Fallback when claude_done_ts missing: use prompt gap
  SESSION_START=$NOW
  PROMPT_COUNT=0
  SESSION_GREETED="false"
  LAST_MILESTONE_MIN=0
  FRUSTRATED_STREAK=0
  LAST_LATE_HOUR=-1
fi
PROMPT_COUNT=$((PROMPT_COUNT + 1))

# ── Derived signals ──────────────────────────────────────────────
ELAPSED_SINCE_NUDGE=$((NOW - LAST_NUDGE))
SESSION_MINUTES=$(( (NOW - SESSION_START) / 60 ))

# ── Auto-detect break from ACTUAL idle time ──────────────────────
# 10+ min of REAL idle (after Claude finished) = a break.
AUTO_BREAK="false"
BREAK_GAP_MIN=0
if [ "$IDLE_TIME" -ge 600 ] && [ "$IDLE_TIME" -lt 28800 ]; then
  AUTO_BREAK="true"
  BREAK_GAP_MIN=$((IDLE_TIME / 60))
  TODAY_BREAKS=$((TODAY_BREAKS + 1))
  LAST_BREAK=$NOW
fi

# Project switching
CURRENT_PROJECT="${CLAUDE_PROJECT_DIR:-unknown}"
PROJECT_SWITCHED="false"
if [ -n "$LAST_PROJECT" ] && [ "$LAST_PROJECT" != "$CURRENT_PROJECT" ] && [ "$LAST_PROJECT" != "unknown" ]; then
  PROJECT_SWITCHED="true"
fi

# ── Consecutive days (streak) ────────────────────────────────────
if [ -f "$STREAK_FILE" ]; then
  CONSECUTIVE_DAYS=$(grep -o '"consecutive_days":[0-9]*' "$STREAK_FILE" 2>/dev/null | grep -o '[0-9]*' || echo "0")
  LAST_ACTIVE_DATE=$(grep -o '"last_active_date":"[^"]*"' "$STREAK_FILE" 2>/dev/null | grep -o '"[^"]*"$' | tr -d '"' || echo "")
  if [ "$LAST_ACTIVE_DATE" = "$TODAY" ]; then
    : # already counted today
  else
    YESTERDAY=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d "yesterday" +%Y-%m-%d 2>/dev/null || echo "")
    if [ "$LAST_ACTIVE_DATE" = "$YESTERDAY" ]; then
      CONSECUTIVE_DAYS=$((CONSECUTIVE_DAYS + 1))
    else
      CONSECUTIVE_DAYS=1
    fi
    TMPFILE=$(mktemp "$STATE_DIR/streak.XXXXXX")
    echo "{\"consecutive_days\":$CONSECUTIVE_DAYS,\"last_active_date\":\"$TODAY\"}" > "$TMPFILE"
    mv "$TMPFILE" "$STREAK_FILE"
  fi
else
  CONSECUTIVE_DAYS=1
  echo "{\"consecutive_days\":1,\"last_active_date\":\"$TODAY\"}" > "$STREAK_FILE"
fi

# Frustrated streak
if [ "$FRUSTRATION_SCORE" -ge 2 ]; then
  FRUSTRATED_STREAK=$((FRUSTRATED_STREAK + 1))
else
  FRUSTRATED_STREAK=0
fi

# Returning after long gap
RETURNING_AFTER_BREAK="false"
if [ "$IDLE_TIME" -ge 1800 ] && [ "$IDLE_TIME" -lt 28800 ]; then
  RETURNING_AFTER_BREAK="true"
fi

# Current unbroken stretch
ELAPSED_SINCE_BREAK=$((NOW - LAST_BREAK))
CURRENT_STRETCH=0
if [ "$LAST_BREAK" -gt 0 ]; then
  CURRENT_STRETCH=$((ELAPSED_SINCE_BREAK / 60))
fi

# Burnout signal
BURNOUT_WARNING="false"
if [ "$CONSECUTIVE_DAYS" -ge 7 ] && [ "$TODAY_NUDGES" -eq 0 ]; then
  BURNOUT_WARNING="true"
fi

# ── Log mood (every 5th prompt) ──────────────────────────────────
if [ $((PROMPT_COUNT % 5)) -eq 0 ] && [ "$PROMPT_LEN" -gt 0 ]; then
  echo "{\"ts\":$NOW,\"mood\":\"$MOOD\",\"frust\":$FRUSTRATION_SCORE,\"len\":$PROMPT_LEN,\"proj\":\"$(basename "$CURRENT_PROJECT")\"}" >> "$MOOD_FILE" 2>/dev/null || true
  if [ -f "$MOOD_FILE" ]; then
    LINES=$(wc -l < "$MOOD_FILE" 2>/dev/null | tr -d ' ')
    if [ "$LINES" -gt 500 ]; then
      tail -300 "$MOOD_FILE" > "$MOOD_FILE.tmp" && mv "$MOOD_FILE.tmp" "$MOOD_FILE"
    fi
  fi
fi

# ═══════════════════════════════════════════════════════════════════
# COMPANION TRIGGER DETECTION
# Lightweight touches for moments between health nudges.
# Priority: break_return > frustration > success > session_start
#           > late_night > milestone > streak
# ═══════════════════════════════════════════════════════════════════
COMPANION_TYPE=""

# 1. Break return — always celebrate (bypasses cooldown)
if [ "$AUTO_BREAK" = "true" ]; then
  COMPANION_TYPE="break_return"
fi

# 2. Frustration support — 3+ frustrated prompts, 10-min cooldown
if [ -z "$COMPANION_TYPE" ] && [ "$FRUSTRATED_STREAK" -ge 3 ]; then
  if [ $((NOW - LAST_MOOD_SUPPORT_TS)) -ge "$MOOD_SUPPORT_COOLDOWN" ]; then
    COMPANION_TYPE="frustration_support"
  fi
fi

# 3. Success celebration — 5-min cooldown
if [ -z "$COMPANION_TYPE" ] && [ "$IS_SUCCESS" = "true" ]; then
  if [ $((NOW - LAST_SUCCESS_TS)) -ge "$SUCCESS_COOLDOWN" ]; then
    COMPANION_TYPE="success"
  fi
fi

# 4. Session start — first prompt of session or returning after long gap
if [ -z "$COMPANION_TYPE" ] && [ "$SESSION_GREETED" = "false" ]; then
  if [ "$PROMPT_COUNT" -le 1 ] || [ "$RETURNING_AFTER_BREAK" = "true" ]; then
    COMPANION_TYPE="session_start"
  fi
fi

# 5. Late night crossing — fire once per hour boundary (22, 23, 0, 1, 2)
if [ -z "$COMPANION_TYPE" ]; then
  HOUR_NUM=$((10#$HOUR))  # force decimal (no octal from leading zero)
  if [ "$HOUR_NUM" -ge 22 ] && [ "$LAST_LATE_HOUR" -lt 22 ]; then
    COMPANION_TYPE="late_night"
  elif [ "$HOUR_NUM" -ge 23 ] && [ "$LAST_LATE_HOUR" -lt 23 ]; then
    COMPANION_TYPE="late_night"
  elif [ "$HOUR_NUM" -le 2 ] && [ "$HOUR_NUM" -ge 0 ] && [ "$LAST_LATE_HOUR" -lt 24 ]; then
    COMPANION_TYPE="deep_night"
  elif [ "$HOUR_NUM" -ge 1 ] && [ "$HOUR_NUM" -le 4 ] && [ "$LAST_LATE_HOUR" -lt "$HOUR_NUM" ]; then
    COMPANION_TYPE="deep_night"
  fi
fi

# 6. Session milestone — every 60 min of session time
if [ -z "$COMPANION_TYPE" ]; then
  NEXT_MILESTONE=$(( (LAST_MILESTONE_MIN / 60 + 1) * 60 ))
  if [ "$SESSION_MINUTES" -ge "$NEXT_MILESTONE" ] && [ "$NEXT_MILESTONE" -ge 60 ]; then
    COMPANION_TYPE="milestone"
  fi
fi

# 7. Streak milestone — at day 3, 5, 7, 14, 30 (once per session)
if [ -z "$COMPANION_TYPE" ] && [ "$PROMPT_COUNT" -le 1 ]; then
  for SC in 3 5 7 14 30; do
    if [ "$CONSECUTIVE_DAYS" -ge "$SC" ] && [ "$STREAK_SHOWN" -lt "$SC" ]; then
      COMPANION_TYPE="streak"
      break
    fi
  done
fi

# ── General companion cooldown (break_return + frustration bypass) ──
if [ -n "$COMPANION_TYPE" ] && [ "$COMPANION_TYPE" != "break_return" ] && [ "$COMPANION_TYPE" != "frustration_support" ]; then
  if [ "$LAST_COMPANION_TS" -gt 0 ] && [ $((NOW - LAST_COMPANION_TS)) -lt "$COMPANION_COOLDOWN" ]; then
    COMPANION_TYPE=""  # too soon, suppress
  fi
fi

# ═══════════════════════════════════════════════════════════════════
# HEALTH NUDGE DECISION (existing tier system)
# ═══════════════════════════════════════════════════════════════════
SHOULD_NUDGE="false"
NUDGE_REASON=""
NUDGE_TIER=0

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

# ── Context promotions ───────────────────────────────────────────
if [ "$FRUSTRATED_STREAK" -ge 3 ] && [ "$ELAPSED_SINCE_NUDGE" -ge "$TIER1_INTERVAL" ]; then
  SHOULD_NUDGE="true"
  if [ "$NUDGE_TIER" -lt 3 ]; then NUDGE_TIER=3; fi
  NUDGE_REASON="frustration_detected"
fi

if [ "$IS_STUCK" = "true" ] && [ "$ELAPSED_SINCE_NUDGE" -ge "$TIER1_INTERVAL" ]; then
  SHOULD_NUDGE="true"
  if [ "$NUDGE_TIER" -lt 3 ]; then NUDGE_TIER=3; fi
  NUDGE_REASON="user_stuck"
fi

if [ "$PROMPT_COUNT" -ge 30 ] && [ "$ELAPSED_SINCE_NUDGE" -ge "$TIER1_INTERVAL" ]; then
  SHOULD_NUDGE="true"
  if [ "$NUDGE_TIER" -lt 2 ]; then NUDGE_TIER=2; fi
  NUDGE_REASON="high_intensity"
fi

HOUR_NUM=$((10#$HOUR))
if [ "$HOUR_NUM" -ge 23 ] || [ "$HOUR_NUM" -lt 5 ]; then
  if [ "$ELAPSED_SINCE_NUDGE" -ge "$TIER1_INTERVAL" ] && [ "$NUDGE_TIER" -ge 1 ]; then
    if [ "$NUDGE_TIER" -lt 2 ]; then NUDGE_TIER=2; fi
    NUDGE_REASON="late_night"
  fi
fi

if [ "$HOUR_NUM" -ge 2 ] && [ "$HOUR_NUM" -lt 5 ]; then
  if [ "$ELAPSED_SINCE_NUDGE" -ge "$TIER1_INTERVAL" ] && [ "$NUDGE_TIER" -ge 1 ]; then
    if [ "$NUDGE_TIER" -lt 3 ]; then NUDGE_TIER=3; fi
    NUDGE_REASON="deep_night"
  fi
fi

if [ "$TODAY_NUDGES" -ge 3 ] && [ "$TODAY_BREAKS" -eq 0 ] && [ "$ELAPSED_SINCE_NUDGE" -ge "$TIER1_INTERVAL" ]; then
  SHOULD_NUDGE="true"
  if [ "$NUDGE_TIER" -lt 3 ]; then NUDGE_TIER=3; fi
  NUDGE_REASON="break_deficit"
fi

if [ "$PROJECT_SWITCHED" = "true" ] && [ "$ELAPSED_SINCE_NUDGE" -ge "$TIER1_INTERVAL" ]; then
  SHOULD_NUDGE="true"
  if [ "$NUDGE_TIER" -lt 1 ]; then NUDGE_TIER=1; fi
  NUDGE_REASON="project_switch"
fi

# ═══════════════════════════════════════════════════════════════════
# OUTPUT ROUTING
# Health nudge wins over companion. Companion wins over silence.
# ═══════════════════════════════════════════════════════════════════

# Helper: compute common fields
SASS_LEVEL="friendly"
if [ "$TODAY_NUDGES" -ge 6 ] && [ "$TODAY_BREAKS" -eq 0 ]; then
  SASS_LEVEL="roast"
elif [ "$TODAY_NUDGES" -ge 3 ] && [ "$TODAY_BREAKS" -eq 0 ]; then
  SASS_LEVEL="sarcastic"
fi

BODY_BATTERY="good"
if [ "$CURRENT_STRETCH" -ge 120 ]; then
  BODY_BATTERY="critical"
elif [ "$CURRENT_STRETCH" -ge 90 ]; then
  BODY_BATTERY="low"
elif [ "$CURRENT_STRETCH" -ge 60 ]; then
  BODY_BATTERY="medium"
fi

# Helper: write state to file
write_state() {
  local SG="$1"   # session_greeted
  local LCT="$2"  # last_companion_ts
  local LMM="$3"  # last_milestone_min
  local LLH="$4"  # last_late_hour
  local LST="$5"  # last_success_ts
  local LMST="$6" # last_mood_support_ts
  local SS="$7"   # streak_shown
  local LN="$8"   # last_nudge
  local LND="$9"  # last_nudge_date
  local PC="${10}" # prompt_count
  local LBA="${11}" # last_body_area

  TMPFILE=$(mktemp "$STATE_DIR/state.XXXXXX")
  cat > "$TMPFILE" <<EOJSON
{"version":3,"last_nudge":$LN,"last_tip_index":$LAST_TIP_INDEX,"last_nudge_date":"$LND","session_start":$SESSION_START,"today_nudges":$TODAY_NUDGES,"today_breaks":$TODAY_BREAKS,"last_break":$LAST_BREAK,"prompt_count":$PC,"last_project":"$CURRENT_PROJECT","last_prompt_ts":$NOW,"frustrated_streak":$FRUSTRATED_STREAK,"last_body_area":"$LBA","session_greeted":$SG,"last_companion_ts":$LCT,"last_milestone_min":$LMM,"last_late_hour":$LLH,"last_success_ts":$LST,"last_mood_support_ts":$LMST,"streak_shown":$SS,"prev_mood":"$MOOD"}
EOJSON
  mv "$TMPFILE" "$STATE_FILE"
}

# ─────────────────────────────────────────────────────────────────
# PATH A: Health nudge fires
# ─────────────────────────────────────────────────────────────────
if [ "$SHOULD_NUDGE" = "true" ]; then

  # Select tip with no-repeat logic
  SHOWN_FILE="$STATE_DIR/shown_tips.json"
  TIP_RESULT=$(python3 -c "
import json, random, os

tips_file = '$TIPS_FILE'
shown_file = '$SHOWN_FILE'
tier = $NUDGE_TIER
today = '$TODAY'
last_area = '$LAST_BODY_AREA'

try:
    all_tips = json.load(open(tips_file))
except:
    all_tips = []

shown = {}
try:
    shown = json.load(open(shown_file))
    if shown.get('date') != today:
        shown = {'date': today, 'indices': []}
except:
    shown = {'date': today, 'indices': []}

shown_indices = set(shown.get('indices', []))
tier_tips = [(i, t) for i, t in enumerate(all_tips) if t.get('tier', 3) == tier]
if not tier_tips:
    tier_tips = list(enumerate(all_tips))

available = [(i, t) for i, t in tier_tips if i not in shown_indices]
if not available:
    tier_indices = {i for i, t in tier_tips}
    shown['indices'] = [x for x in shown['indices'] if x not in tier_indices]
    available = tier_tips

if last_area and len(available) > 1:
    diff_area = [(i, t) for i, t in available if t.get('body_area', '') != last_area]
    if diff_area:
        available = diff_area

idx, tip = random.choice(available)
shown['indices'] = shown.get('indices', []) + [idx]
json.dump(shown, open(shown_file, 'w'))

print(tip['text'])
print('---SEP---')
print(tip.get('category', 'general'))
print('---SEP---')
print(tip.get('body_area', 'general'))
" 2>/dev/null || echo "Take a moment to stretch and breathe.
---SEP---
general
---SEP---
general")

  TIP_TEXT=$(echo "$TIP_RESULT" | sed -n '1p')
  TIP_CATEGORY=$(echo "$TIP_RESULT" | sed -n '3p')
  TIP_BODY_AREA=$(echo "$TIP_RESULT" | sed -n '5p')

  TODAY_NUDGES=$((TODAY_NUDGES + 1))

  # Build health nudge output — shows FIRST in Claude's response
  OUTPUT="[WAVE_HEALTH_NUDGE]
RENDERING: START your response with the health nudge, THEN a blank line, THEN address the user's coding question. The user sees the nudge immediately while you stream the rest. Format by tier:
- tier 1: one italic line. *emoji Wave: tip*
- tier 2: --- separator, then Wave Health | Xm in + small ASCII art + tip
- tier 3: --- separator, full block with ASCII art, body battery bar, personalized tip
- tier 4: --- separator, urgent block with big ASCII art, body battery, strong message
PERSONALIZE the tip using the activity and body_most_stressed fields. Rewrite generic tips to reference what the user is actually doing. Use developer humor when sass_level is high. If auto_break_detected is true, celebrate the break instead of nudging.

tier: ${NUDGE_TIER}
session_duration_min: ${SESSION_MINUTES}
nudge_reason: ${NUDGE_REASON}
mood: ${MOOD}
activity: ${ACTIVITY}
body_most_stressed: ${BODY_FOCUS}
tip_category: ${TIP_CATEGORY}
tip: ${TIP_TEXT}
today_nudges: ${TODAY_NUDGES}
today_breaks: ${TODAY_BREAKS}
sass_level: ${SASS_LEVEL}
body_battery: ${BODY_BATTERY}
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

  if [ "$AUTO_BREAK" = "true" ]; then
    OUTPUT="${OUTPUT}
auto_break_detected: true
break_duration_min: ${BREAK_GAP_MIN}"
  fi

  if [ "$RETURNING_AFTER_BREAK" = "true" ]; then
    OUTPUT="${OUTPUT}
returning_after_break: true
away_duration_min: ${BREAK_GAP_MIN}"
  fi

  if [ "$CURRENT_STRETCH" -gt 0 ]; then
    OUTPUT="${OUTPUT}
current_unbroken_stretch_min: ${CURRENT_STRETCH}"
  fi

  if [ "$BURNOUT_WARNING" = "true" ]; then
    OUTPUT="${OUTPUT}
burnout_warning: true"
  fi

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

  # If this is the first prompt, include greeting hint so Claude also greets
  if [ "$SESSION_GREETED" = "false" ]; then
    OUTPUT="${OUTPUT}
first_prompt_of_session: true
hour: $HOUR_NUM"
    if [ "$CONSECUTIVE_DAYS" -ge 3 ]; then
      OUTPUT="${OUTPUT}
streak_days: $CONSECUTIVE_DAYS"
    fi
    SESSION_GREETED="true"
  fi

  OUTPUT="${OUTPUT}
[/WAVE_HEALTH_NUDGE]"

  echo "$OUTPUT"

  # If nudge had late_night context, mark late hour so companion doesn't repeat
  NUDGE_LATE_HOUR="$LAST_LATE_HOUR"
  if [ "$NUDGE_REASON" = "late_night" ] || [ "$NUDGE_REASON" = "deep_night" ]; then
    NUDGE_LATE_HOUR="$HOUR_NUM"
  fi

  # Save state: nudge fired
  write_state "$SESSION_GREETED" "$LAST_COMPANION_TS" "$LAST_MILESTONE_MIN" \
    "$NUDGE_LATE_HOUR" "$LAST_SUCCESS_TS" "$LAST_MOOD_SUPPORT_TS" \
    "$STREAK_SHOWN" "$NOW" "$TODAY" "0" "$TIP_BODY_AREA"
  exit 0
fi

# ─────────────────────────────────────────────────────────────────
# PATH B: Companion touch fires (no health nudge due)
# ─────────────────────────────────────────────────────────────────
if [ -n "$COMPANION_TYPE" ]; then

  # Update dedup timestamps based on type
  NEW_GREETED="$SESSION_GREETED"
  NEW_COMPANION_TS="$NOW"
  NEW_MILESTONE="$LAST_MILESTONE_MIN"
  NEW_LATE_HOUR="$LAST_LATE_HOUR"
  NEW_SUCCESS_TS="$LAST_SUCCESS_TS"
  NEW_MOOD_TS="$LAST_MOOD_SUPPORT_TS"
  NEW_STREAK_SHOWN="$STREAK_SHOWN"

  case "$COMPANION_TYPE" in
    session_start)
      NEW_GREETED="true"
      ;;
    break_return)
      # no special dedup needed
      ;;
    success)
      NEW_SUCCESS_TS="$NOW"
      ;;
    frustration_support)
      NEW_MOOD_TS="$NOW"
      ;;
    late_night|deep_night)
      NEW_LATE_HOUR="$HOUR_NUM"
      ;;
    milestone)
      NEW_MILESTONE="$SESSION_MINUTES"
      ;;
    streak)
      NEW_STREAK_SHOWN="$CONSECUTIVE_DAYS"
      ;;
  esac

  # Build companion output — type-specific rendering instructions
  case "$COMPANION_TYPE" in

    session_start)
      # Determine sub-context for the greeting
      GREETING_HINTS="hour: $HOUR_NUM"
      if [ "$DOW" -ge 6 ]; then
        GREETING_HINTS="$GREETING_HINTS
weekend: true"
      fi
      if [ "$CONSECUTIVE_DAYS" -ge 3 ]; then
        GREETING_HINTS="$GREETING_HINTS
streak_days: $CONSECUTIVE_DAYS"
      fi
      if [ "$CONSECUTIVE_DAYS" -eq 1 ] && [ "$PROMPT_COUNT" -le 1 ]; then
        GREETING_HINTS="$GREETING_HINTS
fresh_start: true"
      fi
      if [ "$RETURNING_AFTER_BREAK" = "true" ]; then
        GREETING_HINTS="$GREETING_HINTS
returning: true
away_min: $BREAK_GAP_MIN"
      fi
      if [ "$BURNOUT_WARNING" = "true" ]; then
        GREETING_HINTS="$GREETING_HINTS
burnout_warning: true"
      fi

      cat <<EOCOMP
[WAVE_COMPANION]
RENDERING: START your response with a brief greeting (1 line max, casual, like a friend), then a blank line, then address the user's coding question. Tone by time of day: morning=upbeat, afternoon=coach, evening=gentle, late night=concerned. If streak_days shown, mention it. If weekend, acknowledge it. If burnout_warning, be gentle about rest.
type: session_start
$GREETING_HINTS
[/WAVE_COMPANION]
EOCOMP
      ;;

    break_return)
      cat <<EOCOMP
[WAVE_COMPANION]
RENDERING: START your response with a brief break celebration (1 line, genuine, warm), then a blank line, then address the user's coding question. Mention the duration. If they were frustrated before the break, acknowledge the reset. Never be preachy.
type: break_return
break_duration_min: $BREAK_GAP_MIN
mood_before_break: $PREV_MOOD
today_breaks: $TODAY_BREAKS
[/WAVE_COMPANION]
EOCOMP
      ;;

    success)
      cat <<EOCOMP
[WAVE_COMPANION]
RENDERING: START your response with a brief celebration (1 line, genuine, not over-the-top), then a blank line, then address the user's coding question. Match the energy. "Shipped." or "Bug squashed." or "Clean." Keep it tight.
type: success
session_duration_min: $SESSION_MINUTES
mood: $MOOD
[/WAVE_COMPANION]
EOCOMP
      ;;

    frustration_support)
      cat <<EOCOMP
[WAVE_COMPANION]
RENDERING: START your response with empathy (1-2 lines, never preachy, never "just take a break"). Acknowledge the struggle. If the streak is 5+, suggest stepping away. Then a blank line, then address the user's coding question with extra care and clarity.
type: frustration_support
frustrated_prompts_in_row: $FRUSTRATED_STREAK
session_duration_min: $SESSION_MINUTES
body_battery: $BODY_BATTERY
[/WAVE_COMPANION]
EOCOMP
      ;;

    late_night)
      cat <<EOCOMP
[WAVE_COMPANION]
RENDERING: START your response with a gentle time check (1 line, not preachy, just awareness). Then blank line, then address the user's coding question.
type: late_night
hour: $HOUR_NUM
session_duration_min: $SESSION_MINUTES
[/WAVE_COMPANION]
EOCOMP
      ;;

    deep_night)
      cat <<EOCOMP
[WAVE_COMPANION]
RENDERING: START your response with a brief honest check (1 line, direct but caring). "It's 2am. What's the minimum viable stopping point?" or "Past midnight. Tomorrow-you will review this." Then blank line, then address the user's coding question.
type: deep_night
hour: $HOUR_NUM
session_duration_min: $SESSION_MINUTES
[/WAVE_COMPANION]
EOCOMP
      ;;

    milestone)
      cat <<EOCOMP
[WAVE_COMPANION]
RENDERING: START your response with a milestone check-in (1 line). Mention session time and breaks taken. If 0 breaks, note it with light humor. Then blank line, then address the user's coding question.
type: milestone
session_duration_min: $SESSION_MINUTES
today_breaks: $TODAY_BREAKS
body_battery: $BODY_BATTERY
[/WAVE_COMPANION]
EOCOMP
      ;;

    streak)
      STREAK_MSG=""
      if [ "$CONSECUTIVE_DAYS" -ge 7 ]; then
        STREAK_MSG="At 7+ days, gently mention rest days."
      fi
      cat <<EOCOMP
[WAVE_COMPANION]
RENDERING: START your response with a streak acknowledgment (1 line). $STREAK_MSG Then blank line, then address the user's coding question.
type: streak
consecutive_days: $CONSECUTIVE_DAYS
[/WAVE_COMPANION]
EOCOMP
      ;;
  esac

  # Save state: companion fired
  SG_VAL="false"
  if [ "$NEW_GREETED" = "true" ]; then SG_VAL="true"; fi
  write_state "$SG_VAL" "$NEW_COMPANION_TS" "$NEW_MILESTONE" \
    "$NEW_LATE_HOUR" "$NEW_SUCCESS_TS" "$NEW_MOOD_TS" \
    "$NEW_STREAK_SHOWN" "$LAST_NUDGE" "${LAST_NUDGE_DATE:-$TODAY}" \
    "$PROMPT_COUNT" "$LAST_BODY_AREA"
  exit 0
fi

# ─────────────────────────────────────────────────────────────────
# PATH C: Silent — no nudge, no companion
# ─────────────────────────────────────────────────────────────────
write_state "$SESSION_GREETED" "$LAST_COMPANION_TS" "$LAST_MILESTONE_MIN" \
  "$LAST_LATE_HOUR" "$LAST_SUCCESS_TS" "$LAST_MOOD_SUPPORT_TS" \
  "$STREAK_SHOWN" "$LAST_NUDGE" "${LAST_NUDGE_DATE:-$TODAY}" \
  "$PROMPT_COUNT" "$LAST_BODY_AREA"
exit 0
