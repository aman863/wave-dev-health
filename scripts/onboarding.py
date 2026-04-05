#!/usr/bin/env python3
"""Wave Dev Health — Onboarding analysis
Scans last 7 days of Claude Code sessions and prints a quick health snapshot.
Runs during setup. No data leaves the machine."""

import json, os, glob, time, sys
from collections import defaultdict
from datetime import datetime

PROJECTS_DIR = os.path.expanduser("~/.claude/projects/")
NOW = int(time.time())
WEEK_AGO = NOW - 7 * 86400

def analyze():
    if not os.path.isdir(PROJECTS_DIR):
        print("  No Claude Code session history found. That's fine.")
        print("  Wave will start tracking from your next session.")
        return

    days_active = set()
    total_prompts = 0
    sessions = 0
    breaks_by_day = defaultdict(int)
    prompts_by_day = defaultdict(int)
    day_first_ts = {}   # first prompt timestamp per day
    day_last_ts = {}    # last prompt timestamp per day
    longest_stretch = 0
    longest_stretch_day = ""
    zero_break_days = []

    for proj_dir in glob.glob(PROJECTS_DIR + "*/"):
        basename = os.path.basename(proj_dir.rstrip("/"))
        if "conductor" in basename or "paperclip" in basename:
            continue

        for jsonl_path in glob.glob(proj_dir + "*.jsonl"):
            try:
                if os.path.getmtime(jsonl_path) < WEEK_AGO:
                    continue
            except:
                continue

            timestamps = []
            try:
                with open(jsonl_path) as f:
                    for line in f:
                        try:
                            d = json.loads(line)
                            if d.get("type") == "user" and "timestamp" in d:
                                ts = d["timestamp"]
                                dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                                epoch = int(dt.timestamp())
                                if epoch >= WEEK_AGO:
                                    timestamps.append(epoch)
                                    day = dt.strftime("%Y-%m-%d")
                                    days_active.add(day)
                                    prompts_by_day[day] += 1
                                    total_prompts += 1
                                    if day not in day_first_ts or epoch < day_first_ts[day]:
                                        day_first_ts[day] = epoch
                                    if day not in day_last_ts or epoch > day_last_ts[day]:
                                        day_last_ts[day] = epoch
                        except:
                            pass
            except:
                pass

            if timestamps:
                sessions += 1
                timestamps.sort()
                current_stretch = 0
                for i in range(1, len(timestamps)):
                    gap = timestamps[i] - timestamps[i - 1]
                    if gap >= 600:
                        day = time.strftime("%Y-%m-%d", time.localtime(timestamps[i]))
                        breaks_by_day[day] += 1
                        if current_stretch > longest_stretch:
                            longest_stretch = current_stretch
                            longest_stretch_day = time.strftime(
                                "%A", time.localtime(timestamps[i - 1])
                            )
                        current_stretch = 0
                    else:
                        current_stretch += gap
                if current_stretch > longest_stretch:
                    longest_stretch = current_stretch
                    longest_stretch_day = time.strftime(
                        "%A", time.localtime(timestamps[-1])
                    )

    if total_prompts == 0:
        print("  No recent session data found. Wave will start tracking now.")
        return

    # Find zero-break days (only flag if 60+ min of coding, not short sessions)
    for day in sorted(days_active):
        span = (day_last_ts.get(day, 0) - day_first_ts.get(day, 0)) // 60
        if breaks_by_day.get(day, 0) == 0 and span >= 60:
            zero_break_days.append(day)

    total_breaks = sum(breaks_by_day.values())
    avg_breaks = total_breaks / len(days_active) if days_active else 0
    stretch_min = longest_stretch // 60

    # Print onboarding snapshot
    print()
    print("  ┌──────────────────────────────────────────┐")
    print("  │         Your past week of coding         │")
    print("  └──────────────────────────────────────────┘")
    print()
    print(f"  {len(days_active)} days active  ·  {sessions} sessions  ·  {total_prompts} prompts")
    print(f"  {total_breaks} breaks taken  ·  avg {avg_breaks:.1f} breaks/day")
    print()

    if stretch_min > 0:
        print(f"  Longest unbroken stretch: {stretch_min} min", end="")
        if longest_stretch_day:
            print(f" (on a {longest_stretch_day})", end="")
        print()

    if zero_break_days:
        print(f"  Days with 0 breaks: {len(zero_break_days)}", end="")
        if len(zero_break_days) <= 3:
            names = []
            for d in zero_break_days:
                dt = datetime.strptime(d, "%Y-%m-%d")
                names.append(dt.strftime("%a %b %d"))
            print(f" ({', '.join(names)})", end="")
        print()

    print()

    # Personalized tip based on patterns
    if stretch_min >= 120:
        print(f"  Your longest stretch was {stretch_min} min without a break.")
        print("  Blood flow to your legs drops ~50% after 90 min of sitting.")
        print("  Wave will nudge you before that happens.")
    elif len(zero_break_days) >= 2:
        print(f"  {len(zero_break_days)} days with zero breaks in the last week.")
        print("  Your body doesn't have garbage collection.")
        print("  Wave will remind you to take out the trash.")
    elif avg_breaks < 2:
        print(f"  Averaging {avg_breaks:.1f} breaks per day.")
        print("  Research says 1 break per hour keeps your brain sharp.")
        print("  Wave will help you get there.")
    else:
        print(f"  {avg_breaks:.1f} breaks/day. Not bad.")
        print("  Wave will help you stay consistent.")

    print()
    print("  How it works:")
    print("  · Every 20 min without a real break, you get a nudge")
    print("  · Ignore it? Next one gets sassier (4 tiers of escalation)")
    print("  · Take a 5+ min break? Resets to friendly. We celebrate.")
    print("  · No commands. No dashboards. Just code. Wave watches.")
    print()


if __name__ == "__main__":
    try:
        analyze()
    except Exception as e:
        print(f"  Could not analyze sessions: {e}")
        print("  Wave will start tracking from your next session.")
