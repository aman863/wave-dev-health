#!/bin/bash
# Wave Dev Health — One-line installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/aman863/wave-dev-health/main/install.sh | bash

set -euo pipefail

INSTALL_DIR="$HOME/.wave-dev-health-plugin"
SETTINGS_FILE="$HOME/.claude/settings.json"
STATE_DIR="$HOME/.wave-dev-health"
SESSIONS_DIR="$HOME/.claude/projects"

echo ""
echo "  ╔══════════════════════════════════════╗"
echo "  ║     Wave Dev Health — Installer      ║"
echo "  ╚══════════════════════════════════════╝"
echo ""

# ── Step 1: Download ─────────────────────────────────────────────
if [ ! -d "$INSTALL_DIR/.claude-plugin" ]; then
  echo "  Downloading plugin..."
  if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
  fi
  git clone --depth 1 https://github.com/aman863/wave-dev-health.git "$INSTALL_DIR" 2>/dev/null
  echo "  ✓ Downloaded"
else
  echo "  ✓ Plugin already installed"
fi

# ── Step 2: Configure Claude Code ────────────────────────────────
echo "  Configuring Claude Code..."
mkdir -p "$(dirname "$SETTINGS_FILE")"

if [ -f "$SETTINGS_FILE" ]; then
  python3 -c "
import json
f = '$SETTINGS_FILE'
try:
    settings = json.load(open(f))
except:
    settings = {}
if 'extraKnownMarketplaces' not in settings:
    settings['extraKnownMarketplaces'] = {}
settings['extraKnownMarketplaces']['wave-dev-health'] = {
    'source': {'source': 'directory', 'path': '$INSTALL_DIR'}
}
if 'enabledPlugins' not in settings:
    settings['enabledPlugins'] = {}
settings['enabledPlugins']['wave-dev-health@wave-dev-health'] = True
json.dump(settings, open(f, 'w'), indent=2)
" 2>/dev/null && echo "  ✓ Settings updated" || echo "  ✗ Could not update settings.json"
else
  cat > "$SETTINGS_FILE" <<EOJSON
{
  "extraKnownMarketplaces": {
    "wave-dev-health": {
      "source": { "source": "directory", "path": "$INSTALL_DIR" }
    }
  },
  "enabledPlugins": {
    "wave-dev-health@wave-dev-health": true
  }
}
EOJSON
  echo "  ✓ Settings created"
fi

chmod +x "$INSTALL_DIR/scripts/"*.sh 2>/dev/null || true
mkdir -p "$STATE_DIR/sessions"

echo ""
echo "  ✓ Installed! Analyzing your coding sessions..."
echo ""

# ── Step 3: Analyze existing sessions ────────────────────────────
# This is the magic: instant value before they even open Claude Code.

python3 << 'PYEOF'
import json, os, glob, datetime, collections

base = os.path.expanduser("~/.claude/projects")
ist = datetime.timedelta(hours=5, minutes=30)
sessions = []

if not os.path.isdir(base):
    print("  No Claude Code sessions found yet.")
    print("  Start coding and Wave Dev Health will track your patterns.")
    print("")
    exit()

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

        start_ist = start + ist
        all_text = " ".join(user_texts)

        # Mood
        frust = sum(1 for kw in ["error","bug","broken","not working","why is","fails","crash","stuck","confused"] if kw in all_text)
        build = sum(1 for kw in ["add","create","implement","build","write","new"] if kw in all_text)
        ship = sum(1 for kw in ["ship","deploy","push","commit","merge"] if kw in all_text)

        if frust > build and frust > 3: mood = "frustrated"
        elif ship > 2: mood = "shipping"
        elif build > frust: mood = "building"
        else: mood = "mixed"

        sessions.append({
            "date": start_ist.strftime("%Y-%m-%d"),
            "hour": start_ist.hour,
            "dow": start_ist.strftime("%A"),
            "dur": round(dur),
            "msgs": user_msgs,
            "mood": mood,
        })
    except:
        pass

if not sessions:
    print("  No coding sessions found yet.")
    print("  Start coding and Wave Dev Health will track your patterns.")
    print("")
    exit()

sessions.sort(key=lambda x: x["date"])
total = len(sessions)
dates = set(s["date"] for s in sessions)
d1 = datetime.datetime.strptime(min(dates), "%Y-%m-%d")
d2 = datetime.datetime.strptime(max(dates), "%Y-%m-%d")
span = max(1, (d2 - d1).days + 1)
active_days = len(dates)

# Peak hours
by_hour = collections.Counter(s["hour"] for s in sessions)
peak = sorted(by_hour.items(), key=lambda x: -x[1])[:3]

# Late night
late = sum(1 for s in sessions if s["hour"] >= 23 or s["hour"] < 5)
late_pct = round(late / total * 100)

# Weekends
wknd = sum(1 for s in sessions if s["dow"] in ("Saturday", "Sunday"))

