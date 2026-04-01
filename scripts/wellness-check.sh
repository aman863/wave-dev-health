#!/bin/bash
# Wave Dev Health — Background wellness checker
# Runs on EVERY UserPromptSubmit. Stdout is injected as system context to Claude.
# Must be fast (<20ms). Evaluates multiple signals to decide if NOW is the right
# moment to nudge, not just a fixed timer.

set -euo pipefail

STATE_DIR="$HOME/.wave-dev-health"
STATE_FILE="$STATE_DIR/state.json"
TIPS_FILE="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$0")")}/src/tips.json"
ENERGY_FILE="$STATE_DIR/energy.json"
CONFIG_FILE="$STATE_DIR/config.json"
PROMPT_LOG="$STATE_DIR/prompt_log.json"

MIN_INTERVAL=1500    # 25 min — hard floor, never nudge more often than this
SOFT_INTERVAL=3000   # 50 min — default nudge interval for normal sessions
TODAY=$(date +%Y-%m-%d)
NOW=$(date +%s)
HOUR=$(date +%H)

# Ensure state directory exists
mkdir -p "$STATE_DIR/sessions"

# ── Read config (disabled check) ──────────────────────────────────
if [ -f "$CONFIG_FILE" ]; then
  DISABLED=$(grep -o '"disabled":[a-z]*' "$CONFIG_FILE" 2>/dev/null | grep -o 'true' || true)
  if [ "$DISABLED" = "true" ]; then
    exit 0
  fi
  # Read custom soft interval if set
  CUSTOM_INTERVAL=$(grep -o '"nudge_interval":[0-9]*' "$CONFIG_FILE" 2>/dev/null | grep -o '[0-9]*' || true)
  if [ -n "$CUSTOM_INTERVAL" ] && [ "$CUSTOM_INTERVAL" -gt 0 ] 2>/dev/null; then
    SOFT_INTERVAL=$CUSTOM_INTERVAL
  fi
fi

# ── Read state ────────────────────────────────────────────────────
LAST_NUDGE=0
LAST_TIP_INDEX=0
LAST_NUDGE_DATE=""
SESSION_START=0
LAST_BREAK=0
TODAY_NUDGES=0
TODAY_BREAKS=0
PROMPT_COUNT=0

if [ -f "$STATE_FILE" ]; then
  LAST_NUDGE=$(grep -o '"last_nudge":[0-9]*' "$STATE_FILE" 2>/dev/null | grep -o '[0-9]*' || echo "0")
  LAST_TIP_INDEX=$(grep -o '"last_tip_index":[0-9]*' "$STATE_FILE" 2>/dev/null | grep -o '[0-9]*' || echo "0")
  LAST_NUDGE_DATE=$(grep -o '"last_nudge_date":"[^"]*"' "$STATE_FILE" 2>/dev/null | grep -o '"[^"]*"$' | tr -d '"' || echo "")
  SESSION_START=$(grep -o '"session_start":[0-9]*' "$STATE_FILE" 2>/dev/null | grep -o '[0-9]*' || echo "0")
  LAST_BREAK=$(grep -o '"last_break":[0-9]*' "$STATE_FILE" 2>/dev/null | grep -o '[0-9]*' || echo "0")
  PROMPT_COUNT=$(grep -o '"prompt_count":[0-9]*' "$STATE_FILE" 2>/dev/null | grep -o '[0-9]*' || echo "0")
  if [ "$LAST_NUDGE_DATE" = "$TODAY" ]; then
    TODAY_NUDGES=$(grep -o '"today_nudges":[0-9]*' "$STATE_FILE" 2>/dev/null | grep -o '[0-9]*' || echo "0")
    TODAY_BREAKS=$(grep -o '"today_breaks":[0-9]*' "$STATE_FILE" 2>/dev/null | grep -o '[0-9]*' || echo "0")
  fi
fi

# First ever run: initialize session start
if [ "$SESSION_START" -eq 0 ]; then
  SESSION_START=$NOW
fi

# Increment prompt count (tracks activity intensity)
PROMPT_COUNT=$(( PROMPT_COUNT + 1 ))

