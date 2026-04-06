#!/bin/bash
# Wave Dev Health — Wellness checker + companion
# Runs on EVERY UserPromptSubmit. Stdout injected as system context to Claude.
#
# OUTPUT MODES (priority order):
#   1. [WAVE_HEALTH_NUDGE] — Health nudge (shows FIRST in response)
#   2. [WAVE_COMPANION]    — Lightweight emotional/session touch (1-2 lines, shows FIRST)
#   3. Silent              — No output (most prompts)
#
# BREAK DETECTION:
#   real_idle = prompt_gap - claude_processing_time
#   real_idle >= 5 min = REAL BREAK (counts, resets nudge tier)
#   real_idle < 5 min  = CLAUDE BREAK (logged, doesn't count)
#
# NUDGE SYSTEM:
#   Single interval (20 min). Tier = consecutive nudges ignored since last real break.
#   Real break resets tier to 0. Tier caps at 4.

set -euo pipefail

STATE_DIR="$HOME/.wave-dev-health"
STATE_FILE="$STATE_DIR/state.json"
TIPS_FILE="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$0")")}/src/tips.json"
CONFIG_FILE="$STATE_DIR/config.json"
TELEMETRY_SCRIPT="$(cd "$(dirname "$0")" && pwd)/telemetry-ping.sh"
STREAK_FILE="$STATE_DIR/streak.json"
MOOD_FILE="$STATE_DIR/mood_log.jsonl"
GLOBAL_ACTIVE="$STATE_DIR/global_active"
TODAY_LOG="$STATE_DIR/today_activity.log"

# ── Debug mode ───────────────────────────────────────────────────
# touch ~/.wave-dev-health/debug to enable, rm to disable
DEBUG_MODE="false"
if [ -f "$STATE_DIR/debug" ]; then
  DEBUG_MODE="true"
fi

if [ "$DEBUG_MODE" = "true" ]; then
  NUDGE_INTERVAL=5          # 5 sec between nudges
  REAL_BREAK_THRESHOLD=3    # 3 sec = real break
  COMPANION_COOLDOWN=3
  MOOD_SUPPORT_COOLDOWN=5
  SUCCESS_COOLDOWN=3
else
  NUDGE_INTERVAL=1200       # 20 min between nudges
  REAL_BREAK_THRESHOLD=300  # 5 min of actual idle = real break
  COMPANION_COOLDOWN=300    # 5 min between companion touches
  MOOD_SUPPORT_COOLDOWN=600 # 10 min between frustration support
  SUCCESS_COOLDOWN=300      # 5 min between success celebrations
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

# ── Analyze prompt for mood/frustration (lightweight, for trigger decisions) ──
MOOD="neutral"
FRUSTRATION_SCORE=0
IS_DEBUGGING="false"
IS_STUCK="false"
IS_SUCCESS="false"

if echo "$PROMPT_LOWER" | grep -qE '(not working|still broken|same error|why is|what.s wrong|can.t figure|still not|keeps failing|again!|wtf|ugh|help me)'; then
  FRUSTRATION_SCORE=3; MOOD="frustrated"
fi
if echo "$PROMPT_LOWER" | grep -qE '(error|bug|broken|crash|fails|failing|exception|undefined|null|typeerror|referenceerror)'; then
  FRUSTRATION_SCORE=$((FRUSTRATION_SCORE + 1)); IS_DEBUGGING="true"
  [ "$MOOD" = "neutral" ] && MOOD="debugging"
fi
if echo "$PROMPT_LOWER" | grep -qE '(tried everything|no idea|stuck|confused|lost|going in circles|been at this)'; then
  FRUSTRATION_SCORE=$((FRUSTRATION_SCORE + 2)); IS_STUCK="true"; MOOD="stuck"
fi
if echo "$PROMPT_LOWER" | grep -qE '(it works|fixed|nailed it|tests pass|all green|shipped|deployed|merged|done!|perfect|looks good|let.s go|lgtm|nice)'; then
  IS_SUCCESS="true"; [ "$MOOD" = "neutral" ] && MOOD="shipping"
fi
if echo "$PROMPT_LOWER" | grep -qE '(add|create|implement|build|new feature|write|generate|design)'; then
  [ "$MOOD" = "neutral" ] && MOOD="building"
fi
if [ "$PROMPT_LEN" -lt 20 ] && [ "$PROMPT_LEN" -gt 0 ]; then
  FRUSTRATION_SCORE=$((FRUSTRATION_SCORE + 1))
fi

