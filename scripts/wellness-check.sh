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

# ── Nudge tier intervals (based on health research) ──────────────
# Different nudge types fire at different intervals. Lighter nudges
# (eyes, hydration) come more often. Heavier ones (full break) less.
#
#   Tier 1 — Micro-nudge (eyes, breathing):   20 min  (20-20-20 rule)
#   Tier 2 — Light nudge (hydration, posture): 35 min
#   Tier 3 — Full nudge (stretch, movement):   50 min
#   Tier 4 — Break nudge (stand up, walk):     90 min
#
# The script picks the HIGHEST tier that's due. If Tier 3 fires,
# it replaces what would have been a Tier 1 nudge.

TIER1_INTERVAL=1200   # 20 min — eyes, breathing (micro, 1 sentence)
TIER2_INTERVAL=2100   # 35 min — hydration, posture (light, 1-2 sentences)
TIER3_INTERVAL=3000   # 50 min — stretch, movement (full tip)
TIER4_INTERVAL=5400   # 90 min — full break (stand up and walk)

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
# Evaluate tier thresholds + context signals on every prompt.
# Pick the highest tier that's due. Context signals can promote
# a tier (nudge sooner) or add urgency.

SHOULD_NUDGE="false"
NUDGE_REASON=""
NUDGE_TIER=0

# Read custom interval overrides from config
if [ -n "${CUSTOM_INTERVAL:-}" ]; then
  TIER3_INTERVAL=$CUSTOM_INTERVAL
fi

# ── Tier selection: highest due tier wins ─────────────────────────

# Tier 4: Full break (90 min without any break)
if [ "$ELAPSED_SINCE_BREAK" -ge "$TIER4_INTERVAL" ] && [ "$ELAPSED_SINCE_NUDGE" -ge "$TIER1_INTERVAL" ]; then
  SHOULD_NUDGE="true"
  NUDGE_TIER=4
  NUDGE_REASON="full_break"
fi

# Tier 3: Full nudge (50 min since last nudge)
if [ "$NUDGE_TIER" -lt 3 ] && [ "$ELAPSED_SINCE_NUDGE" -ge "$TIER3_INTERVAL" ]; then
  SHOULD_NUDGE="true"
  NUDGE_TIER=3
  NUDGE_REASON="regular_interval"
fi

# Tier 2: Light nudge (35 min — hydration, posture)
if [ "$NUDGE_TIER" -lt 2 ] && [ "$ELAPSED_SINCE_NUDGE" -ge "$TIER2_INTERVAL" ]; then
  SHOULD_NUDGE="true"
  NUDGE_TIER=2
  NUDGE_REASON="light_reminder"
fi

# Tier 1: Micro-nudge (20 min — eyes, breathing)
if [ "$NUDGE_TIER" -lt 1 ] && [ "$ELAPSED_SINCE_NUDGE" -ge "$TIER1_INTERVAL" ]; then
  SHOULD_NUDGE="true"
  NUDGE_TIER=1
  NUDGE_REASON="micro_nudge"
fi

# ── Context signals: can override tier or add urgency ─────────────

# High intensity (30+ prompts since last nudge) — promote to at least Tier 2
if [ "$PROMPT_COUNT" -ge 30 ] && [ "$ELAPSED_SINCE_NUDGE" -ge "$TIER1_INTERVAL" ]; then
  SHOULD_NUDGE="true"
  if [ "$NUDGE_TIER" -lt 2 ]; then
    NUDGE_TIER=2
  fi
  NUDGE_REASON="high_intensity"
fi

# Late night (after 11pm or before 5am) — promote to at least Tier 2
if [ "$HOUR" -ge 23 ] || [ "$HOUR" -lt 5 ]; then
  if [ "$ELAPSED_SINCE_NUDGE" -ge "$TIER1_INTERVAL" ] && [ "$NUDGE_TIER" -ge 1 ]; then
    if [ "$NUDGE_TIER" -lt 2 ]; then
      NUDGE_TIER=2
    fi
    NUDGE_REASON="late_night"
  fi
fi

# Break deficit (3+ nudges, 0 breaks today) — promote to at least Tier 3
if [ "$TODAY_NUDGES" -ge 3 ] && [ "$TODAY_BREAKS" -eq 0 ] && [ "$ELAPSED_SINCE_NUDGE" -ge "$TIER1_INTERVAL" ]; then
  SHOULD_NUDGE="true"
  if [ "$NUDGE_TIER" -lt 3 ]; then
    NUDGE_TIER=3
  fi
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

# ── Select a tip matching the current tier ────────────────────────
# Tips are tagged with tiers 1-4. Pick a random tip from the current
# tier. If none match, fall back to any tip.

TIP_RESULT=$(python3 -c "
import json, random
try:
    tips = json.load(open('$TIPS_FILE'))
    tier_tips = [t for t in tips if t.get('tier', 3) == $NUDGE_TIER]
    if not tier_tips:
        tier_tips = tips  # fallback to any tip
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
NEXT_INDEX=$LAST_TIP_INDEX  # Not strictly sequential anymore, but keep for state compat

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
tier: ${NUDGE_TIER}
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
