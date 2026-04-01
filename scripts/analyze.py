#!/usr/bin/env python3
"""
Wave Dev Health — Coding Health Impact Analysis
Scans Claude Code sessions. Interprets every pattern through a health lens.
Not "you coded 352 sessions." Instead: "you sat without moving for 248 hours."
"""
import json, os, glob, datetime, collections, sys, math

state_dir = os.path.expanduser("~/.wave-dev-health")
html_path = os.path.join(state_dir, "profile.html")
os.makedirs(state_dir, exist_ok=True)

base = os.path.expanduser("~/.claude/projects")
ist = datetime.timedelta(hours=5, minutes=30)
sessions = []

if not os.path.isdir(base):
    print("No Claude Code sessions found.")
    sys.exit()

BREAK_THRESHOLD = 10 * 60   # 10+ min gap between messages = a break
ACTIVE_THRESHOLD = 5 * 60   # gaps under 5 min = continuous coding

for f in glob.glob(f"{base}/*/*.jsonl"):
    try:
        stat = os.stat(f)
        if stat.st_size < 2000: continue
        first_ts = None; last_ts = None; user_msgs = 0; user_texts = []
        user_timestamps = []  # track every user message timestamp

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
                        if ts: user_timestamps.append(ts)
                        content = obj.get("message", {}).get("content", "")
                        if isinstance(content, str): user_texts.append(content.lower()[:200])
                        elif isinstance(content, list):
                            for b in content:
                                if isinstance(b, dict) and b.get("type") == "text":
                                    user_texts.append(b.get("text", "").lower()[:200])
                except: pass

        if not first_ts or user_msgs < 3: continue
        start = datetime.datetime.fromisoformat(first_ts.replace("Z", "+00:00"))
        end = datetime.datetime.fromisoformat(last_ts.replace("Z", "+00:00"))
        wall_dur = (end - start).total_seconds() / 60
        if wall_dur < 3: continue

        # ── Analyze gaps between messages to detect breaks ────────
        # A "break" = gap of 10+ min between consecutive user messages
        # "Active time" = sum of gaps under 5 min (continuous coding)
        # "Longest stretch" = longest run of continuous coding without a break
        breaks_taken = 0
        active_seconds = 0
        longest_stretch_sec = 0
        current_stretch_sec = 0
        break_minutes = []  # duration of each break

        parsed_ts = []
        for t in user_timestamps:
            try:
                parsed_ts.append(datetime.datetime.fromisoformat(t.replace("Z", "+00:00")))
            except: pass

        if len(parsed_ts) >= 2:
            for i in range(1, len(parsed_ts)):
                gap = (parsed_ts[i] - parsed_ts[i-1]).total_seconds()
                if gap >= BREAK_THRESHOLD:
                    # This gap is a break
                    breaks_taken += 1
                    break_minutes.append(round(gap / 60))
                    # Save current stretch, start new one
                    longest_stretch_sec = max(longest_stretch_sec, current_stretch_sec)
                    current_stretch_sec = 0
                elif gap < ACTIVE_THRESHOLD:
                    # Continuous coding
                    active_seconds += gap
                    current_stretch_sec += gap
                else:
                    # 5-10 min gap: probably thinking/reading, count as active but not intense
                    active_seconds += gap
                    current_stretch_sec += gap
            longest_stretch_sec = max(longest_stretch_sec, current_stretch_sec)
        else:
            active_seconds = wall_dur * 60

        active_min = round(active_seconds / 60)
        longest_stretch_min = round(longest_stretch_sec / 60)

        start_ist = start + ist
        all_text = " ".join(user_texts)
        fr = sum(1 for kw in ["error","bug","broken","not working","why is","fails","crash","stuck","confused"] if kw in all_text)
        bu = sum(1 for kw in ["add","create","implement","build","write","new"] if kw in all_text)
        sh = sum(1 for kw in ["ship","deploy","push","commit","merge"] if kw in all_text)
        if fr > bu and fr > 3: mood = "frustrated"
        elif sh > 2: mood = "shipping"
        elif bu > fr: mood = "building"
        else: mood = "mixed"

        sessions.append({
            "date": start_ist.strftime("%Y-%m-%d"),
            "hour": start_ist.hour,
            "dow": start_ist.strftime("%A"),
            "dur": round(wall_dur),        # wall clock duration
            "active": active_min,           # actual coding time
            "longest": longest_stretch_min, # longest stretch without a break
            "breaks": breaks_taken,         # breaks detected (10+ min gaps)
            "msgs": user_msgs,
            "mood": mood,
        })
    except: pass

if not sessions:
    print("No coding sessions found.")
    sys.exit()

# ── Metrics ──────────────────────────────────────────────────────
sessions.sort(key=lambda x: x["date"])
T = len(sessions)
dates = set(s["date"] for s in sessions)
d1 = datetime.datetime.strptime(min(dates), "%Y-%m-%d")
d2 = datetime.datetime.strptime(max(dates), "%Y-%m-%d")
span = max(1, (d2 - d1).days + 1)
active_days = len(dates)
by_hour = collections.Counter(s["hour"] for s in sessions)
late = sum(1 for s in sessions if s["hour"] >= 23 or s["hour"] < 5)
late_pct = round(late / T * 100)
moods = collections.Counter(s["mood"] for s in sessions)
frust_s = [s for s in sessions if s["mood"] == "frustrated"]
build_s = [s for s in sessions if s["mood"] == "building"]
frust_dur = round(sum(s["dur"] for s in frust_s) / max(len(frust_s), 1))
build_dur = round(sum(s["dur"] for s in build_s) / max(len(build_s), 1))
frust_ratio = round(frust_dur / max(build_dur, 1), 1) if frust_s else 0
total_hours = round(sum(min(s["dur"], 240) for s in sessions) / 60)
total_prompts = sum(s["msgs"] for s in sessions)