# ── Activity detection (for today_activity.log, not for nudge output) ────
ACTIVITY="general"
if echo "$PROMPT_LOWER" | grep -qE '(test|spec|assert|expect|coverage|mock|jest|vitest|pytest)'; then ACTIVITY="testing"; fi
if echo "$PROMPT_LOWER" | grep -qE '(review|read|check|look at|what does|explain|diff|pr )'; then ACTIVITY="reviewing"; fi
if echo "$PROMPT_LOWER" | grep -qE '(write|implement|create|add.*function|refactor|rename)'; then ACTIVITY="writing"; fi
if [ "$IS_DEBUGGING" = "true" ] || echo "$PROMPT_LOWER" | grep -qE '(debug|fix|trace|log|inspect|stack)'; then ACTIVITY="debugging"; fi
if echo "$PROMPT_LOWER" | grep -qE '(deploy|docker|kubernetes|ci|cd|pipeline|config|aws|terraform)'; then ACTIVITY="devops"; fi
if echo "$PROMPT_LOWER" | grep -qE '(css|style|design|layout|color|font|ui|ux)'; then ACTIVITY="design"; fi
if echo "$PROMPT_LOWER" | grep -qE '(database|query|sql|migration|schema|data|api|fetch)'; then ACTIVITY="data"; fi

# ── Cross-session tracking ───────────────────────────────────────
CURRENT_PROJECT="${CLAUDE_PROJECT_DIR:-unknown}"
PROJECT_BASE=$(basename "$CURRENT_PROJECT")

# Read global_active mtime BEFORE touching (for cross-session idle detection)
GLOBAL_ACTIVE_TS=0
if [ -f "$GLOBAL_ACTIVE" ]; then
  GLOBAL_ACTIVE_TS=$(python3 -c "import os; print(int(os.path.getmtime('$GLOBAL_ACTIVE')))" 2>/dev/null || echo "0")
fi
touch "$GLOBAL_ACTIVE" 2>/dev/null || true

# Append to daily activity log
if [ -f "$TODAY_LOG" ]; then
  FIRST_DATE=$(head -1 "$TODAY_LOG" 2>/dev/null | awk '{print $2}' 2>/dev/null || echo "")
  if [ -n "$FIRST_DATE" ] && [ "$FIRST_DATE" != "$TODAY" ]; then
    : > "$TODAY_LOG"
  fi
fi
echo "$NOW $TODAY $PROJECT_BASE $ACTIVITY $MOOD ${PPID:-0}" >> "$TODAY_LOG" 2>/dev/null || true
if [ -f "$TODAY_LOG" ]; then
  TLINES=$(wc -l < "$TODAY_LOG" 2>/dev/null | tr -d ' ')
  [ "$TLINES" -gt 500 ] && { tail -300 "$TODAY_LOG" > "$TODAY_LOG.tmp" && mv "$TODAY_LOG.tmp" "$TODAY_LOG"; }
fi

# ── Read config ──────────────────────────────────────────────────
DISABLED="false"
if [ -f "$CONFIG_FILE" ]; then
  DISABLED=$(grep -o '"disabled":[a-z]*' "$CONFIG_FILE" 2>/dev/null | grep -o 'true' || echo "false")
fi
[ "$DISABLED" = "true" ] && exit 0

# ── Read state ───────────────────────────────────────────────────
LAST_NUDGE=0; LAST_TIP_INDEX=0; LAST_NUDGE_DATE=""; SESSION_START=0
LAST_BREAK=0; TODAY_NUDGES=0; TODAY_BREAKS=0; PROMPT_COUNT=0
LAST_PROJECT=""; LAST_PROMPT_TS=0; FRUSTRATED_STREAK=0
LAST_BODY_AREA=""; CLAUDE_DONE_TS=0; NUDGES_SINCE_BREAK=0
SESSION_GREETED="false"; LAST_COMPANION_TS=0; LAST_MILESTONE_MIN=0
LAST_LATE_HOUR=-1; LAST_SUCCESS_TS=0; LAST_MOOD_SUPPORT_TS=0
STREAK_SHOWN=0; PREV_MOOD=""; LAST_SESSION_PID=0
LAST_SESSION_DURATION=0; LAST_SESSION_PROJECT=""

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
p('NUDGES_SINCE_BREAK', d.get('nudges_since_break', 0))
p('SESSION_GREETED', d.get('session_greeted', False))
p('LAST_COMPANION_TS', d.get('last_companion_ts', 0))
p('LAST_MILESTONE_MIN', d.get('last_milestone_min', 0))
p('LAST_LATE_HOUR', d.get('last_late_hour', -1))
p('LAST_SUCCESS_TS', d.get('last_success_ts', 0))
p('LAST_MOOD_SUPPORT_TS', d.get('last_mood_support_ts', 0))
p('STREAK_SHOWN', d.get('streak_shown', 0))
p('PREV_MOOD', d.get('prev_mood', ''))
p('LAST_SESSION_PID', d.get('last_session_pid', 0))
p('LAST_SESSION_DURATION', d.get('last_session_duration', 0))
p('LAST_SESSION_PROJECT', d.get('last_session_project', ''))

nd = d.get('last_nudge_date', '')
if nd == today:
    p('TODAY_NUDGES', d.get('today_nudges', 0))
    p('TODAY_BREAKS', d.get('today_breaks', 0))
" 2>/dev/null)" || true
fi

