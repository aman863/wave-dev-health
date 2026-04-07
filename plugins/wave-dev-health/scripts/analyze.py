import json, os, glob, datetime, collections

state_dir = os.path.expanduser("~/.wave-dev-health")
profile_path = os.path.join(state_dir, "profile.md")
os.makedirs(state_dir, exist_ok=True)

base = os.path.expanduser("~/.claude/projects")
ist = datetime.timedelta(hours=5, minutes=30)
sessions = []

if not os.path.isdir(base):
    print("  No Claude Code sessions found yet.")
    print("  Start coding and Rox will track your patterns.")
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
    print("  Start coding and Rox will track your patterns.")
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
total_hours = round(sum(min(s["dur"], 240) for s in sessions) / 60)
total_prompts = sum(s["msgs"] for s in sessions)
avg_dur = round(sum(s["dur"] for s in sessions) / total)
dow_sessions = collections.Counter(s["dow"] for s in sessions)
dow_dur = collections.defaultdict(int)
for s in sessions:
    dow_dur[s["dow"]] += s["dur"]
hour_counts = collections.Counter(s["hour"] for s in sessions)
wknd_pct = round(wknd / total * 100)
long_pct = round(long / total * 100)
very_long = sum(1 for s in sessions if s["dur"] > 180)
build_pct = round(moods.get("building", 0) / total * 100)
frust_pct = round(moods.get("frustrated", 0) / total * 100)
ship_pct = round(moods.get("shipping", 0) / total * 100)
mix_pct = round(moods.get("mixed", 0) / total * 100)

# ── Build risks list ─────────────────────────────────────────────
risks = []
if max_streak >= 7:
    risks.append(f"**{max_streak}-day coding streak** with no rest day. Your muscles, tendons, and brain need recovery days. Without rest, micro-damage accumulates into RSI and burnout.")
if long_pct > 15:
    risks.append(f"**{long_pct}% of sessions exceed 2 hours** without a break. That's {long * 2} hours of unbroken sitting. Prolonged sitting compresses hip flexors, weakens glutes, dries eyes, and tenses forearms.")
if very_long > 0:
    risks.append(f"**{very_long} sessions went over 3 hours straight.** After 90 min of sitting, blood flow to your legs drops ~50%. After 3 hours, blood clot risk measurably increases.")
if late_pct > 15:
    risks.append(f"**{late_pct}% of sessions start after 11pm.** Late coding = blue light = suppressed melatonin = worse sleep = worse code tomorrow. A cycle.")
if active_days / span > 0.9:
    risks.append(f"**You code {round(active_days/span*100)}% of days.** Almost no rest. High performers rest strategically. Rest days are when your brain consolidates learning.")
if frust_ratio > 3 and len(frust_s) > 2:
    risks.append(f"**Frustrated sessions last {frust_ratio}x longer** than productive ones. When stuck 30+ min, a 5-min walk solves problems faster than staring for 3 more hours.")

# ── Build hour heatmap for markdown ──────────────────────────────
max_h = max(hour_counts.values()) if hour_counts else 1
heatmap_lines = []
for h in range(24):
    c = hour_counts.get(h, 0)
    if c > 0:
        bar_len = int(c / max_h * 20)
        bar = "█" * bar_len + "░" * (20 - bar_len)
        label = ""
        if h >= 23 or h < 5: label = " ← late night"
        elif 13 <= h <= 17: label = " ← peak"
        heatmap_lines.append(f"{h:02d}:00  {bar}  {c:>3} sessions{label}")

# ── Build day of week table ──────────────────────────────────────
max_d = max(dow_sessions.values()) if dow_sessions else 1
dow_lines = []
for day in ["Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday"]:
    c = dow_sessions.get(day, 0)
    d = dow_dur.get(day, 0)
    bar_len = int(c / max_d * 15)
    bar = "█" * bar_len + "░" * (15 - bar_len)
    tag = " (weekend)" if day in ("Saturday","Sunday") else ""
    dow_lines.append(f"{day:<10} {bar}  {c:>3} sessions  ~{d//60}h{tag}")

peak_str = ", ".join(f"{h}:00" for h, _ in peak)