# Break analysis (now based on actual gaps, not wall clock)
total_breaks = sum(s["breaks"] for s in sessions)
sessions_with_breaks = sum(1 for s in sessions if s["breaks"] > 0)
sessions_without_breaks = T - sessions_with_breaks

# Sessions where the longest unbroken stretch was 90+ min
long_stretch = sum(1 for s in sessions if s["longest"] > 90)
long_stretch_pct = round(long_stretch / T * 100)
very_long_stretch = sum(1 for s in sessions if s["longest"] > 180)

# Total active coding hours (excluding breaks)
total_active_hours = round(sum(s["active"] for s in sessions) / 60)
# Total hours of continuous coding without breaks (stretches > 60 min)
unbroken_hours = round(sum(s["longest"] for s in sessions if s["longest"] > 60) / 60)

avg_active = round(sum(s["active"] for s in sessions) / T)
avg_longest = round(sum(s["longest"] for s in sessions) / T)
avg_breaks_per_session = round(total_breaks / T, 1)

# Backward compat aliases
no_break = long_stretch
no_break_pct = long_stretch_pct
lng = long_stretch
lng_pct = long_stretch_pct
very_long = very_long_stretch
sitting_hours = unbroken_hours

# Streak
sorted_dates = sorted(dates)
max_streak = 1; streak = 1
for i in range(1, len(sorted_dates)):
    a = datetime.datetime.strptime(sorted_dates[i-1], "%Y-%m-%d")
    b = datetime.datetime.strptime(sorted_dates[i], "%Y-%m-%d")
    if (b - a).days == 1: streak += 1; max_streak = max(max_streak, streak)
    else: streak = 1

rest_days = span - active_days
rest_pct = round(rest_days / span * 100)

# Peak load hours (when body is under most strain)
hour_dur = collections.defaultdict(int)
for s in sessions: hour_dur[s["hour"]] += s["dur"]
peak_load = sorted(hour_dur.items(), key=lambda x: -x[1])[:3]

# Mood
build_pct = round(moods.get("building", 0) / T * 100)
frust_pct = round(moods.get("frustrated", 0) / T * 100)
ship_pct = round(moods.get("shipping", 0) / T * 100)
mix_pct = round(moods.get("mixed", 0) / T * 100)

# Eye strain estimate (every session = eyes on screen)
eye_hours = total_hours
blinks_missed = round(eye_hours * 60 * 7)  # ~7 blinks/min missed vs normal 15-20

# Wrist load
total_prompts_k = round(total_prompts / 1000, 1)

# ── Verdict + Findings (replaces abstract score) ────────────────
# Instead of a mystery number, give a clear verdict with specific findings

findings = []  # (emoji, title, detail, severity)

# Finding: Break habits
if long_stretch_pct > 30:
    findings.append(("break", "You rarely take breaks", f"In {long_stretch_pct}% of your sessions, you coded for 90+ minutes straight without stepping away. Your average longest unbroken stretch is {avg_longest} minutes.", "bad"))
elif long_stretch_pct > 10:
    findings.append(("break", "Your break habits are inconsistent", f"In {long_stretch_pct}% of sessions you go 90+ minutes without a break. Average longest stretch: {avg_longest} min. Some sessions are great, others not.", "warn"))
else:
    findings.append(("break", "You take breaks regularly", f"Only {long_stretch_pct}% of sessions go past 90 min without a break. Average longest stretch: {avg_longest} min. Solid habit.", "good"))

# Finding: Rest days
if max_streak >= 14:
    findings.append(("rest", f"You coded {max_streak} days in a row", f"Only {rest_days} rest days in {span} days. Your body repairs tendons, muscles, and eyes during rest. {max_streak} days straight is a burnout signal.", "bad"))
elif max_streak >= 7:
    findings.append(("rest", f"{max_streak}-day coding streak", f"You had {rest_days} rest days in {span} days. A streak of {max_streak} days is manageable but pushing it. Aim for at least 2 rest days per week.", "warn"))
else:
    findings.append(("rest", "Good rest day balance", f"{rest_days} rest days in {span} days. Your longest streak was {max_streak} days. Your body gets time to recover.", "good"))

# Finding: Late nights
if late_pct > 25:
    findings.append(("sleep", f"{late_pct}% of sessions are after 11pm", f"That is {late} out of {T} sessions. Screens at night suppress melatonin (your sleep hormone) by up to 50%. Worse sleep means worse code the next day.", "bad"))
elif late_pct > 10:
    findings.append(("sleep", f"Some late night coding ({late_pct}%)", f"{late} sessions started after 11pm. Occasional late nights are fine. Watch for patterns of consecutive late nights since sleep debt compounds.", "warn"))
else:
    findings.append(("sleep", "Healthy coding hours", f"Only {late_pct}% of sessions start after 11pm. Your screen time is not significantly impacting your sleep.", "good"))

# Finding: Frustration patterns
if frust_ratio > 2 and len(frust_s) > 2:
    findings.append(("stress", "Frustrated sessions drag on", f"When you are stuck, your sessions last {frust_ratio}x longer ({frust_dur} min vs {build_dur} min when building). You grind instead of stepping away. A 5-min walk solves bugs faster than 3 more hours of staring.", "warn"))