# Safety defaults
LAST_NUDGE=${LAST_NUDGE:-0}; SESSION_START=${SESSION_START:-0}
LAST_BREAK=${LAST_BREAK:-0}; TODAY_NUDGES=${TODAY_NUDGES:-0}
TODAY_BREAKS=${TODAY_BREAKS:-0}; PROMPT_COUNT=${PROMPT_COUNT:-0}
LAST_PROMPT_TS=${LAST_PROMPT_TS:-0}; FRUSTRATED_STREAK=${FRUSTRATED_STREAK:-0}
CLAUDE_DONE_TS=${CLAUDE_DONE_TS:-0}; LAST_COMPANION_TS=${LAST_COMPANION_TS:-0}
LAST_MILESTONE_MIN=${LAST_MILESTONE_MIN:-0}; LAST_LATE_HOUR=${LAST_LATE_HOUR:--1}
LAST_SUCCESS_TS=${LAST_SUCCESS_TS:-0}; LAST_MOOD_SUPPORT_TS=${LAST_MOOD_SUPPORT_TS:-0}
STREAK_SHOWN=${STREAK_SHOWN:-0}; CONSECUTIVE_DAYS=${CONSECUTIVE_DAYS:-1}
LAST_SESSION_PID=${LAST_SESSION_PID:-0}; LAST_SESSION_DURATION=${LAST_SESSION_DURATION:-0}
NUDGES_SINCE_BREAK=${NUDGES_SINCE_BREAK:-0}

# ═══════════════════════════════════════════════════════════════════
# BREAK DETECTION (new system)
# real_idle = prompt_gap - claude_processing_time
# real_idle >= 5 min = REAL BREAK
# ═══════════════════════════════════════════════════════════════════

# Prompt gap: time between user prompts (across all sessions)
PROMPT_GAP=0
GLOBAL_PROMPT_GAP=0
if [ "$LAST_PROMPT_TS" -gt 0 ]; then
  PROMPT_GAP=$((NOW - LAST_PROMPT_TS))
fi
# Cross-session: use global_active for the gap if it's more recent
if [ "$GLOBAL_ACTIVE_TS" -gt "$LAST_PROMPT_TS" ] && [ "$GLOBAL_ACTIVE_TS" -gt 0 ]; then
  GLOBAL_PROMPT_GAP=$((NOW - GLOBAL_ACTIVE_TS))
else
  GLOBAL_PROMPT_GAP=$PROMPT_GAP
fi

# Claude processing time: how long Claude worked on the last response
CLAUDE_PROCESSING=0
if [ "$CLAUDE_DONE_TS" -gt "$LAST_PROMPT_TS" ] && [ "$LAST_PROMPT_TS" -gt 0 ]; then
  CLAUDE_PROCESSING=$((CLAUDE_DONE_TS - LAST_PROMPT_TS))
fi

# Real idle = gap minus Claude's work
# Use the smaller gap (global vs per-session) for cross-session accuracy
USE_GAP=$PROMPT_GAP
if [ "$GLOBAL_PROMPT_GAP" -gt 0 ] && [ "$GLOBAL_PROMPT_GAP" -lt "$USE_GAP" ]; then
  USE_GAP=$GLOBAL_PROMPT_GAP
fi

REAL_IDLE=0
if [ "$USE_GAP" -gt "$CLAUDE_PROCESSING" ]; then
  REAL_IDLE=$((USE_GAP - CLAUDE_PROCESSING))
fi

# Classify the break
BREAK_TYPE="none"      # none | real | claude
BREAK_DURATION_MIN=0
if [ "$USE_GAP" -ge "$REAL_BREAK_THRESHOLD" ]; then
  if [ "$REAL_IDLE" -ge "$REAL_BREAK_THRESHOLD" ]; then
    BREAK_TYPE="real"
    BREAK_DURATION_MIN=$((REAL_IDLE / 60))
    TODAY_BREAKS=$((TODAY_BREAKS + 1))
    LAST_BREAK=$NOW
    # Telemetry: real break detected (backgrounded)
    bash "$TELEMETRY_SCRIPT" break "break_duration_min=$BREAK_DURATION_MIN" \
      "nudges_since_break=$NUDGES_SINCE_BREAK" "today_breaks=$TODAY_BREAKS" &
    NUDGES_SINCE_BREAK=0  # reset! user took a real break
  else
    BREAK_TYPE="claude"
    # Don't count, don't reset. Just log.
  fi
fi

# ── Detect new Claude Code session ───────────────────────────────
CURRENT_PPID=${PPID:-0}
IS_NEW_SESSION="false"
BREAK_SINCE_LAST_MIN=0

if [ "$SESSION_START" -eq 0 ]; then
  IS_NEW_SESSION="true"
  SESSION_START=$NOW
elif [ "$LAST_SESSION_PID" -ne 0 ] && [ "$LAST_SESSION_PID" -ne "$CURRENT_PPID" ]; then
  IS_NEW_SESSION="true"
  LAST_SESSION_DURATION=$(( (NOW - SESSION_START) / 60 ))
  LAST_SESSION_PROJECT="$PROJECT_BASE"
  BREAK_SINCE_LAST_MIN=$((USE_GAP / 60))
  SESSION_START=$NOW
  PROMPT_COUNT=0; SESSION_GREETED="false"; LAST_MILESTONE_MIN=0
  FRUSTRATED_STREAK=0; LAST_LATE_HOUR=-1