ELAPSED_SINCE_NUDGE=$(( NOW - LAST_NUDGE ))
ELAPSED_SINCE_BREAK=$(( NOW - LAST_BREAK ))
SESSION_DURATION=$(( NOW - SESSION_START ))

# ── Smart nudge decision ─────────────────────────────────────────
# Instead of a single fixed timer, evaluate multiple signals.
# Each signal can lower the threshold (nudge sooner) or raise it.

SHOULD_NUDGE="false"
NUDGE_REASON=""

# Hard floor: never nudge more often than MIN_INTERVAL
if [ "$ELAPSED_SINCE_NUDGE" -lt "$MIN_INTERVAL" ]; then
  # Too soon. Just update prompt count and exit.
  TMPFILE=$(mktemp "$STATE_DIR/state.XXXXXX")
  cat > "$TMPFILE" <<EOJSON
{"version":1,"last_nudge":$LAST_NUDGE,"last_tip_index":$LAST_TIP_INDEX,"last_nudge_date":"$LAST_NUDGE_DATE","session_start":$SESSION_START,"today_nudges":$TODAY_NUDGES,"today_breaks":$TODAY_BREAKS,"last_break":$LAST_BREAK,"prompt_count":$PROMPT_COUNT}
EOJSON
  mv "$TMPFILE" "$STATE_FILE"
  exit 0
fi

# Signal 1: Standard interval elapsed (50 min default)
if [ "$ELAPSED_SINCE_NUDGE" -ge "$SOFT_INTERVAL" ]; then
  SHOULD_NUDGE="true"
  NUDGE_REASON="regular_interval"
fi

# Signal 2: Long session without any break (2+ hours since last break or session start)
if [ "$ELAPSED_SINCE_BREAK" -ge 7200 ] && [ "$ELAPSED_SINCE_NUDGE" -ge "$MIN_INTERVAL" ]; then
  SHOULD_NUDGE="true"
  NUDGE_REASON="long_no_break"
fi

# Signal 3: High intensity — lots of prompts since last nudge (30+ prompts = intense session)
# Read prompt count at last nudge to compute delta
PROMPTS_SINCE_NUDGE=$PROMPT_COUNT  # Simplified: total prompts as proxy
if [ "$PROMPTS_SINCE_NUDGE" -ge 30 ] && [ "$ELAPSED_SINCE_NUDGE" -ge "$MIN_INTERVAL" ]; then
  # Reset prompt count after nudge, so this is actually prompts since last nudge
  SHOULD_NUDGE="true"
  NUDGE_REASON="high_intensity"
fi

# Signal 4: Late night coding (after 11pm or before 5am) — nudge sooner (35 min)
if [ "$HOUR" -ge 23 ] || [ "$HOUR" -lt 5 ]; then
  if [ "$ELAPSED_SINCE_NUDGE" -ge 2100 ]; then  # 35 min
    SHOULD_NUDGE="true"
    NUDGE_REASON="late_night"
  fi
fi

# Signal 5: Break deficit — user has been ignoring nudges (3+ nudges, 0 breaks today)
if [ "$TODAY_NUDGES" -ge 3 ] && [ "$TODAY_BREAKS" -eq 0 ] && [ "$ELAPSED_SINCE_NUDGE" -ge "$MIN_INTERVAL" ]; then
  SHOULD_NUDGE="true"
  NUDGE_REASON="break_deficit"
fi

# ── Not time yet? Exit silently ───────────────────────────────────
if [ "$SHOULD_NUDGE" = "false" ]; then
  TMPFILE=$(mktemp "$STATE_DIR/state.XXXXXX")
  cat > "$TMPFILE" <<EOJSON
{"version":1,"last_nudge":$LAST_NUDGE,"last_tip_index":$LAST_TIP_INDEX,"last_nudge_date":"$LAST_NUDGE_DATE","session_start":$SESSION_START,"today_nudges":$TODAY_NUDGES,"today_breaks":$TODAY_BREAKS,"last_break":$LAST_BREAK,"prompt_count":$PROMPT_COUNT}
EOJSON
  mv "$TMPFILE" "$STATE_FILE"
  exit 0
fi

# ── Time for a nudge! ────────────────────────────────────────────

