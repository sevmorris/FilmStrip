#!/usr/bin/env zsh
# release.sh — Build, verify, package, and publish a FilmStrip release.
#
# Usage: ./release.sh <version>
#   e.g. ./release.sh 1.0.0
#
# Requires: xcodebuild, hdiutil, gh (GitHub CLI), git

set -euo pipefail

REPO="sevmorris/FilmStrip"

# ── Args ──────────────────────────────────────────────────────────────────────
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <version>"
    echo "  e.g. $0 1.0.0"
    exit 1
fi

VERSION="$1"
TAG="v${VERSION}"
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="$SCRIPT_DIR"
PROJECT="$PROJECT_DIR/FilmStrip.xcodeproj"
SCHEME="FilmStrip"
DERIVED_DATA="/tmp/filmstrip_build_${VERSION}"
APP_PATH="$DERIVED_DATA/Build/Products/Release/FilmStrip.app"
DMG="/tmp/FilmStrip-${TAG}.dmg"
MOUNT="/tmp/filmstrip_verify_${VERSION}"
DOCS="$PROJECT_DIR/docs/index.html"
DOCS_THEORY="$PROJECT_DIR/docs/theory.html"
MANUAL_IDX="$PROJECT_DIR/docs/manual/index.html"

# ── Helpers ───────────────────────────────────────────────────────────────────
step()  { echo "\n▶ $*"; }
ok()    { echo "  ✓ $*"; }
fail()  { echo "\n  ✗ $*" >&2; exit 1; }

# ── Version format check (after helpers so `fail` is defined) ────────────────
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    fail "Version must be X.Y.Z format (got: $VERSION)"

# ── Preflight ─────────────────────────────────────────────────────────────────
step "Preflight checks"
for cmd in xcodebuild hdiutil gh git codesign xcrun python3; do
    command -v $cmd &>/dev/null || fail "'$cmd' not found in PATH"
done
python3 -c "import dmgbuild" 2>/dev/null \
    || fail "python3 module 'dmgbuild' not installed — run: python3 -m pip install dmgbuild"
ok "Tools present"

cd "$PROJECT_DIR"

if [[ -n "$(git status --porcelain)" ]]; then
    fail "Working tree is dirty — commit or stash changes before releasing"
fi
ok "Working tree clean"

if git tag | grep -q "^${TAG}$"; then
    fail "Tag $TAG already exists — has this version been released?"
fi
ok "Tag $TAG is available"

# ── Shared-file gate ──────────────────────────────────────────────────────────
# Several files here are vendored copies kept byte-identical with the sibling
# app repos — these projects are deliberately independent, so there is no shared
# package to depend on. The failure mode that costs something is silent drift: a
# fix lands in one repo and the others keep the bug. Release day is when someone
# is looking, so it is when to say so.
#
# Absent siblings are not drift — a fresh clone or a CI checkout has none, and
# the check passes quietly. Only a content mismatch stops the release.
step "Checking shared files against sibling repos"
"$PROJECT_DIR/scripts/check-shared.sh" \
    || fail "Shared files have drifted from the sibling repos — reconcile them before releasing"
ok "Shared files in sync"

# ── Version bump & docs update ────────────────────────────────────────────────
step "Bumping version to $VERSION"
CURRENT=$(grep MARKETING_VERSION "$PROJECT/project.pbxproj" | head -1 | grep -o '[0-9][0-9.]*')
if [[ "$CURRENT" == "$VERSION" ]]; then
    ok "Already at $VERSION"
else
    # Escape dots (and other regex metacharacters) so pre-release versions like
    # "1.7.0-rc.1" don't cause sed pattern mismatches.
    ESC_CURRENT=$(printf '%s' "$CURRENT" | sed 's/[.[\*^$]/\\&/g')
    ESC_VERSION=$(printf '%s'  "$VERSION" | sed 's/[.[\*^$]/\\&/g')
    sed -i '' "s/MARKETING_VERSION = ${ESC_CURRENT};/MARKETING_VERSION = ${ESC_VERSION};/g" \
        "$PROJECT/project.pbxproj"
    ok "Bumped $CURRENT → $VERSION"
fi

# Always update docs — runs even if version was pre-bumped
sed -i '' "s|FilmStrip-v[0-9][0-9.]*\.dmg|FilmStrip-${TAG}.dmg|g" "$DOCS" "$DOCS_THEORY" "$MANUAL_IDX" README.md
sed -i '' "s|Download v[0-9][0-9.]*|Download ${TAG}|g" "$DOCS" "$MANUAL_IDX"
sed -i '' "s|Manual — v[0-9][0-9.]*|Manual — ${TAG}|g" "$MANUAL_IDX"
sed -i '' "s|\[Download v[0-9][0-9.]* (DMG)\].*FilmStrip-v[0-9][0-9.]*.dmg)|\[Download ${TAG} (DMG)\](https://github.com/sevmorris/FilmStrip/releases/latest/download/FilmStrip-${TAG}.dmg)|g" README.md
sed -i '' "s|\*\*Version:\*\* [0-9][0-9.]*|**Version:** ${VERSION}|g" README.md
sed -i '' "s|<strong>Version:</strong> [0-9][0-9.]*|<strong>Version:</strong> ${VERSION}|g" README.md

