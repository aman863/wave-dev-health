#!/bin/bash
# Rox — Record when Claude finishes responding
# Runs on Stop hook (silent, no stdout). Writes timestamp to state.
# This lets wellness-check.sh compute ACTUAL idle time:
#   idle = next_user_prompt - claude_finished (not - last_user_prompt)
STATE_DIR="$HOME/.wave-dev-health"
STATE_FILE="$STATE_DIR/state.json"
NOW=$(date +%s)

[ -d "$STATE_DIR" ] || exit 0
[ -f "$STATE_FILE" ] || exit 0

# Touch global_active so cross-session idle time stays accurate
# (Claude finishing = the user can now be truly idle)
touch "$STATE_DIR/global_active" 2>/dev/null || true

# Write claude_done_ts to state using atomic write
python3 -c "
import json, os
f = '$STATE_FILE'
try:
    d = json.load(open(f))
except:
    d = {}
d['claude_done_ts'] = $NOW
json.dump(d, open(f + '.tmp', 'w'), separators=(',', ':'))
os.rename(f + '.tmp', f)
" 2>/dev/null || true

exit 0