# Read tips
TIP_COUNT=0
if [ -f "$TIPS_FILE" ]; then
  TIP_COUNT=$(grep -c '"text"' "$TIPS_FILE" 2>/dev/null || echo "0")
fi

# Select next tip (rotate through the list)
if [ "$TIP_COUNT" -gt 0 ]; then
  # Reset index if new day
  if [ "$LAST_NUDGE_DATE" != "$TODAY" ]; then
    LAST_TIP_INDEX=0
  fi

  NEXT_INDEX=$(( (LAST_TIP_INDEX + 1) % TIP_COUNT ))

  # Extract the tip text at the given index
  # tips.json is an array of objects with "text", "category", "body_area" fields
  TIP_TEXT=$(python3 -c "
import json, sys
try:
    tips = json.load(open('$TIPS_FILE'))
    print(tips[$NEXT_INDEX]['text'])
except:
    print('Take a moment to stretch and breathe. Your body will thank you.')
" 2>/dev/null || echo "Take a moment to stretch and breathe. Your body will thank you.")

  TIP_CATEGORY=$(python3 -c "
import json, sys
try:
    tips = json.load(open('$TIPS_FILE'))
    print(tips[$NEXT_INDEX].get('category', 'general'))
except:
    print('general')
" 2>/dev/null || echo "general")
else
  NEXT_INDEX=0
  TIP_TEXT="Take a moment to stretch and breathe. Your body will thank you."
  TIP_CATEGORY="general"
fi

# Calculate session duration
SESSION_MINUTES=$(( (NOW - SESSION_START) / 60 ))

# Read today's nudge count
TODAY_NUDGES=0
if [ -f "$STATE_FILE" ] && [ "$LAST_NUDGE_DATE" = "$TODAY" ]; then
  TODAY_NUDGES=$(grep -o '"today_nudges":[0-9]*' "$STATE_FILE" 2>/dev/null | grep -o '[0-9]*' || echo "0")
fi
TODAY_NUDGES=$(( TODAY_NUDGES + 1 ))

# Read today's break count
TODAY_BREAKS=$(grep -o '"today_breaks":[0-9]*' "$STATE_FILE" 2>/dev/null | grep -o '[0-9]*' || echo "0")

# ── Output the nudge (injected as system context to Claude) ──────

OUTPUT="[WAVE_HEALTH_NUDGE]
session_duration_min: ${SESSION_MINUTES}
nudge_reason: ${NUDGE_REASON}
tip_category: ${TIP_CATEGORY}
tip: ${TIP_TEXT}
today_nudges: ${TODAY_NUDGES}
today_breaks: ${TODAY_BREAKS}
snooze_command: /pulse snooze 15m
break_command: /pulse break"

# Check if energy needs prompting (first nudge of day, no energy logged)
if [ "$LAST_NUDGE_DATE" != "$TODAY" ]; then
  HAS_ENERGY_TODAY="false"
  if [ -f "$ENERGY_FILE" ]; then
    HAS_ENERGY_TODAY=$(grep -c "\"$TODAY\"" "$ENERGY_FILE" 2>/dev/null | grep -v '^0$' > /dev/null 2>&1 && echo "true" || echo "false")
  fi
  if [ "$HAS_ENERGY_TODAY" = "false" ]; then
    OUTPUT="${OUTPUT}
energy_prompt: true
energy_command: /pulse energy [1-5]"
  fi
fi

OUTPUT="${OUTPUT}
[/WAVE_HEALTH_NUDGE]"

echo "$OUTPUT"

# ── Update state (atomic write) ──────────────────────────────────
# Reset prompt_count after nudge so Signal 3 measures from last nudge
TMPFILE=$(mktemp "$STATE_DIR/state.XXXXXX")
cat > "$TMPFILE" <<EOJSON
{"version":1,"last_nudge":$NOW,"last_tip_index":$NEXT_INDEX,"last_nudge_date":"$TODAY","session_start":$SESSION_START,"today_nudges":$TODAY_NUDGES,"today_breaks":$TODAY_BREAKS,"last_break":$LAST_BREAK,"prompt_count":0}
EOJSON
mv "$TMPFILE" "$STATE_FILE"

exit 0
