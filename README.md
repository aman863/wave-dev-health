# Wave Dev Health

A Claude Code plugin that keeps you healthy while you code. Tracks your coding sessions, delivers context-aware health nudges, and builds a local developer health profile.

## How it works

1. **Background nudges** — A hook runs on every prompt. After 50 minutes of coding, it injects a health tip into Claude's context. Claude weaves the tip naturally into its response. No pop-ups, no interruptions.

2. **Smart timing** — The hook only fires when you're actively coding. If you step away (no Claude interactions), the timer pauses. Nudges don't stack up.

3. **Health content** — Each nudge teaches something specific about your body: why your wrists hurt, what happens to your eyes during debugging, how sitting affects blood flow. Not generic "take a break" reminders.

4. **Local profile** — Session data stays on your machine at `~/.wave-dev-health/`. Nothing is sent anywhere. Over time, the plugin builds a health profile with your patterns.

## Install

```bash
claude --plugin-dir /path/to/wave-dev-health
```

Or clone and reference:
```bash
git clone https://github.com/aman863/wave-dev-health.git
claude --plugin-dir ./wave-dev-health
```

## Commands

| Command | What it does |
|---------|-------------|
| `/pulse` | Current session stats |
| `/pulse stats` | Detailed session summary |
| `/pulse break` | Log a break + get a health tip |
| `/pulse dashboard` | ASCII health dashboard |
| `/pulse report` | Weekly health report |
| `/pulse profile` | Your health profile |
| `/pulse energy [1-5]` | Log your energy level |
| `/pulse config` | View/change settings |
| `/pulse snooze [duration]` | Snooze next nudge |
| `/pulse reset` | Delete all local data |

## Configuration

```
/pulse config interval 30m    # Change nudge interval
/pulse config energy off      # Disable energy prompts
/pulse config disable         # Pause all nudges
/pulse config enable          # Resume nudges
```

## Data

All data stored locally at `~/.wave-dev-health/`:
- `state.json` — Current session state
- `sessions/` — Per-session history
- `energy.json` — Energy journal
- `config.json` — Your preferences

No data leaves your machine. Ever.

## Wave Health Score

A composite 0-100 score based on:
- Break compliance (40%)
- Session length discipline (20%)
- Schedule consistency (15%)
- Energy trend (15%, if opted in)
- Rest day balance (10%)

Uses your own patterns as baseline. Night owls aren't penalized for coding at night.

---

Powered by [Wave](https://wave.so/health) — AI health companion.