elif [ "$USE_GAP" -ge 1800 ]; then
  IS_NEW_SESSION="true"
  LAST_SESSION_DURATION=$(( (NOW - SESSION_START) / 60 ))
  LAST_SESSION_PROJECT="$PROJECT_BASE"
  BREAK_SINCE_LAST_MIN=$((USE_GAP / 60))
  SESSION_START=$NOW
  PROMPT_COUNT=0; SESSION_GREETED="false"; LAST_MILESTONE_MIN=0
  FRUSTRATED_STREAK=0; LAST_LATE_HOUR=-1
fi
PROMPT_COUNT=$((PROMPT_COUNT + 1))

# ── Derived signals ──────────────────────────────────────────────
ELAPSED_SINCE_NUDGE=$((NOW - LAST_NUDGE))
SESSION_MINUTES=$(( (NOW - SESSION_START) / 60 ))

# Cross-session analysis
ACTIVE_PROJECTS=""
PARALLEL_SESSIONS=1
if [ -f "$TODAY_LOG" ]; then
  CUTOFF_30M=$((NOW - 1800))
  CUTOFF_5M=$((NOW - 300))
  ACTIVE_PROJECTS=$(awk -v c="$CUTOFF_30M" '$1 >= c {print $3}' "$TODAY_LOG" 2>/dev/null | sort -u | tr '\n' ',' | sed 's/,$//')
  PARALLEL_SESSIONS=$(awk -v c="$CUTOFF_5M" '$1 >= c {print $6}' "$TODAY_LOG" 2>/dev/null | sort -u | wc -l | tr -d ' ')
  [ "$PARALLEL_SESSIONS" -lt 1 ] && PARALLEL_SESSIONS=1
fi

# Project switching
PROJECT_SWITCHED="false"
if [ -n "$LAST_PROJECT" ] && [ "$LAST_PROJECT" != "$CURRENT_PROJECT" ] && [ "$LAST_PROJECT" != "unknown" ]; then
  PROJECT_SWITCHED="true"
fi

# Consecutive days (streak)
if [ -f "$STREAK_FILE" ]; then
  CONSECUTIVE_DAYS=$(grep -o '"consecutive_days":[0-9]*' "$STREAK_FILE" 2>/dev/null | grep -o '[0-9]*' || echo "0")
  LAST_ACTIVE_DATE=$(grep -o '"last_active_date":"[^"]*"' "$STREAK_FILE" 2>/dev/null | grep -o '"[^"]*"$' | tr -d '"' || echo "")
  if [ "$LAST_ACTIVE_DATE" != "$TODAY" ]; then
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
if [ "$IS_NEW_SESSION" = "false" ] && [ "$USE_GAP" -ge 1800 ]; then
  RETURNING_AFTER_BREAK="true"
fi

# Current unbroken stretch (time since last REAL break)
CURRENT_STRETCH=0
if [ "$LAST_BREAK" -gt 0 ]; then
  CURRENT_STRETCH=$(( (NOW - LAST_BREAK) / 60 ))
fi

# Burnout signal
BURNOUT_WARNING="false"
if [ "$CONSECUTIVE_DAYS" -ge 7 ] && [ "$TODAY_NUDGES" -eq 0 ]; then
  BURNOUT_WARNING="true"
fi

# Log mood (every 5th prompt)
if [ $((PROMPT_COUNT % 5)) -eq 0 ] && [ "$PROMPT_LEN" -gt 0 ]; then
  echo "{\"ts\":$NOW,\"mood\":\"$MOOD\",\"frust\":$FRUSTRATION_SCORE,\"len\":$PROMPT_LEN,\"proj\":\"$PROJECT_BASE\"}" >> "$MOOD_FILE" 2>/dev/null || true
  if [ -f "$MOOD_FILE" ]; then
    LINES=$(wc -l < "$MOOD_FILE" 2>/dev/null | tr -d ' ')
    [ "$LINES" -gt 500 ] && { tail -300 "$MOOD_FILE" > "$MOOD_FILE.tmp" && mv "$MOOD_FILE.tmp" "$MOOD_FILE"; }
  fi
fi

# ═══════════════════════════════════════════════════════════════════
# COMPANION TRIGGER DETECTION
# ═══════════════════════════════════════════════════════════════════
COMPANION_TYPE=""

# 1. Real break return — celebrate (bypasses cooldown)
if [ "$BREAK_TYPE" = "real" ]; then
  COMPANION_TYPE="break_return"
fi

# 2. Frustration support — 3+ frustrated prompts, cooldown
if [ -z "$COMPANION_TYPE" ] && [ "$FRUSTRATED_STREAK" -ge 3 ]; then
  if [ $((NOW - LAST_MOOD_SUPPORT_TS)) -ge "$MOOD_SUPPORT_COOLDOWN" ]; then
    COMPANION_TYPE="frustration_support"
  fi
fi

