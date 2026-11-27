#!/bin/zsh
# Builds AudioHub, copies it to /Applications and (re)starts it.
#
#   scripts/install.sh              keep the kind of build that is installed now (default)
#   scripts/install.sh --release    install a release build (in-app updates can install)
#   scripts/install.sh --source     install a source build (in-app updates only notify)
#   scripts/install.sh --force      also allow replacing a newer installed version
#
# Why "keep": a release build installed from GitHub (or by the in-app updater) must stay a
# release build, otherwise one-click updates silently turn into notifications.
#
# For tests: INSTALL_DIR (default /Applications), NO_LAUNCH=1 (do not stop/start the app).
set -e
cd "$(dirname "$0")/.."

MODE=auto FORCE=0
for a in "$@"; do
  case "$a" in
    --release) MODE=release ;;
    --source)  MODE=source ;;
    --force)   FORCE=1 ;;
    *) echo "usage: scripts/install.sh [--release|--source] [--force]"; exit 2 ;;
  esac
done

DEST_DIR="${INSTALL_DIR:-/Applications}"
DEST="$DEST_DIR/AudioHub.app"
INSTALLED_PLIST="$DEST/Contents/Info.plist"
installed_value() { plutil -extract "$1" raw "$INSTALLED_PLIST" 2>/dev/null || true; }

if [ "$MODE" = auto ]; then
  if [ "$(installed_value AHReleaseBuild)" = true ]; then
    MODE=release
    echo "Installed copy is a release build: keeping it a release build."
  else
    MODE=source
  fi
fi

if [ "$MODE" = release ] && ! security find-identity -p codesigning 2>/dev/null | grep -q '"AudioHub Local Signing"'; then
  echo "A release build must be signed with the AudioHub Local Signing certificate, which is missing."
  echo "Run scripts/make-signing-cert.sh, or install a source build with --source."
  exit 1
fi

# Never silently go back to an older version (e.g. after the app updated itself from GitHub).
NEW_VERSION=$(plutil -extract CFBundleShortVersionString raw Info.plist)
OLD_VERSION=$(installed_value CFBundleShortVersionString)
if [ -n "$OLD_VERSION" ] && [ "$FORCE" != 1 ]; then
  HIGHER=$(printf '%s\n%s\n' "$OLD_VERSION" "$NEW_VERSION" | sort -V | tail -1)
  if [ "$HIGHER" = "$OLD_VERSION" ] && [ "$OLD_VERSION" != "$NEW_VERSION" ]; then
    echo "Installed version $OLD_VERSION is newer than this checkout ($NEW_VERSION). Pull, or use --force."
    exit 1
  fi
fi

if [ "$MODE" = release ]; then RELEASE=1 ./build.sh; else ./build.sh; fi

if [ "$NO_LAUNCH" != 1 ]; then
  pkill -f "AudioHub.app/Contents/MacOS/audiohub" 2>/dev/null || true
  sleep 1
fi
mkdir -p "$DEST_DIR"
rm -rf "$DEST.installing"
ditto build/AudioHub.app "$DEST.installing"
rm -rf "$DEST"
mv "$DEST.installing" "$DEST"
[ "$NO_LAUNCH" = 1 ] || open "$DEST"
echo "Installed $DEST ($MODE build, version $NEW_VERSION)"
