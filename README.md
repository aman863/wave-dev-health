# Rox

A developer health companion for Claude Code. Runs silently in the background, detects breaks, tracks your session across projects, and delivers contextual health nudges that Claude personalizes to what you're actually working on.

## How it works

1. **Background companion** — A hook runs on every prompt. It tracks your session timing, detects breaks, and monitors your emotional arc. When a nudge is due, it injects context into Claude's response. Claude reads your actual prompt and crafts a personalized health touch.

2. **Smart break detection** — Measures real idle time (prompt gap minus Claude's processing time). A 5+ minute gap where YOU weren't typing = real break. Claude processing for 12 minutes doesn't count as your break.

3. **Escalating nudges** — Every 20 min without a real break, a nudge fires. Tier = how many you've ignored:
   - Tier 1: Friendly one-liner
   - Tier 2: Light sarcasm with ASCII art
   - Tier 3: Full block with body battery
   - Tier 4: Roast mode
   
   Take a real break → resets to friendly Tier 1.

4. **Companion touches** — Beyond nudges, the companion responds to moments: session start (with last-session context), break celebrations, frustration support, success, late night awareness.

5. **Cross-session tracking** — Works across multiple parallel Claude sessions. Tracks what you're working on in each. A break only counts if ALL sessions are idle.

6. **LLM-first analysis** — The hook provides timing data. Claude does the actual analysis: reads your prompt, understands your mood, what you're debugging, and personalizes the health tip to your specific moment.

## Install

**Paste this into Claude Code:**

```
Install wave dev health: clone the repo and run setup.
git clone https://github.com/aman863/wave-dev-health.git ~/wave-dev-health && bash ~/wave-dev-health/setup
```

That's it. Background nudges and companion touches begin automatically.

## What it tracks

| Signal | How | Used for |
|--------|-----|----------|
| Time since last break | Prompt gaps minus Claude processing | Nudge timing, body battery |
| Nudges since last break | Counter, resets on real break | Tier escalation (1→4) |
| Cross-session activity | Shared activity log across all sessions | Parallel session detection |
| Mood signals | Keyword heuristics (for trigger timing only) | Frustration companion, escalation |

Claude does the real mood/context analysis by reading your prompts. The keyword detection is just for deciding WHEN to trigger companions.

## Data

All data stored locally at `~/.wave-dev-health/`. Nothing leaves your machine.

- `state.json` — Session state, nudge timers, break tracking
- `today_activity.log` — Cross-session activity timeline
- `global_active` — Last activity timestamp (file mtime)
- `shown_tips.json` — Tip rotation (no repeats)

## Debug mode

```bash
touch ~/.wave-dev-health/debug    # Enable (timers compress to seconds)
rm ~/.wave-dev-health/debug       # Disable (back to normal)
```

---

Powered by [Rox](https://wavehealth.app)