# 3. Success celebration
if [ -z "$COMPANION_TYPE" ] && [ "$IS_SUCCESS" = "true" ]; then
  if [ $((NOW - LAST_SUCCESS_TS)) -ge "$SUCCESS_COOLDOWN" ]; then
    COMPANION_TYPE="success"
  fi
fi

# 4. Session start
if [ -z "$COMPANION_TYPE" ] && [ "$SESSION_GREETED" = "false" ]; then
  if [ "$PROMPT_COUNT" -le 1 ] || [ "$RETURNING_AFTER_BREAK" = "true" ]; then
    COMPANION_TYPE="session_start"
  fi
fi

# 5. Late night crossing
if [ -z "$COMPANION_TYPE" ]; then
  HOUR_NUM=$((10#$HOUR))
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

# 6. Session milestone (every 60 min)
if [ -z "$COMPANION_TYPE" ]; then
  NEXT_MILESTONE=$(( (LAST_MILESTONE_MIN / 60 + 1) * 60 ))
  if [ "$SESSION_MINUTES" -ge "$NEXT_MILESTONE" ] && [ "$NEXT_MILESTONE" -ge 60 ]; then
    COMPANION_TYPE="milestone"
  fi
fi

# 7. Streak milestone
if [ -z "$COMPANION_TYPE" ] && [ "$PROMPT_COUNT" -le 1 ]; then
  for SC in 3 5 7 14 30; do
    if [ "$CONSECUTIVE_DAYS" -ge "$SC" ] && [ "$STREAK_SHOWN" -lt "$SC" ]; then
      COMPANION_TYPE="streak"
      break
    fi
  done
fi

# General companion cooldown
if [ -n "$COMPANION_TYPE" ] && [ "$COMPANION_TYPE" != "break_return" ] && [ "$COMPANION_TYPE" != "frustration_support" ]; then
  if [ "$LAST_COMPANION_TS" -gt 0 ] && [ $((NOW - LAST_COMPANION_TS)) -lt "$COMPANION_COOLDOWN" ]; then
    COMPANION_TYPE=""
  fi
fi

# ═══════════════════════════════════════════════════════════════════
# NUDGE DECISION
# Single interval. Tier = consecutive nudges ignored since last real break.
# Real break resets nudges_since_break to 0.
# ═══════════════════════════════════════════════════════════════════
SHOULD_NUDGE="false"
NUDGE_TIER=0

# Fire nudge if enough time since last nudge AND no real break just happened
if [ "$ELAPSED_SINCE_NUDGE" -ge "$NUDGE_INTERVAL" ] && [ "$BREAK_TYPE" != "real" ]; then
  SHOULD_NUDGE="true"
  # Tier = how many nudges ignored (capped at 4)
  NUDGE_TIER=$((NUDGES_SINCE_BREAK + 1))
  [ "$NUDGE_TIER" -gt 4 ] && NUDGE_TIER=4
fi

# Context: frustration/stuck can trigger early nudge
if [ "$FRUSTRATED_STREAK" -ge 3 ] && [ "$ELAPSED_SINCE_NUDGE" -ge "$((NUDGE_INTERVAL / 2))" ] && [ "$BREAK_TYPE" != "real" ]; then
  SHOULD_NUDGE="true"
  NUDGE_TIER=$((NUDGES_SINCE_BREAK + 1))
  [ "$NUDGE_TIER" -gt 4 ] && NUDGE_TIER=4
  [ "$NUDGE_TIER" -lt 3 ] && NUDGE_TIER=3
fi

# ═══════════════════════════════════════════════════════════════════
# OUTPUT ROUTING
# ═══════════════════════════════════════════════════════════════════

HOUR_NUM=$((10#$HOUR))

# Sass level based on nudges since break
SASS_LEVEL="friendly"
if [ "$NUDGES_SINCE_BREAK" -ge 4 ]; then
  SASS_LEVEL="roast"
elif [ "$NUDGES_SINCE_BREAK" -ge 2 ]; then
  SASS_LEVEL="sarcastic"
fi

# Body battery
DRAIN=0
[ "$CURRENT_STRETCH" -ge 120 ] && DRAIN=$((DRAIN + 50)) || {
  [ "$CURRENT_STRETCH" -ge 90 ] && DRAIN=$((DRAIN + 35)) || {
    [ "$CURRENT_STRETCH" -ge 60 ] && DRAIN=$((DRAIN + 20)) || {
      [ "$CURRENT_STRETCH" -ge 30 ] && DRAIN=$((DRAIN + 10))
    }
  }
}
[ "$NUDGES_SINCE_BREAK" -ge 4 ] && DRAIN=$((DRAIN + 20)) || {
  [ "$NUDGES_SINCE_BREAK" -ge 2 ] && DRAIN=$((DRAIN + 10))
}
if [ "$HOUR_NUM" -ge 22 ] || [ "$HOUR_NUM" -lt 6 ]; then
  DRAIN=$((DRAIN + 15))
elif [ "$HOUR_NUM" -ge 14 ] && [ "$HOUR_NUM" -lt 16 ]; then
  DRAIN=$((DRAIN + 5))
fi
[ "$FRUSTRATED_STREAK" -ge 3 ] && DRAIN=$((DRAIN + 10))

BODY_BATTERY="good"
if [ "$DRAIN" -ge 60 ]; then BODY_BATTERY="critical"
elif [ "$DRAIN" -ge 40 ]; then BODY_BATTERY="low"
elif [ "$DRAIN" -ge 20 ]; then BODY_BATTERY="medium"
fi

# Helper: write state
write_state() {
  local SG="$1" LCT="$2" LMM="$3" LLH="$4" LST="$5" LMST="$6" SS="$7" LN="$8" LND="$9" PC="${10}" LBA="${11}"
  TMPFILE=$(mktemp "$STATE_DIR/state.XXXXXX")
  cat > "$TMPFILE" <<EOJSON
{"version":5,"last_nudge":$LN,"last_tip_index":$LAST_TIP_INDEX,"last_nudge_date":"$LND","session_start":$SESSION_START,"today_nudges":$TODAY_NUDGES,"today_breaks":$TODAY_BREAKS,"last_break":$LAST_BREAK,"prompt_count":$PC,"last_project":"$CURRENT_PROJECT","last_prompt_ts":$NOW,"frustrated_streak":$FRUSTRATED_STREAK,"last_body_area":"$LBA","nudges_since_break":$NUDGES_SINCE_BREAK,"session_greeted":$SG,"last_companion_ts":$LCT,"last_milestone_min":$LMM,"last_late_hour":$LLH,"last_success_ts":$LST,"last_mood_support_ts":$LMST,"streak_shown":$SS,"prev_mood":"$MOOD","last_session_pid":$CURRENT_PPID,"last_session_duration":$LAST_SESSION_DURATION,"last_session_project":"$LAST_SESSION_PROJECT"}
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
import json, random
tips_file = '$TIPS_FILE'
shown_file = '$SHOWN_FILE'
tier = $NUDGE_TIER
today = '$TODAY'
last_area = '$LAST_BODY_AREA'
try: all_tips = json.load(open(tips_file))
except: all_tips = []
shown = {}
try:
    shown = json.load(open(shown_file))
    if shown.get('date') != today: shown = {'date': today, 'indices': []}
except: shown = {'date': today, 'indices': []}
shown_indices = set(shown.get('indices', []))
tier_tips = [(i, t) for i, t in enumerate(all_tips) if t.get('tier', 3) == tier]
if not tier_tips: tier_tips = list(enumerate(all_tips))
available = [(i, t) for i, t in tier_tips if i not in shown_indices]
if not available:
    tier_indices = {i for i, t in tier_tips}
    shown['indices'] = [x for x in shown['indices'] if x not in tier_indices]
    available = tier_tips
if last_area and len(available) > 1:
    diff_area = [(i, t) for i, t in available if t.get('body_area', '') != last_area]
    if diff_area: available = diff_area
idx, tip = random.choice(available)
shown['indices'] = shown.get('indices', []) + [idx]
json.dump(shown, open(shown_file, 'w'))
print(tip['text']); print('---SEP---'); print(tip.get('body_area', 'general'))
" 2>/dev/null || echo "Take a moment to stretch and breathe.
---SEP---
general")

  TIP_TEXT=$(echo "$TIP_RESULT" | sed -n '1p')
  TIP_BODY_AREA=$(echo "$TIP_RESULT" | sed -n '3p')

  NUDGES_SINCE_BREAK=$((NUDGES_SINCE_BREAK + 1))
  TODAY_NUDGES=$((TODAY_NUDGES + 1))

  OUTPUT="[WAVE_HEALTH_NUDGE]
RENDERING: You are Wave, a developer health companion. START your response with a health nudge, THEN blank line, THEN address the user's coding question.

YOUR JOB: Read the user's prompt and conversation history. Understand what they're working on, how they're feeling. Craft a health nudge that speaks to THEIR moment.

FORMAT by tier (tier = how many nudges ignored since last break):
- tier 1: one italic line. *emoji Wave: [contextual tip]*. First nudge, be friendly.
- tier 2: --- then Wave Health + small ASCII + tip. Second nudge, light sarcasm.
- tier 3: --- then full block: ASCII art, body battery, personalized tip. Getting serious.
- tier 4: --- then urgent block: big ASCII, body battery, strong message. Full roast.

RULES:
- Rewrite the base_tip to match their actual context (read the prompt).
- Higher tier = more urgent tone. Tier 4 = 'I've asked you 4 times.'
- If auto_break_detected is true, celebrate the break instead.

tier: ${NUDGE_TIER}
nudges_since_break: ${NUDGES_SINCE_BREAK}
session_duration_min: ${SESSION_MINUTES}
today_nudges: ${TODAY_NUDGES}
today_breaks: ${TODAY_BREAKS}
sass_level: ${SASS_LEVEL}
body_battery: ${BODY_BATTERY}
coding_streak_days: ${CONSECUTIVE_DAYS}
base_tip: ${TIP_TEXT}"

  [ -n "$ACTIVE_PROJECTS" ] && OUTPUT="${OUTPUT}
active_projects: ${ACTIVE_PROJECTS}"
  [ "$PARALLEL_SESSIONS" -gt 1 ] && OUTPUT="${OUTPUT}
parallel_sessions: ${PARALLEL_SESSIONS}"
  [ "$FRUSTRATION_SCORE" -ge 2 ] && OUTPUT="${OUTPUT}
frustrated_prompts_in_row: ${FRUSTRATED_STREAK}"
  [ "$IS_STUCK" = "true" ] && OUTPUT="${OUTPUT}
user_is_stuck: true"
  [ "$PROJECT_SWITCHED" = "true" ] && OUTPUT="${OUTPUT}
project_switched: true
previous_project: $(basename "$LAST_PROJECT")
current_project: $PROJECT_BASE"
  [ "$BREAK_TYPE" = "real" ] && OUTPUT="${OUTPUT}
auto_break_detected: true
break_duration_min: ${BREAK_DURATION_MIN}"
  [ "$CURRENT_STRETCH" -gt 0 ] && OUTPUT="${OUTPUT}
current_unbroken_stretch_min: ${CURRENT_STRETCH}"
  [ "$BURNOUT_WARNING" = "true" ] && OUTPUT="${OUTPUT}
burnout_warning: true"

  if [ "$SESSION_GREETED" = "false" ]; then
    OUTPUT="${OUTPUT}
first_prompt_of_session: true
hour: $HOUR_NUM"
    [ "$CONSECUTIVE_DAYS" -ge 3 ] && OUTPUT="${OUTPUT}
coding_streak_days: $CONSECUTIVE_DAYS"
    SESSION_GREETED="true"
  fi

  OUTPUT="${OUTPUT}
[/WAVE_HEALTH_NUDGE]"
  echo "$OUTPUT"

  # Telemetry: nudge fired (backgrounded, silent)
  bash "$TELEMETRY_SCRIPT" nudge "tier=$NUDGE_TIER" "nudges_since_break=$NUDGES_SINCE_BREAK" \
    "body_battery=$BODY_BATTERY" "sass_level=$SASS_LEVEL" "hour=$HOUR_NUM" \
    "coding_streak_days=$CONSECUTIVE_DAYS" "today_breaks=$TODAY_BREAKS" &

  NUDGE_LATE_HOUR="$LAST_LATE_HOUR"
  write_state "$SESSION_GREETED" "$LAST_COMPANION_TS" "$LAST_MILESTONE_MIN" \
    "$NUDGE_LATE_HOUR" "$LAST_SUCCESS_TS" "$LAST_MOOD_SUPPORT_TS" \
    "$STREAK_SHOWN" "$NOW" "$TODAY" "0" "$TIP_BODY_AREA"
  exit 0
fi

# ─────────────────────────────────────────────────────────────────
# PATH B: Companion touch
# ─────────────────────────────────────────────────────────────────
if [ -n "$COMPANION_TYPE" ]; then

  NEW_GREETED="$SESSION_GREETED"
  NEW_COMPANION_TS="$NOW"
  NEW_MILESTONE="$LAST_MILESTONE_MIN"
  NEW_LATE_HOUR="$LAST_LATE_HOUR"
  NEW_SUCCESS_TS="$LAST_SUCCESS_TS"
  NEW_MOOD_TS="$LAST_MOOD_SUPPORT_TS"
  NEW_STREAK_SHOWN="$STREAK_SHOWN"

  case "$COMPANION_TYPE" in
    session_start) NEW_GREETED="true" ;;
    success) NEW_SUCCESS_TS="$NOW" ;;
    frustration_support) NEW_MOOD_TS="$NOW" ;;
    late_night|deep_night) NEW_LATE_HOUR="$HOUR_NUM" ;;
    milestone) NEW_MILESTONE="$SESSION_MINUTES" ;;
    streak) NEW_STREAK_SHOWN="$CONSECUTIVE_DAYS" ;;
  esac

  COMPANION_CONTEXT=""
  [ -n "$ACTIVE_PROJECTS" ] && COMPANION_CONTEXT="${COMPANION_CONTEXT}
