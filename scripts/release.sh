#!/bin/zsh
# Builds, tests, zips and signs a release:  scripts/release.sh 0.2.1
# Then attach build/AudioHub-<version>.zip and .zip.sig to a GitHub release tagged v<version>.
set -e
cd "$(dirname "$0")/.."
V="$1"
[ -n "$V" ] || { echo "usage: scripts/release.sh <version>   (e.g. 0.2.1)"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Commit your changes first (the release must match a commit)."; exit 1; }
PLIST_V=$(plutil -extract CFBundleShortVersionString raw Info.plist)
[ "$PLIST_V" = "$V" ] || { echo "Info.plist says $PLIST_V, not $V. Bump CFBundleShortVersionString and commit."; exit 1; }
[ -n "$(plutil -extract AHUpdatePublicKey raw Info.plist 2>/dev/null)" ] || { echo "AHUpdatePublicKey is empty; run update-keygen."; exit 1; }
security find-identity -p codesigning | grep -q '"AudioHub Local Signing"' \
  || { echo "Release builds must be signed with the AudioHub Local Signing certificate."; exit 1; }

RELEASE=1 ./build.sh
BIN=build/AudioHub.app/Contents/MacOS/audiohub
$BIN selftest > build/release-selftest.log 2>&1 || { tail -20 build/release-selftest.log; echo "selftest failed"; exit 1; }
echo "selftest: $(tail -1 build/release-selftest.log)"

ZIP=build/AudioHub-$V.zip
rm -f "$ZIP" "$ZIP.sig"
ditto -c -k --keepParent build/AudioHub.app "$ZIP"
$BIN sign-update "$ZIP"
echo
echo "Release v$V ($(git rev-parse --short HEAD)):"
ls -l "$ZIP" "$ZIP.sig"
echo
echo "Next: git push, then on GitHub create release v$V from main and attach both files."
