#!/bin/zsh
# Builds this personal Coucou and installs it as ~/Applications/Coucou Personal.app.
# The official Coucou is quit first: both use the same notch and Claude Code hooks.
set -e
cd "$(dirname "$0")/../NotchBuddy"
command -v xcodegen >/dev/null || brew install xcodegen
xcodegen >/dev/null
xcodebuild -scheme NotchBuddy -configuration Debug -derivedDataPath build/dd build 2>&1 \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
APP="build/dd/Build/Products/Debug/Coucou.app"
[ -d "$APP" ] || { echo "Build failed"; exit 1; }

osascript -e 'quit app id "fr.louisraille.NotchBuddy"' 2>/dev/null || true
osascript -e 'quit app id "com.greatbamba.coucou"' 2>/dev/null || true
sleep 1
mkdir -p ~/Applications
rm -rf ~/Applications/"Coucou Personal.app"
cp -R "$APP" ~/Applications/"Coucou Personal.app"
open ~/Applications/"Coucou Personal.app"
echo "Installed ~/Applications/Coucou Personal.app"