active_projects: $ACTIVE_PROJECTS"
  [ "$PARALLEL_SESSIONS" -gt 1 ] && COMPANION_CONTEXT="${COMPANION_CONTEXT}
parallel_sessions: $PARALLEL_SESSIONS"

  case "$COMPANION_TYPE" in
    session_start)
      EXTRA=""
      if [ "$DOW" -ge 6 ]; then
        DAY_NAME=$(date +%A)
        EXTRA="${EXTRA}
weekend: $DAY_NAME"
      fi
      [ "$CONSECUTIVE_DAYS" -ge 3 ] && EXTRA="${EXTRA}
coding_streak_days: $CONSECUTIVE_DAYS"
      [ "$RETURNING_AFTER_BREAK" = "true" ] && EXTRA="${EXTRA}
returning: true
away_min: $BREAK_SINCE_LAST_MIN"
      [ "$BURNOUT_WARNING" = "true" ] && EXTRA="${EXTRA}
burnout_warning: true"
      [ "$LAST_SESSION_DURATION" -gt 0 ] && EXTRA="${EXTRA}
last_session_duration_min: $LAST_SESSION_DURATION"
      [ -n "$LAST_SESSION_PROJECT" ] && [ "$LAST_SESSION_PROJECT" != "unknown" ] && EXTRA="${EXTRA}