# Finding: Eye strain
if total_active_hours > 100:
    findings.append(("eyes", f"{total_active_hours} hours of screen time", f"Your eyes were actively focused on code for {total_active_hours} hours. At reduced blink rates during coding, that is roughly {blinks_missed:,} missed blinks your eyes needed.", "warn"))

# Count severities
bad_count = sum(1 for f in findings if f[3] == "bad")
warn_count = sum(1 for f in findings if f[3] == "warn")
good_count = sum(1 for f in findings if f[3] == "good")

# Verdict
if bad_count >= 2:
    verdict = "needs_attention"
    verdict_text = "Your coding habits need attention"
    verdict_sub = "We found " + str(bad_count) + " area" + ("s" if bad_count > 1 else "") + " that could be affecting your health. The good news: small changes make a big difference."
    verdict_color = "#ef4444"
elif bad_count >= 1 or warn_count >= 2:
    verdict = "room_to_improve"
    verdict_text = "Room to improve"
    verdict_sub = "Some of your habits are solid, but there are " + str(bad_count + warn_count) + " areas worth working on."
    verdict_color = "#f59e0b"
else:
    verdict = "looking_good"
    verdict_text = "Your habits look healthy"
    verdict_sub = "No major concerns. Keep doing what you are doing. The plugin will help you stay on track."
    verdict_color = "#10b981"

# One actionable recommendation
if bad_count > 0:
    worst = [f for f in findings if f[3] == "bad"][0]
    action_text = {
        "break": "Start with one rule: stand up every 60 minutes. Set a timer if you need to. Wave Dev Health will do this for you automatically.",
        "rest": "Take tomorrow off from coding. Not to be lazy. Because your wrists, eyes, and brain need a day to repair. Then aim for 2 rest days per week.",
        "sleep": "Stop coding by 10:30pm for one week. See how your next morning feels. The code will still be there tomorrow. You will write it better after sleep.",
    }.get(worst[0], "Install Wave Dev Health and let it nudge you at the right moments.")
elif warn_count > 0:
    first_warn = [f for f in findings if f[3] == "warn"][0]
    action_text = {
        "break": "You are close to good habits. The sessions where you go 90+ minutes are the ones to fix. Wave Dev Health catches these automatically.",
        "rest": "Try to keep your coding streak under 5 days. Your body repairs during rest, not during work.",
        "sleep": "Watch for consecutive late nights. One late session is fine. Three in a row degrades your output.",
        "stress": "Next time you are stuck for 20+ minutes, stand up and walk for 5 minutes. The answer comes faster when you stop forcing it.",
        "eyes": "The 20-20-20 rule works. Every 20 min, look 20 feet away for 20 seconds. Wave Dev Health reminds you.",
    }.get(first_warn[0], "Wave Dev Health will nudge you at the right moments.")
else:
    action_text = "Keep going. Wave Dev Health runs in the background and catches the days when your habits slip."

# Findings HTML
findings_html = ""
for emoji_key, title, detail, severity in findings:
    icon = {"break": "&#9201;", "rest": "&#128164;", "sleep": "&#127769;", "stress": "&#129504;", "eyes": "&#128065;"}.get(emoji_key, "&#8226;")
    sev_class = {"bad": "f-bad", "warn": "f-warn", "good": "f-good"}.get(severity, "")
    sev_label = {"bad": "Needs attention", "warn": "Worth watching", "good": "Looking good"}.get(severity, "")
    sev_color = {"bad": "var(--r)", "warn": "var(--y)", "good": "var(--g)"}.get(severity, "var(--t3)")
    findings_html += f'<div class="finding {sev_class}"><div class="f-header"><span class="f-icon">{icon}</span><div><div class="f-title">{title}</div><div class="f-sev" style="color:{sev_color}">{sev_label}</div></div></div><div class="f-detail">{detail}</div></div>'

# ── Time blocks (instead of raw hours) ───────────────────────────
time_blocks = [
    ("Morning", "6am-12pm", range(6, 12), "#6366f1"),
    ("Afternoon", "12-5pm", range(12, 17), "#818cf8"),
    ("Evening", "5-10pm", range(17, 22), "#a78bfa"),
    ("Late Night", "10pm-6am", list(range(22, 24)) + list(range(0, 6)), "#ef4444"),
]
block_data = []
for name, label, hours, color in time_blocks:
    count = sum(by_hour.get(h, 0) for h in hours)
    pct = round(count / T * 100) if T > 0 else 0
    block_data.append({"name": name, "label": label, "count": count, "pct": pct, "color": color})
max_block = max(b["count"] for b in block_data) if block_data else 1
for b in block_data:
    b["bar"] = round(b["count"] / max_block * 100)
block_json = json.dumps(block_data)

# ── Break visual: sessions with vs without breaks ────────────────
with_breaks = sessions_with_breaks
without_breaks = sessions_without_breaks
wb_pct = round(with_breaks / T * 100) if T > 0 else 0
wob_pct = 100 - wb_pct

