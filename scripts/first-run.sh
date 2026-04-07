#!/bin/bash
# Rox — First run analysis
# Scans existing Claude Code sessions to build an instant health profile.
# Output is injected as system context — Claude presents it as a welcome message.
#
# Only runs ONCE (creates ~/.wave-dev-health/.onboarded marker).
# Must complete in <5 seconds.

set -euo pipefail

STATE_DIR="$HOME/.wave-dev-health"
ONBOARDED_FILE="$STATE_DIR/.onboarded"

# Skip if already onboarded
if [ -f "$ONBOARDED_FILE" ]; then
  exit 0
fi

mkdir -p "$STATE_DIR/sessions"

# Check if Claude Code sessions exist
SESSIONS_DIR="$HOME/.claude/projects"
if [ ! -d "$SESSIONS_DIR" ]; then
  # No session history — show basic welcome
  cat <<'WELCOME'
[WAVE_HEALTH_WELCOME]
type: new_user
message: This is your first time using Claude Code (or no session history found). Rox is now running in the background. As you code, it will learn your patterns and nudge you with health tips at the right moments. No setup needed. Just code.
commands: /pulse (stats), /pulse dashboard (visual), /pulse report (weekly), /pulse break (log a break)
[/WAVE_HEALTH_WELCOME]
WELCOME
  touch "$ONBOARDED_FILE"
  exit 0
fi

# ── Analyze existing sessions ────────────────────────────────────
# Uses python for speed over complex bash parsing
ANALYSIS=$(python3 << 'PYEOF'
import json, os, glob, datetime, collections

base = os.path.expanduser("~/.claude/projects")
sessions = []
ist = datetime.timedelta(hours=5, minutes=30)

for f in glob.glob(f"{base}/*/*.jsonl"):
    try:
        stat = os.stat(f)
        if stat.st_size < 2000:
            continue

        first_ts = None
        last_ts = None
        user_msgs = 0
        user_texts = []

        with open(f, 'r') as fh:
            for line in fh:
                try:
                    obj = json.loads(line.strip())
                    ts = obj.get("timestamp")
                    if ts:
                        if first_ts is None: first_ts = ts
                        last_ts = ts
                    if obj.get("type") == "user":
                        user_msgs += 1
                        content = obj.get("message", {}).get("content", "")
                        if isinstance(content, str):
                            user_texts.append(content.lower()[:200])
                        elif isinstance(content, list):
                            for b in content:
                                if isinstance(b, dict) and b.get("type") == "text":
                                    user_texts.append(b.get("text", "").lower()[:200])
                except:
                    pass

        if not first_ts or user_msgs < 3:
            continue

        start = datetime.datetime.fromisoformat(first_ts.replace("Z", "+00:00"))
        end = datetime.datetime.fromisoformat(last_ts.replace("Z", "+00:00"))
        dur = (end - start).total_seconds() / 60
        if dur < 3:
            continue

        # Calculate active time (gaps < 30 min)
        start_ist = start + ist

        # Mood detection
        all_text = " ".join(user_texts)
        frustrated = sum(1 for kw in ["error","bug","broken","not working","why is","fails","crash","stuck","confused"] if kw in all_text)
        building = sum(1 for kw in ["add","create","implement","build","write","new"] if kw in all_text)
        shipping = sum(1 for kw in ["ship","deploy","push","commit","merge","pr "] if kw in all_text)

        if frustrated > building and frustrated > 3:
            mood = "frustrated"
        elif shipping > 2:
            mood = "shipping"
        elif building > frustrated:
            mood = "building"
        else:
            mood = "mixed"

        sessions.append({
            "date": start_ist.strftime("%Y-%m-%d"),
            "hour": start_ist.hour,
            "dow": start_ist.strftime("%A"),
            "dur": round(dur),
            "msgs": user_msgs,
            "mood": mood,
            "frustrated": frustrated,
        })
    except:
        pass

if not sessions:
    print("NO_DATA")
    exit()

sessions.sort(key=lambda x: x["date"])

# ── Compute stats ────────────────────────────────────────────────
total = len(sessions)
dates = set(s["date"] for s in sessions)
date_range_days = max(1, (datetime.datetime.strptime(max(dates), "%Y-%m-%d") -
                          datetime.datetime.strptime(min(dates), "%Y-%m-%d")).days + 1)
active_days = len(dates)

# Time of day
by_hour = collections.Counter(s["hour"] for s in sessions)
peak_hours = sorted(by_hour.items(), key=lambda x: -x[1])[:3]
peak_str = ", ".join(f"{h}:00" for h, _ in peak_hours)

# Late night
late = sum(1 for s in sessions if s["hour"] >= 23 or s["hour"] < 5)
late_pct = round(late / total * 100)

# Weekends
weekends = sum(1 for s in sessions if s["dow"] in ("Saturday", "Sunday"))
weekend_pct = round(weekends / total * 100)

# Mood
moods = collections.Counter(s["mood"] for s in sessions)
building_pct = round(moods.get("building", 0) / total * 100)
frustrated_pct = round(moods.get("frustrated", 0) / total * 100)
shipping_pct = round(moods.get("shipping", 0) / total * 100)

# Frustrated session duration vs building
frust_sessions = [s for s in sessions if s["mood"] == "frustrated"]
build_sessions = [s for s in sessions if s["mood"] == "building"]
frust_avg_dur = round(sum(s["dur"] for s in frust_sessions) / max(len(frust_sessions), 1))
build_avg_dur = round(sum(s["dur"] for s in build_sessions) / max(len(build_sessions), 1))
frust_ratio = round(frust_avg_dur / max(build_avg_dur, 1), 1)

# Consecutive days
sorted_dates = sorted(dates)
max_streak = 1
current_streak = 1
for i in range(1, len(sorted_dates)):
    d1 = datetime.datetime.strptime(sorted_dates[i-1], "%Y-%m-%d")
    d2 = datetime.datetime.strptime(sorted_dates[i], "%Y-%m-%d")
    if (d2 - d1).days == 1:
        current_streak += 1
        max_streak = max(max_streak, current_streak)
    else:
        current_streak = 1

# Day of week
dow_count = collections.Counter(s["dow"] for s in sessions)
busiest_day = dow_count.most_common(1)[0][0]
quietest_day = dow_count.most_common()[-1][0]

# Long sessions (>2h)
long_sessions = sum(1 for s in sessions if s["dur"] > 120)
long_pct = round(long_sessions / total * 100)

# Output as structured data
print(f"total_sessions: {total}")
print(f"date_range_days: {date_range_days}")
print(f"active_days: {active_days}")
print(f"active_pct: {round(active_days / date_range_days * 100)}")
print(f"peak_hours: {peak_str}")
print(f"late_night_pct: {late_pct}")
print(f"weekend_pct: {weekend_pct}")
print(f"building_pct: {building_pct}")
print(f"frustrated_pct: {frustrated_pct}")
print(f"shipping_pct: {shipping_pct}")
print(f"frust_avg_dur: {frust_avg_dur}")
print(f"build_avg_dur: {build_avg_dur}")
print(f"frust_ratio: {frust_ratio}")
print(f"max_streak: {max_streak}")
print(f"busiest_day: {busiest_day}")
print(f"quietest_day: {quietest_day}")
print(f"long_session_pct: {long_pct}")
print(f"first_date: {sessions[0]['date']}")
print(f"last_date: {sessions[-1]['date']}")

PYEOF
) || ANALYSIS="NO_DATA"