last_session_project: $LAST_SESSION_PROJECT"
      [ -n "$PREV_MOOD" ] && [ "$PREV_MOOD" != "neutral" ] && EXTRA="${EXTRA}
last_session_mood: $PREV_MOOD"
      [ "$BREAK_SINCE_LAST_MIN" -gt 0 ] && EXTRA="${EXTRA}
break_since_last_min: $BREAK_SINCE_LAST_MIN"
      cat <<EOCOMP
[WAVE_COMPANION]
RENDERING: You are Wave. This is a NEW session. START with a welcome (1-2 lines, casual). Reference last session context if available. Then blank line, then address their question.
type: session_start
hour: $HOUR_NUM
consecutive_coding_days: $CONSECUTIVE_DAYS$EXTRA$COMPANION_CONTEXT
[/WAVE_COMPANION]
EOCOMP
      ;;
    break_return)
      cat <<EOCOMP
[WAVE_COMPANION]
RENDERING: You are Wave. START with a brief break celebration (1 line). Mention the duration. Then blank line, then address their question.
type: break_return
break_duration_min: $BREAK_DURATION_MIN
today_breaks: $TODAY_BREAKS$COMPANION_CONTEXT
[/WAVE_COMPANION]
EOCOMP
      ;;
    success)
      cat <<EOCOMP