# Longest stretch distribution (how long people go without breaking)
stretch_buckets = [
    ("Under 30 min", 0, 30, "good"),
    ("30-60 min", 30, 60, "good"),
    ("1-1.5 hours", 60, 90, "ok"),
    ("1.5-2 hours", 90, 120, "warn"),
    ("2-3 hours", 120, 180, "bad"),
    ("3+ hours", 180, 99999, "bad"),
]
stretch_data = []
for label, lo, hi, sev in stretch_buckets:
    c = sum(1 for s in sessions if lo <= s["longest"] < hi)
    stretch_data.append({"l": label, "c": c, "p": round(c/T*100) if T > 0 else 0, "s": sev})
max_stretch = max(d["c"] for d in stretch_data) if stretch_data else 1
for d in stretch_data:
    d["bar"] = round(d["c"] / max_stretch * 100) if max_stretch > 0 else 0
stretch_json = json.dumps(stretch_data)

# Heatmap
date_counts = collections.Counter(s["date"] for s in sessions)
hm = []
start_d = d2 - datetime.timedelta(days=d2.weekday() + 7*6)
cur = start_d
while cur <= d2:
    ds = cur.strftime("%Y-%m-%d")
    hm.append({"d": ds, "c": date_counts.get(ds, 0), "w": cur.weekday()})
    cur += datetime.timedelta(days=1)
hm_json = json.dumps(hm)

# Score ring
# Score ring removed — replaced with verdict + findings approach

# Donut
mood_items = [("Building", build_pct, "#10b981"), ("Mixed", mix_pct, "#8b5cf6"), ("Shipping", ship_pct, "#f59e0b"), ("Frustrated", frust_pct, "#ef4444")]
R = 54; CX = 64; CY = 64; C = 2 * math.pi * R
segs = []; off = 0
for name, pct, col in mood_items:
    if pct == 0: continue
    d = C * pct / 100
    segs.append(f'<circle cx="{CX}" cy="{CY}" r="{R}" fill="none" stroke="{col}" stroke-width="14" stroke-dasharray="{d:.1f} {C-d:.1f}" stroke-dashoffset="{-off:.1f}" class="dseg" style="animation-delay:{len(segs)*0.2}s"/>')
    off += d
donut_svg = "\n".join(segs)
mood_legend = "".join(
    '<div class="ml"><div class="md" style="background:'+c+'"></div><span class="mn">'+n+'</span><span class="mp">'+str(p)+'%</span></div>'
    for n, p, c in mood_items if p > 0
)

# Component bars for score breakdown
# comp_html removed — replaced with findings approach