if [ "$ANALYSIS" = "NO_DATA" ] || [ -z "$ANALYSIS" ]; then
  cat <<'WELCOME'
[WAVE_HEALTH_WELCOME]
type: new_user
message: Rox is now active. It will learn your coding patterns and nudge you with health tips at the right moments. No setup needed.
commands: /pulse (stats), /pulse dashboard (visual), /pulse report (weekly), /pulse break (log a break)
[/WAVE_HEALTH_WELCOME]
WELCOME
  touch "$ONBOARDED_FILE"
  exit 0
fi

# ── Output the welcome with analysis ─────────────────────────────
cat <<EOWELCOME
[WAVE_HEALTH_WELCOME]
type: returning_user_with_history
analysis:
$ANALYSIS

instructions_for_claude: |
  This is the user's FIRST time with Rox. Present their coding health
  profile as a personalized welcome message. Make it feel like "whoa, it already
  knows me." Use the analysis data above to generate a profile that covers:

  1. OVERVIEW: "{total_sessions} sessions over {date_range_days} days. You code
     {active_pct}% of days." One sentence establishing you've seen their history.

  2. YOUR PATTERN: When they code (peak hours), which days are heaviest/lightest,
     late night percentage. Be specific with their numbers.

  3. YOUR MOODS: Building vs debugging vs frustrated breakdown. If frustrated
     sessions are significantly longer than building sessions, call it out:
     "Your frustrated sessions last {frust_ratio}x longer. That's the #1 thing
     this plugin will help with."

  4. WHAT I SPOTTED: 2-3 specific observations that feel personal. Examples:
     - "Your longest coding streak was {max_streak} days straight with no rest."
     - "{late_night_pct}% of your sessions start after 11pm."
     - "{long_session_pct}% of sessions go over 2 hours without a break."
     Pick the ones that are most striking for THIS user's data.

  5. WHAT HAPPENS NOW: Brief explanation. "I'm running in the background now.
     Micro eye-break nudges at 20 min. Hydration at 35. Full stretch at 50.
     If I detect you're frustrated or stuck, I'll intervene earlier. If you're
     in flow and shipping, I'll stay quiet longer."

  6. COMMANDS: Show /pulse, /pulse dashboard, /pulse break, /pulse report.

  Format as a clean, warm welcome. Not a wall of stats. Pick the 3-4 most
  interesting numbers and weave them into a narrative. End with "Let's code."

  DO NOT show this raw data to the user. Transform it into a conversational
  welcome message.
[/WAVE_HEALTH_WELCOME]
EOWELCOME

# Mark as onboarded
touch "$ONBOARDED_FILE"

exit 0
