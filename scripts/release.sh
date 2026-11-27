#!/bin/zsh
# One-command release:
#
#   scripts/release.sh 0.3.1                    bump, build, test, sign, push, tag, draft release
#   scripts/release.sh 0.3.1 --notes notes.md   use notes.md as the release description
#   scripts/release.sh 0.3.1 --publish          publish right away instead of leaving a draft
#   scripts/release.sh 0.3.1 --no-github        stop after build + signing (nothing pushed)
#
# Steps:
#  1. checks: clean tree, on main, not behind origin, tag v<version> not used yet
#  2. sets CFBundleShortVersionString (and bumps CFBundleVersion) and commits, if needed
#  3. release build, selftest, zip, Ed25519 signature
#  4. pushes main and the tag v<version> — the tag is the exact commit the zip was built from
#  5. creates the GitHub release with both files via `gh` (draft unless --publish);
#     without `gh`, prints what to upload by hand
set -e
cd "$(dirname "$0")/.."

V="" NOTES="" PUBLISH=0 GITHUB=1
while [ $# -gt 0 ]; do
  case "$1" in
    --notes) NOTES="$2"; shift ;;
    --publish) PUBLISH=1 ;;
    --no-github) GITHUB=0 ;;
    -*) echo "unknown option $1"; exit 2 ;;
    *) V="$1" ;;
  esac
  shift
done
[[ "$V" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "usage: scripts/release.sh <x.y.z> [--notes file] [--publish] [--no-github]"; exit 2; }
[ -z "$NOTES" ] || [ -f "$NOTES" ] || { echo "Notes file $NOTES not found."; exit 1; }
TAG="v$V"
step() { echo; echo "== $*"; }
fail() { echo "✗ $*"; exit 1; }

step "Checks"
[ -z "$(git status --porcelain)" ] || fail "Uncommitted changes. Commit or stash them first."
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || fail "Not on main."
[ -n "$(plutil -extract AHUpdatePublicKey raw Info.plist 2>/dev/null)" ] || fail "AHUpdatePublicKey is empty; run update-keygen."
security find-identity -p codesigning | grep -q '"AudioHub Local Signing"' \
  || fail "Release builds must be signed with the AudioHub Local Signing certificate."
if [ "$GITHUB" = 1 ]; then
  git fetch -q origin main --tags || fail "Could not reach origin."
  [ "$(git rev-list --count HEAD..origin/main)" = 0 ] || fail "origin/main has commits you don't have. Pull first."
  git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1 && fail "Tag $TAG already exists on origin."
fi
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "Tag $TAG already exists locally."
OLD=$(plutil -extract CFBundleShortVersionString raw Info.plist)
if [ "$OLD" != "$V" ]; then
  HIGHER=$(printf '%s\n%s\n' "$OLD" "$V" | sort -V | tail -1)
  [ "$HIGHER" = "$V" ] || fail "$V is not newer than the current version $OLD."
fi
echo "ok: clean main, version $OLD → $V"

if [ "$OLD" != "$V" ]; then
  step "Version $V"
  BUILD=$(( $(plutil -extract CFBundleVersion raw Info.plist) + 1 ))
  # Text edits keep Info.plist's formatting (plutil -replace would rewrite the whole file).
  sed -i '' "s|<key>CFBundleShortVersionString</key><string>$OLD</string>|<key>CFBundleShortVersionString</key><string>$V</string>|" Info.plist
  sed -i '' "s|<key>CFBundleVersion</key><string>[0-9]*</string>|<key>CFBundleVersion</key><string>$BUILD</string>|" Info.plist
  plutil -lint Info.plist >/dev/null
  [ "$(plutil -extract CFBundleShortVersionString raw Info.plist)" = "$V" ] || fail "Could not set the version in Info.plist."
  git commit -q -am "Version $V"
  echo "committed $(git rev-parse --short HEAD)"
fi
COMMIT=$(git rev-parse --short HEAD)

step "Build, test, sign ($COMMIT)"
RELEASE=1 ./build.sh
BIN=build/AudioHub.app/Contents/MacOS/audiohub
$BIN selftest > build/release-selftest.log 2>&1 || { tail -20 build/release-selftest.log; fail "selftest failed (nothing pushed)."; }
echo "selftest: $(tail -1 build/release-selftest.log)"
ZIP=build/AudioHub-$V.zip
rm -f "$ZIP" "$ZIP.sig"
ditto -c -k --keepParent build/AudioHub.app "$ZIP"
$BIN sign-update "$ZIP"
ls -l "$ZIP" "$ZIP.sig"

if [ "$GITHUB" = 0 ]; then
  step "Done (--no-github): nothing was pushed"
  echo "Files: $ZIP $ZIP.sig — the version commit, if any, is local."
  exit 0
fi

step "Push $COMMIT and tag $TAG"
git tag -a "$TAG" -m "AudioHub $V" "$COMMIT"
git push -q origin main
git push -q origin "$TAG"
echo "pushed main and $TAG → $COMMIT"

step "GitHub release"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  ARGS=(release create "$TAG" "$ZIP" "$ZIP.sig" --title "AudioHub $V" --verify-tag)
  if [ -n "$NOTES" ]; then ARGS+=(--notes-file "$NOTES"); else ARGS+=(--notes "AudioHub $V"); fi
  [ "$PUBLISH" = 1 ] || ARGS+=(--draft)
  URL=$(gh "${ARGS[@]}")
  if [ "$PUBLISH" = 1 ]; then echo "Published: $URL"; else echo "Draft created: $URL"; echo "Review the notes there and press Publish."; fi
else
  REPO_URL=$(git remote get-url origin | sed -E 's#^git@github.com:#https://github.com/#; s#\.git$##')
  echo "GitHub CLI (gh) is not installed or not logged in, so create the release by hand:"
  echo "  $REPO_URL/releases/new?tag=$TAG"
  echo "  title: AudioHub $V — attach $ZIP and $ZIP.sig"
fi
