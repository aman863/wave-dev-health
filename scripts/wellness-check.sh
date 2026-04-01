#!/bin/bash
# Wave Dev Health — Background wellness checker
# Runs on UserPromptSubmit hook. Stdout is injected as system context to Claude.
# Must be fast (<20ms). Reads local state, checks timer, outputs nudge if due.

set -euo pipefail

STATE_DIR="$HOME/.wave-dev-health"
STATE_FILE="$STATE_DIR/state.json"
TIPS_FILE="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$0")")}/src/tips.json"
ENERGY_FILE="$STATE_DIR/energy.json"
CONFIG_FILE="$STATE_DIR/config.json"

NUDGE_INTERVAL=3000  # 50 minutes in seconds
TODAY=$(date +%Y-%m-%d)
NOW=$(date +%s)

# Ensure state directory exists
mkdir -p "$STATE_DIR/sessions"

# ── Read config (disabled check) ──────────────────────────────────
if [ -f "$CONFIG_FILE" ]; then
  DISABLED=$(grep -o '"disabled":[a-z]*' "$CONFIG_FILE" 2>/dev/null | grep -o 'true' || true)
  if [ "$DISABLED" = "true" ]; then
    exit 0
  fi
  # Read custom interval if set
  CUSTOM_INTERVAL=$(grep -o '"nudge_interval":[0-9]*' "$CONFIG_FILE" 2>/dev/null | grep -o '[0-9]*' || true)
  if [ -n "$CUSTOM_INTERVAL" ] && [ "$CUSTOM_INTERVAL" -gt 0 ] 2>/dev/null; then
    NUDGE_INTERVAL=$CUSTOM_INTERVAL
  fi
fi

# ── Read state ────────────────────────────────────────────────────
LAST_NUDGE=0
LAST_TIP_INDEX=0
LAST_NUDGE_DATE=""
SESSION_START=0

if [ -f "$STATE_FILE" ]; then
  # Parse state.json with grep (no jq dependency)
  LAST_NUDGE=$(grep -o '"last_nudge":[0-9]*' "$STATE_FILE" 2>/dev/null | grep -o '[0-9]*' || echo "0")
  LAST_TIP_INDEX=$(grep -o '"last_tip_index":[0-9]*' "$STATE_FILE" 2>/dev/null | grep -o '[0-9]*' || echo "0")
  LAST_NUDGE_DATE=$(grep -o '"last_nudge_date":"[^"]*"' "$STATE_FILE" 2>/dev/null | grep -o '"[^"]*"$' | tr -d '"' || echo "")
  SESSION_START=$(grep -o '"session_start":[0-9]*' "$STATE_FILE" 2>/dev/null | grep -o '[0-9]*' || echo "0")
fi

# First ever run: initialize session start
if [ "$SESSION_START" -eq 0 ]; then
  SESSION_START=$NOW
fi

ELAPSED=$(( NOW - LAST_NUDGE ))

# ── Not time yet? Exit silently ───────────────────────────────────
if [ "$ELAPSED" -lt "$NUDGE_INTERVAL" ]; then
  # Still update session_start if it was 0
  if ! [ -f "$STATE_FILE" ]; then
    TMPFILE=$(mktemp "$STATE_DIR/state.XXXXXX")
    cat > "$TMPFILE" <<EOJSON
{"version":1,"last_nudge":0,"last_tip_index":0,"last_nudge_date":"","session_start":$NOW,"today_nudges":0,"today_breaks":0}
EOJSON
    mv "$TMPFILE" "$STATE_FILE"
  fi
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
TMPFILE=$(mktemp "$STATE_DIR/state.XXXXXX")
cat > "$TMPFILE" <<EOJSON
{"version":1,"last_nudge":$NOW,"last_tip_index":$NEXT_INDEX,"last_nudge_date":"$TODAY","session_start":$SESSION_START,"today_nudges":$TODAY_NUDGES,"today_breaks":$TODAY_BREAKS}
EOJSON
mv "$TMPFILE" "$STATE_FILE"

exit 0