[WAVE_COMPANION]
RENDERING: You are Wave. START with a brief celebration (1 line). Be specific about WHAT succeeded. Then blank line, then address their question.
type: success
session_duration_min: $SESSION_MINUTES$COMPANION_CONTEXT
[/WAVE_COMPANION]
EOCOMP
      ;;
    frustration_support)
      cat <<EOCOMP
[WAVE_COMPANION]
RENDERING: You are Wave. START with empathy about the SPECIFIC problem (1-2 lines). Then blank line, then address their question with extra care.
type: frustration_support
frustrated_prompts_in_row: $FRUSTRATED_STREAK
body_battery: $BODY_BATTERY$COMPANION_CONTEXT
[/WAVE_COMPANION]
EOCOMP
      ;;
    late_night)
      cat <<EOCOMP
[WAVE_COMPANION]
RENDERING: You are Wave. START with gentle time awareness (1 line). Then blank line, then address their question.
type: late_night
hour: $HOUR_NUM
session_duration_min: $SESSION_MINUTES$COMPANION_CONTEXT
[/WAVE_COMPANION]
EOCOMP
      ;;
    deep_night)
      cat <<EOCOMP
[WAVE_COMPANION]
RENDERING: You are Wave. It's past midnight. START with a direct, caring time check (1 line). Then blank line, then address their question.
type: deep_night
hour: $HOUR_NUM
session_duration_min: $SESSION_MINUTES$COMPANION_CONTEXT
[/WAVE_COMPANION]
EOCOMP
      ;;
    milestone)
      cat <<EOCOMP
[WAVE_COMPANION]
RENDERING: START with a milestone check-in (1 line). Mention time and breaks. Then blank line, then address their question.
type: milestone
session_duration_min: $SESSION_MINUTES
today_breaks: $TODAY_BREAKS
body_battery: $BODY_BATTERY
[/WAVE_COMPANION]
EOCOMP
      ;;
    streak)
      cat <<EOCOMP
[WAVE_COMPANION]
RENDERING: START with a streak acknowledgment (1 line). $([ "$CONSECUTIVE_DAYS" -ge 7 ] && echo "Gently mention rest days.") Then blank line, then address their question.
type: streak
consecutive_days: $CONSECUTIVE_DAYS
[/WAVE_COMPANION]
EOCOMP
      ;;
  esac

  SG_VAL="false"
  [ "$NEW_GREETED" = "true" ] && SG_VAL="true"
  write_state "$SG_VAL" "$NEW_COMPANION_TS" "$NEW_MILESTONE" \
    "$NEW_LATE_HOUR" "$NEW_SUCCESS_TS" "$NEW_MOOD_TS" \
    "$NEW_STREAK_SHOWN" "$LAST_NUDGE" "${LAST_NUDGE_DATE:-$TODAY}" \
    "$PROMPT_COUNT" "$LAST_BODY_AREA"
  exit 0
fi

# ─────────────────────────────────────────────────────────────────
# PATH C: Silent
# ─────────────────────────────────────────────────────────────────
write_state "$SESSION_GREETED" "$LAST_COMPANION_TS" "$LAST_MILESTONE_MIN" \
  "$LAST_LATE_HOUR" "$LAST_SUCCESS_TS" "$LAST_MOOD_SUPPORT_TS" \
  "$STREAK_SHOWN" "$LAST_NUDGE" "${LAST_NUDGE_DATE:-$TODAY}" \
  "$PROMPT_COUNT" "$LAST_BODY_AREA"
exit 0
