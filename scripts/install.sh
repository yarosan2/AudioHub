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
# The old copy is kept until the new one is in place and verified; any failure restores it.
#
# For tests: INSTALL_DIR (default /Applications), NO_LAUNCH=1 (do not stop/start the app),
# INSTALL_TEST_FAIL=rename|verify (simulate a failure at that step).
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
STAGED="$DEST.installing"
BACKUP="$DEST.previous"
had_old=0 placed=0

rollback() {
  echo "✗ $1 — restoring the previous version."
  if [ "$had_old" = 0 ] && [ "$placed" = 1 ]; then
    rm -rf "$DEST"   # first install: don't leave an unverified copy behind
  fi
  if [ "$had_old" = 1 ] && [ -d "$BACKUP" ]; then
    [ -e "$DEST" ] && rm -rf "$DEST"
    if mv "$BACKUP" "$DEST"; then
      echo "  previous version restored at $DEST"
    else
      echo "  could NOT restore it automatically; it is at $BACKUP — move it back to $DEST"
    fi
  fi
  rm -rf "$STAGED"
  exit 1
}
fail_here() { [ "$INSTALL_TEST_FAIL" = "$1" ]; }

# Leftovers of an interrupted earlier run.
[ -e "$STAGED" ] && rm -rf "$STAGED"
if [ -d "$BACKUP" ] && [ ! -e "$DEST" ]; then
  mv "$BACKUP" "$DEST" && echo "Restored $DEST from an interrupted earlier install."
fi
[ -e "$BACKUP" ] && rm -rf "$BACKUP"

# 1. Stage the new copy next to the destination (same volume, so the swaps are renames)
#    and check it before touching the installed one.
ditto build/AudioHub.app "$STAGED" || { rm -rf "$STAGED"; echo "✗ could not copy the new build; nothing changed"; exit 1; }
codesign --verify --deep --strict "$STAGED" 2>/dev/null || { rm -rf "$STAGED"; echo "✗ the new build's signature is invalid; nothing changed"; exit 1; }

# 2. Move the old copy aside (not deleted yet).
if [ -e "$DEST" ]; then
  mv "$DEST" "$BACKUP" || { rm -rf "$STAGED"; echo "✗ could not move the installed copy aside; nothing changed"; exit 1; }
  had_old=1
fi

# 3. Put the new one in place and verify it there.
if fail_here rename || ! mv "$STAGED" "$DEST"; then rollback "could not put the new version in place"; fi
placed=1
if fail_here verify || ! codesign --verify --deep --strict "$DEST" 2>/dev/null \
   || [ "$(plutil -extract CFBundleShortVersionString raw "$DEST/Contents/Info.plist" 2>/dev/null)" != "$NEW_VERSION" ]; then
  rollback "the installed copy failed verification"
fi

# 4. Only now drop the old copy.
[ "$had_old" = 1 ] && rm -rf "$BACKUP"
[ "$NO_LAUNCH" = 1 ] || open "$DEST"
echo "Installed $DEST ($MODE build, version $NEW_VERSION)"