# Sanity-check: nothing should still reference the old version.
if grep -E "FilmStrip-v[0-9]+\.[0-9]+\.[0-9]+\.dmg" "$DOCS" "$DOCS_THEORY" "$MANUAL_IDX" README.md \
        | grep -v "${TAG}\.dmg" >/dev/null; then
    fail "Stale version references remain after rewrite — check sed patterns"
fi

if [[ -n "$(git status --porcelain)" ]]; then
    git add "$PROJECT/project.pbxproj" "$DOCS" "$DOCS_THEORY" "$MANUAL_IDX" README.md
    git commit -m "Bump version to $VERSION"
    ok "Committed version bump"
else
    ok "All files already up to date"
fi

# ── Fetch FFmpeg ──────────────────────────────────────────────────────────────
# Before xcodebuild, not only as its build phase. The binaries are gitignored and
# the app folder is a synchronized group, so Xcode decides what to bundle when it
# plans the build — before the phase that would download them. On a machine where
# they are already present that ordering is invisible; on a fresh clone it would
# ship an app with no ffmpeg inside. Fetching here means the files exist before
# planning starts. Same reason the sibling repos do it.
step "Fetching FFmpeg binaries"
chmod +x "$PROJECT_DIR/scripts/fetch-ffmpeg.sh"
"$PROJECT_DIR/scripts/fetch-ffmpeg.sh"
ok "FFmpeg present"

# ── Build ─────────────────────────────────────────────────────────────────────
step "Building (clean, Release)"
rm -rf "$DERIVED_DATA"
rm -rf ~/Library/Caches/com.apple.dt.Xcode* 2>/dev/null || true
rm -rf ~/Library/Developer/Xcode/DerivedData/ModuleCache* 2>/dev/null || true
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    -quiet
[[ -d "$APP_PATH" ]] || fail "Build did not produce $APP_PATH"
ok "Build complete"

# ── Sign ──────────────────────────────────────────────────────────────────────
step "Codesigning binaries and app"
IDENTITY="Developer ID Application: Seven Morris (T9RLNAXPWU)"
ENTITLEMENTS="$PROJECT_DIR/FilmStrip/FilmStrip.entitlements"

# Sign bundled binaries with Hardened Runtime
codesign --force --options runtime --sign "$IDENTITY" "$APP_PATH/Contents/Resources/ffmpeg"
codesign --force --options runtime --sign "$IDENTITY" "$APP_PATH/Contents/Resources/ffprobe"

# Sign the app bundle
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1 | tail -3
ok "Codesigning complete"

# ── Verify app version ────────────────────────────────────────────────────────
step "Verifying built app version"
BUILT_VERSION=$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString)
[[ "$BUILT_VERSION" == "$VERSION" ]] || \
    fail "App version mismatch: expected $VERSION, got $BUILT_VERSION"
ok "App reports $BUILT_VERSION"

# ── Create DMG ────────────────────────────────────────────────────────────────
# Built with dmgbuild rather than bare hdiutil so the installer window is laid
# out: background art with an arrow, the app and the Applications alias pinned
# to its endpoints, chrome hidden. dmgbuild writes the .DS_Store directly, so
# this needs no Finder, no GUI session and no automation permission — styling a
# mounted image with AppleScript would make releases fail for environment
# reasons rather than code ones.
#
# No staging directory: dmgbuild places the app and creates the Applications
# symlink itself, from tools/dmg/dmg-settings.py.
#
# Two PATH subtleties, both load-bearing:
#   * python3 is resolved BEFORE the PATH override, so we keep the interpreter
#     that actually has dmgbuild installed rather than Xcode's bundled one.
#   * /bin is prepended for the child, because dmgbuild shells out to bare
#     `sync` and a personal ~/bin/sync would otherwise shadow the system one
#     and abort the build.
step "Creating DMG"
rm -f "$DMG"
DMG_BACKGROUND="$PROJECT_DIR/tools/dmg/dmg-background-filmstrip.png"
[[ -f "$DMG_BACKGROUND" ]] \
    || fail "Missing DMG background: ${DMG_BACKGROUND#$PROJECT_DIR/} — regenerate with tools/dmg/make-background.py"
PY_BIN=$(command -v python3)
PATH="/bin:/usr/bin:$PATH" "$PY_BIN" -m dmgbuild \
    -s "$PROJECT_DIR/tools/dmg/dmg-settings.py" \
    -D app="$APP_PATH" \
    -D background="$DMG_BACKGROUND" \
    "Install FilmStrip" \
    "$DMG" >/dev/null
[[ -f "$DMG" ]] || fail "dmgbuild did not produce $DMG"
ok "Created $(du -sh $DMG | cut -f1) styled DMG"