# ── Write full profile to markdown file ──────────────────────────
md = f"""# Your Coding Health Profile

*Analyzed from your Claude Code session history by Rox*

---

## The Big Picture

I just scanned **{total} coding sessions** over the last **{span} days**.
That's **~{total_prompts:,} prompts** and **~{total_hours} hours** of coding.

| Metric | Value |
|--------|-------|
| Sessions | {total} |
| Active coding days | {active_days}/{span} ({round(active_days/span*100)}%) |
| Total coding time | ~{total_hours} hours |
| Avg session length | {avg_dur} min |
| Longest streak without rest | **{max_streak} days** |

---

## When You Code

**Peak hours:** {peak_str}
**Late night sessions:** {late} ({late_pct}%) start after 11pm
**Weekend sessions:** {wknd} ({wknd_pct}%)

### Hour-by-Hour Heatmap
```
{chr(10).join(heatmap_lines)}
```

### Day of Week
```
{chr(10).join(dow_lines)}
```

---

## Session Patterns

| Duration | Count | % |
|----------|-------|---|
| Under 15 min | {sum(1 for s in sessions if s['dur'] < 15)} | {round(sum(1 for s in sessions if s['dur'] < 15)/total*100)}% |
| 15-30 min | {sum(1 for s in sessions if 15 <= s['dur'] < 30)} | {round(sum(1 for s in sessions if 15 <= s['dur'] < 30)/total*100)}% |
| 30-60 min | {sum(1 for s in sessions if 30 <= s['dur'] < 60)} | {round(sum(1 for s in sessions if 30 <= s['dur'] < 60)/total*100)}% |
| 1-2 hours | {sum(1 for s in sessions if 60 <= s['dur'] < 120)} | {round(sum(1 for s in sessions if 60 <= s['dur'] < 120)/total*100)}% |
| **2-3 hours (no break?)** | {sum(1 for s in sessions if 120 <= s['dur'] < 180)} | {round(sum(1 for s in sessions if 120 <= s['dur'] < 180)/total*100)}% |
| **3+ hours (no break?)** | {sum(1 for s in sessions if s['dur'] >= 180)} | {round(sum(1 for s in sessions if s['dur'] >= 180)/total*100)}% |

---

## Your Mood at the Keyboard

| Mood | % |
|------|---|
| 🔨 Building | {build_pct}% |
| 🔄 Mixed/exploring | {mix_pct}% |
| 🚀 Shipping | {ship_pct}% |
| 😤 Frustrated | {frust_pct}% |

{"**When building**, avg session: " + str(build_dur) + " min. **When frustrated**, avg session: " + str(frust_dur) + " min. That's **" + str(frust_ratio) + "x longer**. When you hit a wall, you don't stop. You grind for hours." if frust_ratio > 2 and len(frust_s) > 2 else ""}

---

## Health Risks Detected

{chr(10).join('- 🔴 ' + r if i < 2 else '- 🟡 ' + r for i, r in enumerate(risks)) if risks else "- 🟢 No major risks detected. Let's keep it that way."}

---

## How Rox Helps

This plugin runs silently in the background. It reads your prompts, detects your mood, and nudges you with health tips at exactly the right moment.

**Not a dumb timer. It understands context:**

| Trigger | What happens |
|---------|-------------|
| Every 20 min | Quick eye break (20-20-20 rule). One line, barely visible. |
| Every 35 min | Hydration + posture check. Short callout. |
| Every 50 min | Full stretch with specific tips and actions. |
| 90 min no break | Stand up and walk. Urgent. Non-negotiable. |
| Frustrated (3+ prompts) | Breathing exercises + "step away, the answer will come" |
| Shipping mode | Brief nudges that don't break your momentum |
| After 11pm | Gentle sleep reminder, no judgment |
| 2-4am | More direct: "everything you write now, you'll re-read tomorrow" |
| Switched projects | "Context switch. Take a breath before diving in." |
| 7+ days straight | Burnout early warning, once per day |

**Your tools:**
- `/pulse` — Quick session stats + health score
- `/pulse dashboard` — ASCII health board (screenshot-ready)
- `/pulse break` — Log a break + get a personalized tip
- `/pulse report` — Weekly health report with insights
- `/pulse energy [1-5]` — Track your energy level (optional)
- `/pulse config` — Adjust nudge timing + preferences

**Privacy:** All data stays at `~/.wave-dev-health/`. Nothing leaves your machine. Ever.
**AI:** Uses Claude's own model for personalized insights. No API keys needed.

---

*Powered by [Rox](https://wave.so/health) — AI health companion*
"""

with open(profile_path, 'w') as f:
    f.write(md)

# ── Print SHORT summary to terminal ─────────────────────────────
print(f"INSTALLED_OK")
print(f"PROFILE_PATH:{profile_path}")
print(f"SESSIONS:{total}")
print(f"DAYS:{span}")