# Moods
moods = collections.Counter(s["mood"] for s in sessions)

# Frustrated vs building duration
frust_s = [s for s in sessions if s["mood"] == "frustrated"]
build_s = [s for s in sessions if s["mood"] == "building"]
frust_dur = round(sum(s["dur"] for s in frust_s) / max(len(frust_s), 1))
build_dur = round(sum(s["dur"] for s in build_s) / max(len(build_s), 1))
frust_ratio = round(frust_dur / max(build_dur, 1), 1) if frust_s else 0

# Consecutive days streak
sorted_dates = sorted(dates)
max_streak = 1
streak = 1
for i in range(1, len(sorted_dates)):
    dd1 = datetime.datetime.strptime(sorted_dates[i-1], "%Y-%m-%d")
    dd2 = datetime.datetime.strptime(sorted_dates[i], "%Y-%m-%d")
    if (dd2 - dd1).days == 1:
        streak += 1
        max_streak = max(max_streak, streak)
    else:
        streak = 1

# Long sessions
long = sum(1 for s in sessions if s["dur"] > 120)

# Day analysis
dow_count = collections.Counter(s["dow"] for s in sessions)
busiest = dow_count.most_common(1)[0]
quietest = dow_count.most_common()[-1]

# ── Print the profile ────────────────────────────────────────────

print("  ┌──────────────────────────────────────────────────┐")
print("  │          YOUR CODING HEALTH PROFILE              │")
print("  └──────────────────────────────────────────────────┘")
print("")
print(f"  📊 {total} sessions over {span} days")
print(f"     You coded {active_days} of those days ({round(active_days/span*100)}%)")
print("")

# Peak hours
peak_str = ", ".join(f"{h}:00" for h, _ in peak)
print(f"  ⏰ Peak hours: {peak_str}")
if late_pct > 10:
    print(f"  🌙 {late_pct}% of sessions start after 11pm")
if max_streak >= 5:
    print(f"  🔥 Longest streak: {max_streak} days straight without rest")
print("")

# Mood breakdown
build_pct = round(moods.get("building", 0) / total * 100)
frust_pct = round(moods.get("frustrated", 0) / total * 100)
ship_pct = round(moods.get("shipping", 0) / total * 100)
mix_pct = round(moods.get("mixed", 0) / total * 100)

print(f"  🔨 Building:    {build_pct}%  {'█' * (build_pct // 3)}")
print(f"  🔄 Mixed:       {mix_pct}%  {'█' * (mix_pct // 3)}")
print(f"  🚀 Shipping:    {ship_pct}%  {'█' * (ship_pct // 3)}")
print(f"  😤 Frustrated:  {frust_pct}%  {'█' * (frust_pct // 3)}")
print("")

# Key insight
if frust_ratio > 2 and len(frust_s) > 2:
    print(f"  ⚡ KEY INSIGHT: Your frustrated sessions last {frust_ratio}x longer")
    print(f"     than building sessions. When you're stuck, you grind for hours.")
    print(f"     That's the #1 thing this plugin will help with.")
    print("")
elif long > total * 0.1:
    long_pct = round(long / total * 100)
    print(f"  ⚡ KEY INSIGHT: {long_pct}% of your sessions go over 2 hours")
    print(f"     without a break. That's where RSI and eye strain accumulate.")
    print("")
elif max_streak >= 7:
    print(f"  ⚡ KEY INSIGHT: {max_streak} days straight with no rest day.")
    print(f"     Rest is when your brain consolidates what you learned.")
    print("")

print("  ┌──────────────────────────────────────────────────┐")
print("  │  WHAT HAPPENS NOW                                │")
print("  ├──────────────────────────────────────────────────┤")
print("  │                                                  │")
print("  │  🟢 Micro eye-break nudges every 20 min          │")
print("  │  💧 Hydration reminders every 35 min             │")
print("  │  🧘 Full stretch tips every 50 min               │")
print("  │  🚶 Break nudge at 90 min without a break        │")
print("  │                                                  │")
print("  │  😤 Frustration detected? Earlier intervention.  │")
print("  │  🚀 Shipping mode? Quieter nudges.               │")
print("  │  🌙 Late night? Gentler, more urgent.            │")
print("  │                                                  │")
print("  │  Commands:                                       │")
print("  │    /pulse           → session stats              │")
print("  │    /pulse dashboard → visual health board        │")
print("  │    /pulse break     → log a break                │")
print("  │    /pulse report    → weekly report              │")
print("  │                                                  │")
print("  │  All data stays local. Nothing leaves your       │")
print("  │  machine. Ever.                                  │")
print("  └──────────────────────────────────────────────────┘")
print("")
print("  Powered by Wave — wave.so/health")
print("")

PYEOF

# Mark as onboarded
touch "$STATE_DIR/.onboarded"

echo "  Ready. Start coding with Claude Code and the nudges will appear."
echo ""