# ── HTML ─────────────────────────────────────────────────────────
html = f'''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Coding Health Impact Analysis | Wave Dev Health</title>
<link rel="preconnect" href="https://api.fontshare.com">
<link href="https://api.fontshare.com/v2/css?f[]=satoshi@400,500,700,900&display=swap" rel="stylesheet">
<style>
:root{{--bg:#050508;--s1:#0c0c14;--s2:#12121c;--s3:#1a1a28;--b1:#1c1c2e;--b2:#2a2a42;
--t1:#e8e8f0;--t2:#9898b0;--t3:#5c5c78;--a:#7c6aef;--a2:#9d8ff5;--ag:rgba(124,106,239,.12);
--g:#10b981;--r:#ef4444;--y:#f59e0b;--p:#8b5cf6;}}
*{{margin:0;padding:0;box-sizing:border-box}}
body{{background:var(--bg);color:var(--t1);font-family:Satoshi,system-ui,sans-serif;line-height:1.7;overflow-x:hidden}}
body::before{{content:'';position:fixed;top:-300px;left:50%;transform:translateX(-50%);width:800px;height:800px;background:radial-gradient(ellipse,rgba(124,106,239,.06) 0%,transparent 70%);pointer-events:none;z-index:0}}
.c{{max-width:780px;margin:0 auto;padding:48px 20px;position:relative;z-index:1}}

.hdr{{text-align:center;margin-bottom:20px;animation:fu .7s ease}}
.badge{{display:inline-block;padding:5px 14px;border-radius:99px;background:var(--ag);border:1px solid rgba(124,106,239,.18);color:var(--a2);font-size:11px;font-weight:600;letter-spacing:1.5px;margin-bottom:14px;text-transform:uppercase}}
.hdr h1{{font-size:32px;font-weight:900;letter-spacing:-.5px;background:linear-gradient(135deg,#fff 30%,var(--a2));-webkit-background-clip:text;-webkit-text-fill-color:transparent}}
.hdr .sub{{color:var(--t3);font-size:13px;margin-top:4px}}

/* Verdict */
.verdict{{text-align:center;margin:32px 0 36px;animation:fu .7s ease .1s both}}
.verdict-label{{font-size:28px;font-weight:900;color:#fff;margin-bottom:6px}}
.verdict-sub{{font-size:14px;color:var(--t2);max-width:500px;margin:0 auto;line-height:1.6}}
.verdict-dot{{display:inline-block;width:10px;height:10px;border-radius:50%;margin-right:8px}}

/* Findings */
.findings{{margin-bottom:32px}}
.finding{{background:var(--s1);border:1px solid var(--b1);border-radius:14px;padding:20px 22px;margin-bottom:10px;transition:border-color .2s}}
.finding:hover{{border-color:var(--b2)}}
.finding.f-bad{{border-left:3px solid var(--r)}}
.finding.f-warn{{border-left:3px solid var(--y)}}
.finding.f-good{{border-left:3px solid var(--g)}}
.f-header{{display:flex;align-items:center;gap:12px;margin-bottom:8px}}
.f-icon{{font-size:20px;flex-shrink:0}}
.f-title{{font-size:15px;font-weight:700;color:#fff}}
.f-sev{{font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:.5px}}
.f-detail{{font-size:13px;color:var(--t2);line-height:1.6;padding-left:32px}}

/* Action box */
.action{{background:linear-gradient(135deg,rgba(124,106,239,.06),rgba(139,92,246,.03));border:1px solid rgba(124,106,239,.15);border-radius:14px;padding:22px 26px;margin-bottom:32px;animation:fu .7s ease .3s both}}
.action-label{{font-size:11px;font-weight:600;color:var(--a2);text-transform:uppercase;letter-spacing:1.5px;margin-bottom:6px}}
.action-text{{font-size:15px;color:var(--t1);line-height:1.7}}

/* Quick context bar */
.ctx{{display:flex;justify-content:center;gap:24px;flex-wrap:wrap;margin-bottom:28px;animation:fu .7s ease .15s both}}
.ctx-item{{font-size:13px;color:var(--t3)}}
.ctx-item strong{{color:var(--t1);font-weight:600}}
.comp-track{{height:6px;background:var(--s2);border-radius:3px;overflow:hidden}}
.comp-fill{{height:100%;border-radius:3px;transition:width 1.2s ease}}

/* Section */
.sec{{background:var(--s1);border:1px solid var(--b1);border-radius:14px;padding:28px;margin-bottom:16px}}
.sec h2{{font-size:13px;font-weight:600;color:var(--t3);text-transform:uppercase;letter-spacing:1.5px;margin-bottom:6px;display:flex;align-items:center;gap:8px}}
.sec h2::before{{content:'';width:3px;height:12px;border-radius:2px}}
.sec h2.eyes::before{{background:#60a5fa}} .sec h2.body::before{{background:var(--r)}}
.sec h2.brain::before{{background:var(--p)}} .sec h2.sleep::before{{background:var(--y)}}
.sec h2.recovery::before{{background:var(--g)}} .sec h2.load::before{{background:var(--a)}}
.sec .desc{{font-size:14px;color:var(--t2);margin-bottom:18px;line-height:1.6}}
.sec .desc strong{{color:var(--t1)}}
.sec .callout{{font-size:13px;color:var(--t2);padding:14px 16px;background:var(--s2);border-radius:8px;margin-top:14px;line-height:1.6;border-left:3px solid var(--a)}}
.sec .callout strong{{color:var(--a2)}}

/* Bars */
.br{{display:flex;align-items:center;gap:8px;margin-bottom:5px}}
.br .bl{{width:40px;font-size:11px;color:var(--t3);text-align:right;font-variant-numeric:tabular-nums;font-weight:500}}
.br .bt{{flex:1;height:24px;background:var(--s2);border-radius:5px;overflow:hidden}}
.br .bf{{height:100%;border-radius:5px;width:0;transition:width 1s cubic-bezier(.4,0,.2,1)}}
.bf.pk{{background:linear-gradient(90deg,#5b57d6,var(--a))}}
.bf.lt{{background:linear-gradient(90deg,#6d28d9,#a78bfa)}}
.bf.nm{{background:linear-gradient(90deg,#252538,#35354d)}}
.bf.dn{{background:linear-gradient(90deg,#b91c1c,var(--r))}}
.bf.sf{{background:linear-gradient(90deg,#047857,var(--g))}}
.bf.wn{{background:linear-gradient(90deg,#b45309,var(--y))}}
.br .bv{{width:24px;font-size:10px;color:var(--t3)}}

/* Heatmap */
.hm{{display:flex;gap:3px;justify-content:center;flex-wrap:wrap}}
.hm-c{{display:flex;flex-direction:column;gap:3px}}
.hm-d{{width:14px;height:14px;border-radius:3px;background:var(--s2)}}
.hm-d.l1{{background:rgba(124,106,239,.15)}} .hm-d.l2{{background:rgba(124,106,239,.3)}}
.hm-d.l3{{background:rgba(124,106,239,.5)}} .hm-d.l4{{background:rgba(124,106,239,.8)}}

/* Donut */
.mood{{display:flex;align-items:center;gap:32px;flex-wrap:wrap;justify-content:center}}
.dw{{position:relative;width:128px;height:128px}} .dw svg{{width:128px;height:128px;transform:rotate(-90deg)}}
.dc{{position:absolute;top:50%;left:50%;transform:translate(-50%,-50%);text-align:center}}
.dc .dn{{font-size:13px;font-weight:700;color:#fff}} .dc .ds{{font-size:9px;color:var(--t3)}}
.dseg{{opacity:0;animation:di .8s ease forwards}}
@keyframes di{{from{{opacity:0;stroke-dasharray:0 999}}to{{opacity:1}}}}
.mleg{{display:flex;flex-direction:column;gap:10px}}
.ml{{display:flex;align-items:center;gap:8px}} .md{{width:8px;height:8px;border-radius:50%}}
.mn{{font-size:13px;color:var(--t2);min-width:70px}} .mp{{font-size:16px;font-weight:700;color:#fff}}

/* Risk */
.rk{{padding:16px;border-radius:10px;margin-bottom:8px;display:flex;gap:12px}}
.rk.cr{{background:rgba(239,68,68,.04);border:1px solid rgba(239,68,68,.1)}}
.rk.wr{{background:rgba(245,158,11,.04);border:1px solid rgba(245,158,11,.08)}}
.rk-i{{width:6px;height:6px;border-radius:50%;margin-top:7px;flex-shrink:0}}
.rk.cr .rk-i{{background:var(--r);box-shadow:0 0 8px rgba(239,68,68,.4)}}
.rk.wr .rk-i{{background:var(--y);box-shadow:0 0 6px rgba(245,158,11,.3)}}
.rk h3{{font-size:13px;font-weight:600;color:var(--t1);margin-bottom:2px}} .rk p{{font-size:12px;color:var(--t2);line-height:1.5}}

/* Learn more accordion */
.learn{{margin-top:14px}}
.learn summary{{font-size:12px;color:var(--a2);cursor:pointer;padding:8px 0;font-weight:500;list-style:none;display:flex;align-items:center;gap:6px}}
.learn summary::before{{content:'+';display:inline-flex;align-items:center;justify-content:center;width:18px;height:18px;border-radius:50%;background:var(--ag);border:1px solid rgba(124,106,239,.15);font-size:11px;color:var(--a2);flex-shrink:0;transition:transform .2s}}
.learn[open] summary::before{{content:'-';transform:rotate(180deg)}}

/* Split bar (breaks vs no breaks) */
.split-bar{{}} .split-labels{{display:flex;justify-content:space-between;font-size:11px;margin-bottom:4px}}
.split-track{{display:flex;height:32px;border-radius:8px;overflow:hidden;gap:2px}}
.split-fill{{transition:width 1s ease}}

/* Time blocks */
.block-row{{display:flex;align-items:center;gap:12px;margin-bottom:10px;padding:12px 16px;background:var(--s2);border-radius:10px}}
.block-name{{width:90px;font-size:14px;font-weight:600;color:var(--t1)}}
.block-time{{width:70px;font-size:11px;color:var(--t3)}}
.block-bar-wrap{{flex:1;height:20px;background:var(--bg);border-radius:4px;overflow:hidden}}
.block-bar{{height:100%;border-radius:4px;width:0;transition:width 1s ease}}
.block-count{{width:60px;text-align:right;font-size:13px;color:var(--t2)}}
.block-pct{{width:40px;text-align:right;font-size:12px;font-weight:600}}

/* Stretch bars */
.str-row{{display:flex;align-items:center;gap:8px;margin-bottom:6px}}
.str-label{{width:100px;font-size:12px;color:var(--t2);text-align:right}}
.str-bar-wrap{{flex:1;height:22px;background:var(--s2);border-radius:5px;overflow:hidden}}
.str-bar{{height:100%;border-radius:5px;width:0;transition:width 1s ease}}
.str-bar.good{{background:linear-gradient(90deg,#047857,var(--g))}}
.str-bar.ok{{background:linear-gradient(90deg,#0e7490,#22d3ee)}}
.str-bar.warn{{background:linear-gradient(90deg,#b45309,var(--y))}}
.str-bar.bad{{background:linear-gradient(90deg,#b91c1c,var(--r))}}
.str-count{{width:30px;font-size:11px;color:var(--t3)}}
.learn .sci{{padding:12px 16px;background:var(--s2);border-radius:8px;font-size:12px;color:var(--t2);line-height:1.7;margin-top:4px}}
.learn .sci strong{{color:var(--t1)}}

/* Features + Commands */
.fg{{display:grid;grid-template-columns:repeat(2,1fr);gap:8px}}
.ft{{padding:14px;background:var(--s2);border-radius:8px}} .ft .tm{{font-size:11px;font-weight:600;color:var(--a);margin-bottom:2px}} .ft .ds2{{font-size:12px;color:var(--t2)}}
.cms{{display:grid;grid-template-columns:repeat(3,1fr);gap:6px}}
.cm{{padding:12px;background:var(--s2);border-radius:8px}} .cm code{{color:var(--a2);font-size:12px;font-weight:600}} .cm .cd2{{color:var(--t3);font-size:10px;display:block;margin-top:2px}}

.ftr{{text-align:center;margin-top:40px;padding-top:24px;border-top:1px solid var(--b1)}}
.ftr a{{color:var(--a);text-decoration:none}} .ftr p{{color:var(--t3);font-size:12px;margin-bottom:4px}}

@keyframes fu{{from{{opacity:0;transform:translateY(16px)}}to{{opacity:1;transform:translateY(0)}}}}
.rv{{opacity:0;transform:translateY(16px);transition:opacity .5s,transform .5s}} .rv.vis{{opacity:1;transform:translateY(0)}}
@media(max-width:640px){{.fg,.cms{{grid-template-columns:1fr}}}}
</style>
</head>
<body>
<div class="c">

<div class="hdr">
  <div class="badge">Wave Dev Health</div>
  <h1>How Your Coding Affects Your Body</h1>
  <p class="sub">Based on {T:,} sessions over {span} days of Claude Code usage</p>
</div>

<div class="ctx">
  <div class="ctx-item"><strong>{T}</strong> sessions</div>
  <div class="ctx-item"><strong>{total_active_hours}</strong> hours coded</div>
  <div class="ctx-item"><strong>{total_breaks}</strong> breaks taken</div>
  <div class="ctx-item"><strong>{span}</strong> days analyzed</div>
</div>

<div class="verdict">
  <div class="verdict-label"><span class="verdict-dot" style="background:{verdict_color}"></span>{verdict_text}</div>
  <div class="verdict-sub">{verdict_sub}</div>
</div>

<div class="findings rv">
{findings_html}
</div>


<div class="sec rv">
  <h2 class="body">How Often You Take Breaks</h2>
  <p class="desc">We looked at the gaps between your messages to detect when you stepped away (10+ minute gap = a break).</p>

  <div class="split-bar" style="margin:20px 0">
    <div class="split-labels"><span style="color:var(--g)">Took a break</span><span style="color:var(--t3)">No break detected</span></div>
    <div class="split-track">
      <div class="split-fill" style="width:{wb_pct}%;background:var(--g)" title="{with_breaks} sessions"></div>
      <div class="split-fill" style="width:{wob_pct}%;background:var(--s3)" title="{without_breaks} sessions"></div>
    </div>
    <div class="split-labels"><span style="color:var(--g)">{with_breaks} sessions ({wb_pct}%)</span><span style="color:var(--t3)">{without_breaks} sessions ({wob_pct}%)</span></div>
  </div>

  <p class="desc" style="margin-top:16px"><strong>How long do you code before your first break?</strong> This shows the longest unbroken stretch in each session:</p>
  <div id="stretches"></div>

  <details class="learn"><summary>How we detect breaks</summary><div class="sci">We look at the time between each of your messages. A <strong>10+ minute gap</strong> means you likely stepped away. Gaps under 5 min are continuous coding. 5-10 min is thinking/reading time. This is not perfect, but across hundreds of sessions the pattern is reliable. Your body needs you to stand up every 60-90 minutes. Blood flow to your legs drops ~50% after 90 min of sitting.</div></details>
</div>

<div class="sec rv">
  <h2 class="eyes">Screen Time and Your Eyes</h2>
  <p class="desc">Your eyes were locked on a screen for <strong>{eye_hours} hours</strong>. When you read code, you blink about 60% less than normal. Over {span} days, that adds up to roughly <strong>{blinks_missed:,} missed blinks</strong>, which is why your eyes feel dry, tired, or blurry by evening.</p>
  <details class="learn"><summary>Why this matters</summary><div class="sci">Normal blink rate is 15-20 times per minute. While reading code or debugging, it drops to 4-7. Each missed blink means your eye surface dries a tiny bit more. Over hours, this causes <strong>dry eye syndrome, headaches, and blurred vision</strong>. The fix is simple: every 20 minutes, look at something 20 feet away for 20 seconds. This relaxes the focusing muscle inside your eye and triggers a few full blinks. Wave Dev Health nudges you every 20 minutes with this reminder.</div></details>
</div>

<div class="sec rv">
  <h2 class="sleep">When You Code</h2>
  <p class="desc">Your sessions grouped by time of day. <strong>Late night coding (after 10pm) affects your sleep quality</strong>, which affects your code quality the next day.</p>
  <div id="blocks"></div>
  <details class="learn"><summary>Why late night matters</summary><div class="sci">Your brain produces melatonin (the sleep hormone) when it gets dark. Screen light after 10pm can <strong>cut melatonin production by up to 50%</strong>. This reduces deep sleep, REM sleep, and memory consolidation. The code you wrote today gets processed while you sleep. Bad sleep = the learning does not stick. Wave Dev Health nudges you gently after 11pm and more directly after 2am.</div></details>
</div>

<div class="sec rv">
  <h2 class="recovery">Rest Days and Recovery</h2>
  <p class="desc">You coded <strong>{active_days} out of {span} days</strong>. That is only <strong>{rest_days} days off</strong>. Your longest stretch was <strong>{max_streak} days in a row</strong> without taking a single day off from coding.</p>
  <div id="hm" class="hm" style="margin-bottom:10px"></div>
  <details class="learn"><summary>Why this matters</summary><div class="sci">{"<strong>"+str(max_streak)+" days without rest is a serious concern.</strong> " if max_streak >= 10 else ""}Your wrists, forearms, shoulders, and eyes are doing repetitive motions for hours every day. Without rest days, <strong>tiny amounts of damage accumulate</strong> faster than your body can repair them. This is exactly how RSI (repetitive strain injury) develops: not from one bad day, but from many days in a row without recovery. Professional athletes train 5 days and rest 2. Your hands deserve the same. Wave Dev Health warns you when your streak hits 7+ days.</div></details>
</div>

<div class="sec rv">
  <h2 class="brain">Stress and Frustration</h2>
  <p class="desc">When you code, you are not always in the same mental state. Sometimes you are building something new (focused, creative). Sometimes you are stuck debugging (tense, frustrated). <strong>Frustrated sessions are harder on your body</strong> because you tense up, breathe shallowly, and grind for hours without stopping.</p>
  <div class="mood">
    <div class="dw"><svg viewBox="0 0 128 128">{donut_svg}</svg><div class="dc"><div class="dn">Mood</div><div class="ds">breakdown</div></div></div>
    <div class="mleg">{mood_legend}</div>
  </div>
  {('<details class="learn" style="margin-top:14px"><summary>Why this matters</summary><div class="sci">Your frustrated sessions last <strong>'+str(frust_ratio)+'x longer</strong> than your building sessions ('+str(frust_dur)+' min vs '+str(build_dur)+' min). When you hit a wall, you do not stop. You keep going. The problem: frustration triggers your stress response. Your shoulders tense, your jaw clenches, your breathing gets shallow, and your body floods with cortisol. A 5-minute walk during a debugging session <strong>actually helps you solve the problem faster</strong> because it lets your subconscious process while your body resets. Wave Dev Health reads your prompts and detects when you are frustrated. After 3 frustrated prompts in a row, it intervenes.</div></details>') if frust_ratio > 2 and len(frust_s) > 2 else '<details class="learn"><summary>Why this matters</summary><div class="sci">Frustration triggers your stress response: tense shoulders, shallow breathing, jaw clenching. When you notice you are grinding on something for over 30 minutes without progress, stepping away for 5 minutes helps more than staring for another hour. Wave Dev Health detects frustration from your prompt text and intervenes early.</div></details>'}
</div>


<div class="sec rv">
  <h2 class="body">What Wave Dev Health Does About This</h2>
  <div class="fg">
    <div class="ft"><div class="tm">Every 20 min</div><div class="ds2">Eye break. 20-20-20 rule. Prevents the dry-eye cascade.</div></div>
    <div class="ft"><div class="tm">Every 35 min</div><div class="ds2">Hydration + posture. Counters dehydration and slouching.</div></div>
    <div class="ft"><div class="tm">Every 50 min</div><div class="ds2">Stretch. Specific exercises for wrists, back, shoulders.</div></div>
    <div class="ft"><div class="tm">90 min no break</div><div class="ds2">Stand up and walk. Blood flow restored in 2 minutes.</div></div>
    <div class="ft"><div class="tm">Frustrated 3+ prompts</div><div class="ds2">Detects frustration from your text. Breathing exercises.</div></div>
    <div class="ft"><div class="tm">After 11pm</div><div class="ds2">Sleep impact reminder. Gentle, no judgment.</div></div>
    <div class="ft"><div class="tm">7+ days straight</div><div class="ds2">Burnout warning. Your body needs rest days.</div></div>
    <div class="ft"><div class="tm">Project switch</div><div class="ds2">Context switch = take a breath. Working memory reset.</div></div>
  </div>
</div>

<div class="sec rv">
  <h2 class="load">Commands</h2>
  <div class="cms">
    <div class="cm"><code>/pulse</code><span class="cd2">Stats + health score</span></div>
    <div class="cm"><code>/pulse dashboard</code><span class="cd2">Visual health board</span></div>
    <div class="cm"><code>/pulse break</code><span class="cd2">Log a break + tip</span></div>
    <div class="cm"><code>/pulse report</code><span class="cd2">Weekly report</span></div>
    <div class="cm"><code>/pulse energy 1-5</code><span class="cd2">Track energy</span></div>
    <div class="cm"><code>/pulse config</code><span class="cd2">Adjust settings</span></div>
  </div>
</div>

<div class="ftr">
  <p style="color:var(--t2);font-size:13px">All data stays on your machine. Nothing sent anywhere. Ever.</p>
  <p>Powered by <a href="https://wave.so/health">Wave</a></p>
</div>

</div>
<script>
const BL={block_json},ST={stretch_json},HM={hm_json};
const O=new IntersectionObserver(e=>e.forEach(x=>{{if(x.isIntersecting){{x.target.classList.add('vis');O.unobserve(x.target)}}}}),{{threshold:.1}});
document.querySelectorAll('.rv').forEach(e=>O.observe(e));
document.querySelectorAll('[data-c]').forEach(el=>{{const t=parseInt(el.dataset.c);if(isNaN(t))return;
const io=new IntersectionObserver(e=>{{if(e[0].isIntersecting){{const s=performance.now();
(function a(n){{const p=Math.min((n-s)/1200,1);el.textContent=Math.round(t*(1-Math.pow(1-p,3)));
if(p<1)requestAnimationFrame(a)}})(s);io.disconnect()}}}});io.observe(el)}});
// Time blocks
document.getElementById('blocks').innerHTML=BL.map(b=>
  '<div class="block-row"><div class="block-name">'+b.name+'</div><div class="block-time">'+b.label+'</div><div class="block-bar-wrap"><div class="block-bar" style="background:'+b.color+'" data-w="'+b.bar+'"></div></div><div class="block-count">'+b.count+' sessions</div><div class="block-pct" style="color:'+b.color+'">'+b.pct+'%</div></div>'
).join('');
setTimeout(()=>document.querySelectorAll('.block-bar').forEach(b=>b.style.width=b.dataset.w+'%'),200);

// Stretch distribution
document.getElementById('stretches').innerHTML=ST.filter(d=>d.c>0).map(d=>
  '<div class="str-row"><div class="str-label">'+d.l+'</div><div class="str-bar-wrap"><div class="str-bar '+d.s+'" data-w="'+d.bar+'"></div></div><div class="str-count">'+d.c+'</div></div>'
).join('');
setTimeout(()=>document.querySelectorAll('.str-bar').forEach(b=>b.style.width=b.dataset.w+'%'),300);
const hel=document.getElementById('hm');const mx=Math.max(...HM.map(d=>d.c),1);
let wk=-1,col;HM.forEach(d=>{{const w=Math.floor((new Date(d.d)-new Date(HM[0].d))/(7*864e5));
if(w!==wk){{col=document.createElement('div');col.className='hm-c';hel.appendChild(col);wk=w}}
const c=document.createElement('div');c.className='hm-d';c.title=d.d+': '+d.c;
const r=d.c/mx;if(r>.75)c.classList.add('l4');else if(r>.5)c.classList.add('l3');
else if(r>.25)c.classList.add('l2');else if(d.c>0)c.classList.add('l1');col.appendChild(c)}});
</script>
</body>
</html>'''

with open(html_path, 'w') as f:
    f.write(html)
print(f"PROFILE_READY:{html_path}")
print(f"SESSIONS:{T}")
print(f"VERDICT:{verdict}")
