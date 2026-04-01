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

# ── Compute extra stats ──────────────────────────────────────────

# Total coding hours (rough: sum of session durations capped at 4h each)
total_hours = round(sum(min(s["dur"], 240) for s in sessions) / 60)

# Total prompts
total_prompts = sum(s["msgs"] for s in sessions)

# Avg session
avg_dur = round(sum(s["dur"] for s in sessions) / total)

# Day of week breakdown
dow_sessions = collections.Counter(s["dow"] for s in sessions)
dow_dur = collections.defaultdict(int)
for s in sessions:
    dow_dur[s["dow"]] += s["dur"]

# Hour heatmap
hour_counts = collections.Counter(s["hour"] for s in sessions)

# Weekend stats
wknd_pct = round(wknd / total * 100)

# Long session stats
long_pct = round(long / total * 100)
very_long = sum(1 for s in sessions if s["dur"] > 180)

# ── Print the profile ────────────────────────────────────────────

print("")
print("  ╔════════════════════════════════════════════════════════════╗")
print("  ║                                                          ║")
print("  ║            YOUR CODING HEALTH PROFILE                    ║")
print("  ║            Analyzed from your Claude Code history         ║")
print("  ║                                                          ║")
print("  ╚════════════════════════════════════════════════════════════╝")
print("")
print(f"  I just scanned {total} coding sessions over the last {span} days.")
print(f"  That's ~{total_prompts:,} prompts and ~{total_hours} hours of coding.")
print(f"  Here's what your coding habits look like from a health perspective:")
print("")

# ── Section 1: The Big Numbers ───────────────────────────────────
print("  ── THE BIG NUMBERS ──────────────────────────────────────────")
print("")
print(f"    Sessions:          {total}")
print(f"    Active days:       {active_days}/{span} ({round(active_days/span*100)}%)")
print(f"    Total coding time: ~{total_hours} hours")
print(f"    Avg session:       {avg_dur} min")
print(f"    Longest streak:    {max_streak} days without a rest day")
print("")

# ── Section 2: When You Code ─────────────────────────────────────
print("  ── WHEN YOU CODE ────────────────────────────────────────────")
print("")

# Hour heatmap (visual)
print("    Hour of day:")
max_h = max(hour_counts.values()) if hour_counts else 1
for h in range(24):
    c = hour_counts.get(h, 0)
    if c > 0:
        bar_len = int(c / max_h * 20)
        bar = "█" * bar_len + "░" * (20 - bar_len)
        label = ""
        if h >= 23 or h < 5: label = "  ← late night"
        elif 13 <= h <= 17: label = "  ← peak"
        print(f"    {h:02d}:00  {bar}  {c:>3} sessions{label}")

print("")
peak_str = ", ".join(f"{h}:00" for h, _ in peak)
print(f"    Your peak:     {peak_str}")
if late_pct > 0:
    print(f"    Late night:    {late} sessions ({late_pct}%) start after 11pm")
if wknd_pct > 0:
    print(f"    Weekends:      {wknd} sessions ({wknd_pct}%)")
print("")

# Day of week
print("    Day of week:")
max_d = max(dow_sessions.values()) if dow_sessions else 1
for day in ["Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday"]:
    c = dow_sessions.get(day, 0)
    d = dow_dur.get(day, 0)
    bar_len = int(c / max_d * 15)
    bar = "█" * bar_len + "░" * (15 - bar_len)
    tag = " (weekend)" if day in ("Saturday","Sunday") else ""
    print(f"    {day:<10} {bar}  {c:>3} sessions  ~{d//60}h{tag}")
print("")

# ── Section 3: Session Patterns ──────────────────────────────────
print("  ── SESSION PATTERNS ─────────────────────────────────────────")
print("")
print("    Length distribution:")
buckets = [(0,15,"< 15 min  "),(15,30,"15-30 min "),(30,60,"30-60 min "),
           (60,120,"1-2 hours "),(120,180,"2-3 hours "),(180,9999,"3+ hours  ")]
