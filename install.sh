#!/bin/bash
# Wave Dev Health — One-line installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/aman863/wave-dev-health/main/install.sh | bash
#
# Or:
#   git clone https://github.com/aman863/wave-dev-health.git ~/.wave-dev-health-plugin
#   bash ~/.wave-dev-health-plugin/install.sh

set -euo pipefail

INSTALL_DIR="$HOME/.wave-dev-health-plugin"
SETTINGS_FILE="$HOME/.claude/settings.json"

echo ""
echo "  ╔══════════════════════════════════════╗"
echo "  ║     Wave Dev Health — Installer      ║"
echo "  ╚══════════════════════════════════════╝"
echo ""

# Step 1: Clone if not already local
if [ ! -d "$INSTALL_DIR/.claude-plugin" ]; then
  echo "  Downloading plugin..."
  if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
  fi
  git clone --depth 1 https://github.com/aman863/wave-dev-health.git "$INSTALL_DIR" 2>/dev/null
  echo "  ✓ Downloaded to $INSTALL_DIR"
else
  echo "  ✓ Plugin already at $INSTALL_DIR"
fi

# Step 2: Add to Claude Code settings
echo "  Configuring Claude Code..."
mkdir -p "$(dirname "$SETTINGS_FILE")"

if [ -f "$SETTINGS_FILE" ]; then
  # Merge into existing settings using python
  python3 -c "
import json, sys

f = '$SETTINGS_FILE'
try:
    settings = json.load(open(f))
except:
    settings = {}

# Add marketplace
if 'extraKnownMarketplaces' not in settings:
    settings['extraKnownMarketplaces'] = {}
settings['extraKnownMarketplaces']['wave-dev-health'] = {
    'source': {'source': 'directory', 'path': '$INSTALL_DIR'}
}

# Enable plugin
if 'enabledPlugins' not in settings:
    settings['enabledPlugins'] = {}
settings['enabledPlugins']['wave-dev-health@wave-dev-health'] = True

json.dump(settings, open(f, 'w'), indent=2)
print('  ✓ Updated $SETTINGS_FILE')
" || {
    echo "  ✗ Could not update settings.json automatically."
    echo "  Add this to $SETTINGS_FILE manually:"
    echo '  "extraKnownMarketplaces": { "wave-dev-health": { "source": { "source": "directory", "path": "'$INSTALL_DIR'" } } }'
    echo '  "enabledPlugins": { "wave-dev-health@wave-dev-health": true }'
  }
else
  # Create new settings file
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
  echo "  ✓ Created $SETTINGS_FILE"
fi

chmod +x "$INSTALL_DIR/scripts/wellness-check.sh"
chmod +x "$INSTALL_DIR/scripts/first-run.sh" 2>/dev/null || true

echo ""
echo "  ╔══════════════════════════════════════╗"
echo "  ║          ✓ Installed!                ║"
echo "  ╠══════════════════════════════════════╣"
echo "  ║  Start a new Claude Code session.    ║"
echo "  ║  The plugin will analyze your past   ║"
echo "  ║  coding sessions and show you your   ║"
echo "  ║  health profile automatically.       ║"
echo "  ║                                      ║"
echo "  ║  Then it just works. No config.      ║"
echo "  ╚══════════════════════════════════════╝"
echo ""
