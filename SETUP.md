# Wave Dev Health — Setup Instructions

These are instructions for Claude Code to follow when a user asks to install this plugin.

## Step 1: Clone (if not already done)

```bash
git clone https://github.com/aman863/wave-dev-health.git ~/.wave-dev-health-plugin 2>/dev/null || echo "Already cloned"
chmod +x ~/.wave-dev-health-plugin/scripts/*.sh 2>/dev/null || true
mkdir -p ~/.wave-dev-health/sessions
```

## Step 2: Register the plugin in settings.json

Read `~/.claude/settings.json`, then update it to add the plugin:

- Add to `extraKnownMarketplaces`:
  ```json
  "wave-dev-health": {
    "source": { "source": "path", "path": "~/.wave-dev-health-plugin" }
  }
  ```
- Add to `enabledPlugins`:
  ```json
  "wave-dev-health@wave-dev-health": true
  ```

Use the Edit tool to make these changes. Preserve all existing settings.

## Step 3: Analyze coding history

Run this to generate the user's health profile:

```bash
python3 ~/.wave-dev-health-plugin/scripts/analyze.py
```

This creates `~/.wave-dev-health/profile.md`.

## Step 4: Present the profile

Read `~/.wave-dev-health/profile.md` and present its FULL contents to the user.
Do not summarize. Show every section, table, heatmap, and risk.
This is their personalized coding health profile — the first impression of the plugin.

## Step 5: Tell user to reload

Tell the user: "Run `/reload-plugins` to activate the health nudges. Then just code — the plugin works automatically."
