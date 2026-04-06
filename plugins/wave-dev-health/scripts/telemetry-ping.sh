#!/bin/bash
# Wave Dev Health — Telemetry ping
# Sends anonymous usage events. No prompts, no code, no project names.
# Only runs if telemetry is enabled in config.json.
# Always backgrounded, silent, fire-and-forget.

STATE_DIR="$HOME/.wave-dev-health"
CONFIG_FILE="$STATE_DIR/config.json"
TELEMETRY_LOG="$STATE_DIR/telemetry.jsonl"
ENDPOINT_FILE="$STATE_DIR/telemetry_endpoint"

# Check if telemetry is enabled
TELEMETRY="false"
if [ -f "$CONFIG_FILE" ]; then
  TELEMETRY=$(python3 -c "import json; print('true' if json.load(open('$CONFIG_FILE')).get('telemetry') else 'false')" 2>/dev/null || echo "false")
fi
[ "$TELEMETRY" != "true" ] && exit 0

# Read event from args
EVENT_TYPE="${1:-unknown}"  # install, nudge, break, companion
shift

# Build event JSON
EVENT=$(python3 -c "
import json, sys, platform, time

event = {
    'event': '$EVENT_TYPE',
    'ts': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
    'os': platform.system().lower(),
    'arch': platform.machine(),
}

# Parse key=value args
for arg in sys.argv[1:]:
    if '=' in arg:
        k, v = arg.split('=', 1)
        try: v = int(v)
        except: pass
        if v == 'true': v = True
        elif v == 'false': v = False
        event[k] = v

print(json.dumps(event, separators=(',', ':')))
" "$@" 2>/dev/null)

[ -z "$EVENT" ] && exit 0

# Always log locally
echo "$EVENT" >> "$TELEMETRY_LOG" 2>/dev/null || true

# Rotate local log (keep last 1000 events)
if [ -f "$TELEMETRY_LOG" ]; then
  LINES=$(wc -l < "$TELEMETRY_LOG" 2>/dev/null | tr -d ' ')
  [ "$LINES" -gt 1000 ] && { tail -500 "$TELEMETRY_LOG" > "$TELEMETRY_LOG.tmp" && mv "$TELEMETRY_LOG.tmp" "$TELEMETRY_LOG"; }
fi

# Remote ping (if endpoint configured)
if [ -f "$ENDPOINT_FILE" ]; then
  ENDPOINT=$(cat "$ENDPOINT_FILE" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$ENDPOINT" ]; then
    curl -s -X POST "$ENDPOINT" \
      -H "Content-Type: application/json" \
      -d "$EVENT" \
      --max-time 3 \
      > /dev/null 2>&1 || true
  fi
fi

exit 0
