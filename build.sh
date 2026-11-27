#!/bin/zsh
# Builds build/AudioHub.app with the Xcode Command Line Tools — full Xcode is not needed.
#   ./build.sh            build
#   SDK=/path/to.sdk ./build.sh   force a specific macOS SDK
set -e
cd "$(dirname "$0")"
APP=build/AudioHub.app
SOURCES=(Sources/audiohub/*.swift)
FRAMEWORKS=(-framework CoreAudio -framework AudioToolbox -framework AppKit -framework Network
            -framework AVFoundation -framework SwiftUI)

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
# Release builds (scripts/release.sh sets RELEASE=1) may install updates in-app;
# builds from source only announce them.
[ "$RELEASE" = 1 ] && plutil -insert AHReleaseBuild -bool true "$APP/Contents/Info.plist"
rsync -a --delete Resources/ "$APP/Contents/Resources/"   # translations (*.lproj)

compile() {
  swiftc -sdk "$1" -target "$(uname -m)-apple-macos14.2" -O -suppress-warnings ${=SWIFTFLAGS} \
    -I Sources/CAtomics/include \
    -o "$APP/Contents/MacOS/audiohub" $SOURCES $FRAMEWORKS
}

# Try the requested/default SDK first. If the Command Line Tools were updated only partly
# (newer SDK than compiler), fall back to older installed SDKs (14.2+ has the needed APIs).
if [ -n "$SDK" ]; then
  CANDIDATES=("$SDK")
else
  CANDIDATES=("$(xcrun --show-sdk-path)" $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX1[45]*.sdk 2>/dev/null | sort -rV))
fi
for sdk in $CANDIDATES; do
  if compile "$sdk" 2>build/compile.log; then
    echo "SDK: $sdk"; ok=1; break
  fi
  echo "SDK $sdk failed, trying next…" >&2
done
[ -n "$ok" ] || { cat build/compile.log; exit 1; }

# Sign with the "AudioHub Local Signing" certificate when present (see scripts/make-signing-cert.sh):
# macOS then ties the audio-capture and local-network permissions to that certificate, so
# they survive rebuilds. Without it, fall back to ad-hoc signing (permissions must then be
# granted again after every build).
CERT=$(security find-identity -p codesigning 2>/dev/null | awk '/"AudioHub Local Signing"/{print $2; exit}')
codesign -s "${CERT:--}" -i local.audiohub --force "$APP"
[ -n "$CERT" ] || echo "note: signed ad-hoc; run scripts/make-signing-cert.sh to keep permissions across builds" >&2
echo "built: $APP"
