#!/bin/zsh
# Runs AudioHub.app with CLI arguments; output goes to build/audiohub.log (tailed here).
# Launching through `open` makes macOS treat it as its own app, so permission prompts work.
cd "$(dirname "$0")"
LOG=build/audiohub.log; : > $LOG
tail -f $LOG & T=$!
ENV=()
[ -n "$AUDIOHUB_DEBUG" ] && ENV+=(--env AUDIOHUB_DEBUG=1)
[ -n "$AUDIOHUB_DROP_EVERY" ] && ENV+=(--env AUDIOHUB_DROP_EVERY=$AUDIOHUB_DROP_EVERY)
open -W -n $ENV build/AudioHub.app --stdout $LOG --stderr $LOG --args "$@"
kill $T 2>/dev/null