for lo, hi, label in buckets:
    c = sum(1 for s in sessions if lo <= s["dur"] < hi)
    pct = round(c / total * 100)
    bar = "█" * (pct // 2) + "░" * (25 - pct // 2)
    flag = ""
    if lo >= 120 and c > 0: flag = "  ← no break?"
    print(f"    {label}  {bar}  {c:>3} ({pct}%){flag}")
print("")

if long > 0:
    print(f"    ⚠  {long} sessions ({long_pct}%) went over 2 hours without a break.")
    print(f"       That's {long * 2} hours of unbroken sitting. Your back, eyes,")
    print(f"       and wrists were under sustained load with zero recovery.")
    print("")
if very_long > 0:
    print(f"    ⚠  {very_long} sessions went over 3 HOURS straight.")
    print(f"       After 90 minutes of sitting, blood flow to your legs drops ~50%.")
    print(f"       After 3 hours, your risk of blood clots measurably increases.")
    print("")

# ── Section 4: Your Mood at the Keyboard ─────────────────────────
print("  ── YOUR MOOD AT THE KEYBOARD ────────────────────────────────")
print("")
build_pct = round(moods.get("building", 0) / total * 100)
frust_pct = round(moods.get("frustrated", 0) / total * 100)
ship_pct = round(moods.get("shipping", 0) / total * 100)
mix_pct = round(moods.get("mixed", 0) / total * 100)

print(f"    🔨 Building new things:  {build_pct}%  {'█' * (build_pct // 2)}")
print(f"    🔄 Mixed/exploring:      {mix_pct}%  {'█' * (mix_pct // 2)}")
print(f"    🚀 Shipping/deploying:   {ship_pct}%  {'█' * (ship_pct // 2)}")
print(f"    😤 Frustrated/debugging: {frust_pct}%  {'█' * max(frust_pct // 2, 1 if frust_pct > 0 else 0)}")
print("")

if frust_ratio > 2 and len(frust_s) > 2:
    print(f"    When you're building, avg session: {build_dur} min")
    print(f"    When you're frustrated, avg session: {frust_dur} min")
    print(f"    That's {frust_ratio}x longer. When you hit a wall, you don't stop.")
    print(f"    You grind. For hours. This is where burnout lives.")
    print("")

# ── Section 5: Health Risks Detected ─────────────────────────────
print("  ── HEALTH RISKS I SPOTTED ────────────────────────────────────")
print("")

risks = []
if max_streak >= 7:
    risks.append(f"    🔴 {max_streak}-day coding streak with no rest day.")
    risks.append(f"       Your muscles, tendons, and brain need recovery days.")
    risks.append(f"       Without rest, micro-damage accumulates into RSI and burnout.")
if long_pct > 15:
    risks.append(f"    🔴 {long_pct}% of sessions exceed 2 hours without a break.")
    risks.append(f"       Prolonged sitting compresses your hip flexors, weakens glutes,")
    risks.append(f"       dries your eyes, and tenses your forearms. Every hour.")
if late_pct > 15:
    risks.append(f"    🟡 {late_pct}% of sessions start after 11pm.")
    risks.append(f"       Late coding = blue light exposure = suppressed melatonin")
    risks.append(f"       = worse sleep = worse code tomorrow. A cycle.")
if active_days / span > 0.9:
    risks.append(f"    🟡 You code {round(active_days/span*100)}% of days. Almost no rest.")
    risks.append(f"       High performers rest strategically. Rest days aren't laziness,")
    risks.append(f"       they're when your brain consolidates learning.")
if frust_ratio > 3 and len(frust_s) > 2:
    risks.append(f"    🟡 Frustrated sessions last {frust_ratio}x longer than productive ones.")
    risks.append(f"       When stuck for 30+ min, a 5-min walk solves problems faster")
    risks.append(f"       than staring at the screen for 3 more hours.")
if not risks:
    risks.append("    🟢 No major risks detected. Let's keep it that way.")

for r in risks:
    print(r)
print("")

# ── Section 6: What This Plugin Does About It ────────────────────
print("  ╔════════════════════════════════════════════════════════════╗")
print("  ║  HOW WAVE DEV HEALTH WILL HELP                           ║")
print("  ╠════════════════════════════════════════════════════════════╣")
print("  ║                                                          ║")
print("  ║  This plugin runs silently in the background. It reads   ║")
print("  ║  your prompts, detects your mood, and nudges you with    ║")
print("  ║  health tips at exactly the right moment.                ║")
print("  ║                                                          ║")
print("  ║  Not a dumb timer. It actually understands context:      ║")
print("  ║                                                          ║")
print("  ║  ┌─────────────────────────────────────────────────┐     ║")
print("  ║  │ EVERY 20 MIN  Quick eye break (20-20-20 rule)   │     ║")
print("  ║  │ EVERY 35 MIN  Hydration + posture check         │     ║")
print("  ║  │ EVERY 50 MIN  Full stretch with specific tips    │     ║")
print("  ║  │ AT 90 MIN     Stand up and walk. Non-negotiable. │     ║")
print("  ║  └─────────────────────────────────────────────────┘     ║")
print("  ║                                                          ║")
print("  ║  SMART DETECTION:                                        ║")
print("  ║  😤 Frustrated? Breathing exercises, not wrist stretches ║")
print("  ║  🚀 Shipping? Brief nudges that don't break momentum     ║")
print("  ║  🌙 2am session? \"Go to bed\" nudge, no judgment          ║")
print("  ║  🔀 Switched projects? \"Take a breath before diving in\"  ║")
print("  ║  📈 7+ days straight? Burnout early warning              ║")
print("  ║                                                          ║")
print("  ║  YOUR TOOLS:                                             ║")
print("  ║  /pulse           Quick session stats + health score     ║")
print("  ║  /pulse dashboard ASCII health board (screenshot-ready)  ║")
print("  ║  /pulse break     Log a break + get a tip                ║")
print("  ║  /pulse report    Weekly health report with insights     ║")
print("  ║  /pulse energy N  Track your energy (1-5, optional)      ║")
print("  ║  /pulse config    Adjust nudge timing + preferences      ║")
print("  ║                                                          ║")
print("  ║  📍 All data stays on your machine. Nothing sent anywhere.║")
print("  ║  🧠 Uses Claude's own AI for personalized insights.      ║")
print("  ║  ⚡ No API keys. No accounts. No setup. Just code.       ║")
print("  ║                                                          ║")
print("  ╚════════════════════════════════════════════════════════════╝")
print("")
print("  Powered by Wave — AI health companion")
print("  wave.so/health")
print("")

PYEOF

# Mark as onboarded
touch "$STATE_DIR/.onboarded"

echo "  Ready. Start coding with Claude Code and the nudges will appear."
echo ""
