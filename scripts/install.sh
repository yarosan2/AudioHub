#!/bin/zsh
# Builds AudioHub, copies it to /Applications and (re)starts it.
set -e
cd "$(dirname "$0")/.."
./build.sh
pkill -f "AudioHub.app/Contents/MacOS/audiohub" 2>/dev/null || true
sleep 1
ditto build/AudioHub.app /Applications/AudioHub.app
open /Applications/AudioHub.app
echo "Installed /Applications/AudioHub.app"