# ── Notarize ──────────────────────────────────────────────────────────────────
step "Notarizing DMG"
# Reusing 'WoWoNotary' profile from WaxOnWaxOff
xcrun notarytool submit "$DMG" --wait --keychain-profile "WoWoNotary"
xcrun stapler staple "$DMG"
ok "Notarization complete"

# ── Verify DMG ────────────────────────────────────────────────────────────────
step "Verifying DMG contents"
rm -rf "$MOUNT"
mkdir "$MOUNT"
hdiutil attach "$DMG" -mountpoint "$MOUNT" -quiet -nobrowse
DMG_VERSION=$(defaults read "$MOUNT/FilmStrip.app/Contents/Info.plist" CFBundleShortVersionString)
hdiutil detach "$MOUNT" -quiet
[[ "$DMG_VERSION" == "$VERSION" ]] || \
    fail "DMG version mismatch: expected $VERSION, got $DMG_VERSION"
ok "DMG contains $DMG_VERSION"

# ── Tag and push ──────────────────────────────────────────────────────────────
step "Tagging and pushing"
git tag "$TAG"
# Resolve the tracked remote/branch so this works from any branch (e.g. a
# worktree branch whose name differs from its upstream). Fall back to
# `origin` + current branch when no upstream is configured; `-u` sets it
# on first push so subsequent runs resolve cleanly.
if UPSTREAM=$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null); then
    REMOTE="${UPSTREAM%%/*}"
    BRANCH="${UPSTREAM#*/}"
else
    REMOTE="origin"
    BRANCH=$(git branch --show-current)
fi
git push -u "$REMOTE" "HEAD:$BRANCH"
git push "$REMOTE" "$TAG"
ok "Pushed $TAG to $REMOTE/$BRANCH"

# ── GitHub release ────────────────────────────────────────────────────────────
step "Creating GitHub release"
PREV_TAG=$(git tag --sort=-creatordate | grep -v "^${TAG}$" | head -1 || true)
if [[ -n "$PREV_TAG" ]]; then
    CHANGES=$(git log "${PREV_TAG}..HEAD" --pretty=format:"- %s" \
        | grep -v "^- Bump version" \
        | grep -v "^- docs:" || true)
else
    CHANGES=$(git log --pretty=format:"- %s" \
        | grep -v "^- Bump version" \
        | grep -v "^- docs:" || true)
fi
[[ -n "$CHANGES" ]] || CHANGES="- Initial release"
RELEASE_NOTES="**[App Page](https://sevmorris.github.io/FilmStrip/)**

### Changes
${CHANGES}"
gh release create "$TAG" "$DMG" \
    --repo "$REPO" \
    --title "FilmStrip $TAG" \
    --notes "$RELEASE_NOTES"
ok "Release published"

# ── Remove old releases (keep the ${KEEP_RELEASES} most recent) ───────────────
KEEP_RELEASES=5
step "Removing old releases (keeping ${KEEP_RELEASES} most recent)"
OLD_TAGS=$(gh release list --repo "$REPO" --limit 100 --json tagName \
    --jq '.[].tagName' | tail -n +$((KEEP_RELEASES + 1)) || true)
if [[ -z "$OLD_TAGS" ]]; then
    ok "No old releases to remove"
else
    while IFS= read -r old_tag; do
        gh release delete "$old_tag" --repo "$REPO" --yes --cleanup-tag 2>/dev/null || true
        git tag -d "$old_tag" 2>/dev/null || true
        ok "Removed $old_tag"
    done <<< "$OLD_TAGS"
fi

# ── Remove old Pages deployments ─────────────────────────────────────────────
step "Removing old Pages deployments"
ALL_DEPLOY_IDS=$(gh api "repos/$REPO/deployments?environment=github-pages&per_page=100" \
    --jq '.[].id' 2>/dev/null || true)
OLD_DEPLOY_IDS=$(echo "$ALL_DEPLOY_IDS" | tail -n +2)
if [[ -z "$OLD_DEPLOY_IDS" ]]; then
    ok "No old deployments to remove"
else
    COUNT=0
    while IFS= read -r deploy_id; do
        gh api -X POST "repos/$REPO/deployments/${deploy_id}/statuses" \
            -f state=inactive --silent 2>/dev/null || true
        gh api -X DELETE "repos/$REPO/deployments/${deploy_id}" --silent 2>/dev/null || true
        COUNT=$((COUNT + 1))
    done <<< "$OLD_DEPLOY_IDS"
    ok "Removed $COUNT old deployment(s)"
fi

# ── Clean up temp files ───────────────────────────────────────────────────────
step "Cleaning up"
rm -rf "$MOUNT" "$DERIVED_DATA"
rm -f "$DMG"
ok "Temp files removed"

# ── Open release page ─────────────────────────────────────────────────────────
RELEASE_URL="https://github.com/${REPO}/releases/tag/${TAG}"
echo "\n✓ FilmStrip $TAG released successfully."
echo "  $RELEASE_URL"
open "$RELEASE_URL"
