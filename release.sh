#!/usr/bin/env zsh
# release.sh — Build, verify, package, and publish a FilmStrip release.
#
# Usage: ./release.sh <version> [--generated-notes] [--skip-tests]
#   e.g. ./release.sh 1.0.0
#
# Requires: xcodebuild, hdiutil, gh (GitHub CLI), git

set -euo pipefail

REPO="sevmorris/FilmStrip"

# notarytool keychain profile, shared by every sibling release script. A profile
# cannot be exported, so a new Mac needs it created again under this name:
#   xcrun notarytool store-credentials notarytool --apple-id <email> --team-id T9RLNAXPWU
# Set NOTARY_PROFILE to use another (a Mac still holding the old WoWoNotary one).
NOTARY_PROFILE="${NOTARY_PROFILE:-notarytool}"

# ── Args ──────────────────────────────────────────────────────────────────────
# One positional argument (the version) plus optional flags in any position.
# Anything else — including no arguments, or a second positional that isn't a
# flag — still fails with usage, as it did before the flags existed.
ALLOW_GENERATED_NOTES=0
SKIP_TESTS=0
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --generated-notes) ALLOW_GENERATED_NOTES=1 ;;
        --skip-tests)      SKIP_TESTS=1 ;;
        *)                 ARGS+=("$arg") ;;
    esac
done

if [[ ${#ARGS[@]} -ne 1 ]]; then
    echo "Usage: $0 <version> [--generated-notes] [--skip-tests]"
    echo "  e.g. $0 1.0.0"
    echo ""
    echo "  --generated-notes  Release without a curated release-notes file,"
    echo "                     generating notes from commit subjects instead."
    echo "  --skip-tests       Skip the test suite (not recommended; use only when"
    echo "                     tests are known-broken and you need an emergency release)."
    exit 1
fi

VERSION="${ARGS[1]}"
TAG="v${VERSION}"
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="$SCRIPT_DIR"
PROJECT="$PROJECT_DIR/FilmStrip.xcodeproj"
SCHEME="FilmStrip"
DERIVED_DATA="/tmp/filmstrip_build_${VERSION}"
APP_PATH="$DERIVED_DATA/Build/Products/Release/FilmStrip.app"
DMG="/tmp/FilmStrip-${TAG}.dmg"
APP_ZIP="/tmp/FilmStrip-${TAG}-app.zip"
MOUNT="/tmp/filmstrip_verify_${VERSION}"
DOCS="$PROJECT_DIR/docs/index.html"
DOCS_THEORY="$PROJECT_DIR/docs/theory.html"
MANUAL_IDX="$PROJECT_DIR/docs/manual/index.html"
NOTES_FILE="$PROJECT_DIR/release-notes/${TAG}.md"
TEST_LOG="/tmp/filmstrip_test_${VERSION}.log"

# ── Helpers ───────────────────────────────────────────────────────────────────
step()  { echo "\n▶ $*"; }
ok()    { echo "  ✓ $*"; }
fail()  { echo "\n  ✗ $*" >&2; exit 1; }
warn()  { echo "  ! $*" >&2; }

# Temp files only: the version bump here is committed before the build, so a
# failure leaves nothing uncommitted to revert. ${VAR:-} keeps `set -u` quiet on
# an early exit. A failure between attach and detach would leave the image
# mounted, so detach before removing the mount point.
cleanup() {
    if [[ -d "${MOUNT:-}" ]]; then
        hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
        rm -rf -- "$MOUNT" || true
    fi
    [[ -d "${DERIVED_DATA:-}" ]] && rm -rf -- "$DERIVED_DATA" || true
    [[ -f "${DMG:-}" ]]          && rm -f  -- "$DMG"          || true
    [[ -f "${APP_ZIP:-}" ]]      && rm -f  -- "$APP_ZIP"      || true
    [[ -f "${TEST_LOG:-}" ]]     && rm -f  -- "$TEST_LOG"     || true
}
# A zsh EXIT trap does not fire on a signal, so Ctrl-C or a closed terminal
# during the long notarization wait used to leave the version bump sitting in
# the working tree — the same stranded-bump state that blocked two releases on
# 2026-09-16, which the deferred commit only fixed for an ordinary failure.
# These handlers exit and let the EXIT trap do the cleanup, exactly once.
trap 'exit 130' INT
trap 'exit 143' TERM
trap cleanup EXIT

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
# Importing dmgbuild does not prove it can run. On 2026-09-16 a pyenv Python
# built against Xcode 27's macOS 27 SDK, on macOS 26.7, imported it and then
# segfaulted on its first subprocess — dmgbuild's hdiutil call — and every DMG
# that day went out without its installer window.
python3 -c "import subprocess; subprocess.run(['/usr/bin/true'], check=True)" &>/dev/null \
    || fail "$(command -v python3) cannot start a subprocess, so dmgbuild would crash — rebuild that Python against an SDK no newer than this macOS"
ok "Tools present"

# True when this user's console session is locked. Reads IOKit's console-user
# records for our uid rather than taking the first: with more than one user
# logged in, the first record need not be ours.
screen_locked() {
    local plist i uid
    plist=$(ioreg -n Root -d1 -a 2>/dev/null) || return 1
    for i in 0 1 2 3 4 5 6 7; do
        uid=$(plutil -extract "IOConsoleUsers.$i.kCGSSessionUserIDKey" raw -o - - <<<"$plist" 2>/dev/null) || return 1
        [[ "$uid" == "$(id -u)" ]] || continue
        [[ "$(plutil -extract "IOConsoleUsers.$i.CGSSessionScreenIsLocked" raw -o - - <<<"$plist" 2>/dev/null)" == true ]]
        return
    done
    return 1
}

# A missing profile used to surface at the notarization step, after a clean
# build — which is how a new Mac found out. Asking costs one API call.
# A locked screen reads as a missing profile: notarytool keeps its credentials
# in the data-protection keychain, which locks with the screen. On 2026-09-24 a
# release stopped here at 4 a.m. and was sent looking for a profile that was
# there all along. Asked only once the check has failed, so it can never stop a
# release that would otherwise go ahead.
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" &>/dev/null; then
    screen_locked && fail "The screen is locked, so notarytool cannot read its keychain profile '$NOTARY_PROFILE' — unlock the Mac and re-run"
    fail "notarytool profile '$NOTARY_PROFILE' is missing, rejected or unreachable — create it with: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <email> --team-id T9RLNAXPWU"
fi
ok "notarytool profile '$NOTARY_PROFILE' works"

cd "$PROJECT_DIR"

if [[ -n "$(git status --porcelain)" ]]; then
    fail "Working tree is dirty — commit or stash changes before releasing"
fi
ok "Working tree clean"

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

# The remote's tags are the record, not this clone's. A clone that has not seen
# a release — made on another Mac, or one whose tag push failed — passes a
# local-only check, then builds, notarizes and pushes the branch before the tag
# is refused, as re-runs of ClipHack and WaxOnWaxOff did on 2026-09-16. Fetching
# first lets the checks below see every published tag, and a local tag that
# disagrees with the remote makes the fetch itself fail.
git fetch --tags "$REMOTE" \
    || fail "Could not fetch tags from $REMOTE — a tag reported as rejected above points at different commits here and on $REMOTE"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    fail "Tag $TAG already exists — has this version been released?"
fi
ok "Tag $TAG is available"

# The push at the end is a fast-forward or nothing, so a remote branch with
# commits this one lacks would fail it after the notarization. Stop now instead.
if git rev-parse -q --verify "refs/remotes/$REMOTE/$BRANCH" >/dev/null \
        && ! git merge-base --is-ancestor "$REMOTE/$BRANCH" HEAD; then
    fail "$REMOTE/$BRANCH has commits that HEAD lacks — pull before releasing"
fi
ok "HEAD contains everything on $REMOTE/$BRANCH"

# ── Version ordering ────────────────────────────────────────────────────────────────────────
# Nothing here stopped a release going backwards. On 2026-09-03 Magic Backup
# Machine published v1.3.9 on top of v1.4.2 — two sessions releasing from one
# clone, neither aware of the other. GitHub served the older build as "latest"
# from that moment, and because the update checker compares numerically, every
# client already on 1.4.2 read 1.3.9 as older and reported itself up to date.
# The release could not reach anyone.
#
# Tags are the record of what is actually published, and what "latest" keys on,
# so they are what this compares against. Set ALLOW_DOWNGRADE=1 to override.
step "Checking version ordering"
version_core() { printf '%s' "${1%%[-+]*}"; }
HIGHEST_TAG=$(git tag --list 'v[0-9]*' --sort=-v:refname | head -1 | sed 's/^v//')
if [[ -n "$HIGHEST_TAG" ]]; then
    NEW_CORE=$(version_core "$VERSION")
    REF_CORE=$(version_core "$HIGHEST_TAG")
    # Numeric cores only: `sort -V` places 1.7.0 ahead of 1.7.0-rc.1, backwards
    # from semver, and comparing raw strings would block any release that
    # follows its own release candidate.
    if [[ "$NEW_CORE" != "$REF_CORE" ]] \
       && [[ "$(printf '%s\n%s\n' "$NEW_CORE" "$REF_CORE" | sort -V | head -1)" == "$NEW_CORE" ]]; then
        if [[ "${ALLOW_DOWNGRADE:-0}" != "0" ]]; then
            warn "$VERSION sorts below tag v$HIGHEST_TAG — continuing, ALLOW_DOWNGRADE is set"
        else
            fail "$VERSION sorts below the highest tag v$HIGHEST_TAG. Publishing it would leave GitHub serving an older build as 'latest', and clients on $HIGHEST_TAG would be told they are up to date. Set ALLOW_DOWNGRADE=1 to override."
        fi
    fi
fi
ok "Version $VERSION does not go backwards"


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

# ── Release-notes gate ────────────────────────────────────────────────────────
# The notes are read much later, at the GitHub-release step — by which point the
# branch and the tag have both been pushed. Failing there would strand a pushed
# tag with no release behind it, so the absence has to be caught here, while
# nothing has been mutated and nothing has left the machine.
#
# Without this, a forgotten notes file is invisible: the curated path announces
# itself, the generated path says nothing, and both end on the same "Release
# published" line. Shipping auto-generated notes becomes a silent default rather
# than a decision.
if [[ -f "$NOTES_FILE" ]]; then
    ok "Curated notes present: release-notes/${TAG}.md"
elif (( ALLOW_GENERATED_NOTES )); then
    echo "\n  ⚠ --generated-notes — publishing $TAG without curated notes" >&2
    echo "      expected:  release-notes/${TAG}.md" >&2
    echo "      notes will be generated from commit subjects since the last tag" >&2
    ok "Generated notes accepted"
else
    echo "      expected:  release-notes/${TAG}.md" >&2
    fail "No curated notes for $TAG — write that file, or re-run with --generated-notes"
fi

# ── Tests ─────────────────────────────────────────────────────────────────────
# Until 2026-09-23 nothing ran FilmStripTests: the target existed and passed, but
# there was no CI and no step here, so a release could ship with them failing.
# CI runs them on every push now; this is the check on what is actually being
# released, from this clone. Magic Backup Machine's step, with its escape hatch.
#
# Before the version bump, like every gate above: a failure here leaves nothing
# committed and nothing to undo.
step "Running unit tests"
if (( SKIP_TESTS )); then
    warn "Skipping tests (--skip-tests)"
else
    if ! xcodebuild test \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -destination 'platform=macOS,arch=arm64' \
        -quiet > "$TEST_LOG" 2>&1; then
        cat "$TEST_LOG" >&2
        fail "Tests failed — fix before releasing, or pass --skip-tests for an emergency release"
    fi
    ok "Tests passed"
fi

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
# Before xcodebuild, not only as its build phase. Until 2026-09-24 this was all
# that kept a fresh clone's release from shipping with no ffmpeg inside: the
# binaries reached Copy Bundle Resources only through the synchronized FilmStrip
# folder, which Xcode reads when it loads the project — before the phase that
# downloads them. The project now names them in the Resources phase, so even a
# first build copies them. Fetching here stays as the second guard: a lost
# reference still cannot ship an app without them, and a failed download or
# checksum stops the release before the clean build starts.
step "Fetching FFmpeg binaries"
chmod +x "$PROJECT_DIR/scripts/fetch-ffmpeg.sh"
"$PROJECT_DIR/scripts/fetch-ffmpeg.sh"
ok "FFmpeg present"

# ── Build ─────────────────────────────────────────────────────────────────────
step "Building (clean, Release)"
rm -rf "$DERIVED_DATA"
# (N): a glob that matches nothing expands to nothing. Without it zsh reports
# "no matches found" — on a new Mac, where neither cache exists yet.
rm -rf ~/Library/Caches/com.apple.dt.Xcode*(N) 2>/dev/null || true
rm -rf ~/Library/Developer/Xcode/DerivedData/ModuleCache*(N) 2>/dev/null || true
# -destination 'generic/platform=macOS' ("Any Mac"): without it xcodebuild picks
# the first matching run destination, warns about it on every release, and builds
# for that destination's arch alone. With it, ARCHS decides — arm64, the only
# arch the bundled FFmpeg has.
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    -destination 'generic/platform=macOS' \
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

# ── Notarize app ──────────────────────────────────────────────────────────────
step "Notarizing app"
# Stapling the DMG alone leaves the app unstapled once it is dragged out, which
# is the only form anyone actually runs. Gatekeeper still passes it — it falls
# back to asking Apple — but that needs a working network on first launch. So
# the app gets its own notarization round trip and its own ticket here, before
# the DMG is built around it; the DMG is then stapled separately below.
#
# The ticket covers this exact cdhash, so this has to run after codesigning and
# before the app is copied into the DMG.
rm -f "$APP_ZIP"
ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"
xcrun notarytool submit "$APP_ZIP" --wait --keychain-profile "$NOTARY_PROFILE" \
    || fail "App notarization failed"
xcrun stapler staple "$APP_PATH" || fail "Stapling the app failed"
xcrun stapler validate "$APP_PATH" >/dev/null || fail "App has no valid stapled ticket"
rm -f "$APP_ZIP"
ok "App notarized and stapled"

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
#
# There is no fallback to bare hdiutil, deliberately. One was added on
# 2026-09-16 for what looked like dmgbuild crashing on a new Mac; the crash was
# the Python interpreter (see preflight), and the fallback shipped that day's
# DMGs without their installer window while still reporting a styled one.
# A DMG without its window is a failed release, not a degraded one.
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
    "$DMG" >/dev/null \
    || fail "dmgbuild failed (exit $?) — no DMG was built"
[[ -f "$DMG" ]] || fail "dmgbuild did not produce $DMG"
ok "Created $(du -sh $DMG | cut -f1) styled DMG"

# ── Notarize ──────────────────────────────────────────────────────────────────
step "Notarizing DMG"
# NOTARY_PROFILE is defined at the top and proven usable in preflight.

# The image itself is signed, not only the app inside it. An unsigned DMG
# reports "no usable signature" to spctl even with a valid ticket stapled, so
# the wrapper can never be assessed — a download that looks unsigned to
# Gatekeeper while the app within it is perfectly notarized. Signing has to
# precede submission; stapling afterwards leaves the signature intact.
codesign --force --timestamp --sign "$IDENTITY" "$DMG" \
    || fail "Signing the DMG failed"

xcrun notarytool submit "$DMG" --wait --keychain-profile "$NOTARY_PROFILE"
xcrun stapler staple "$DMG"
ok "Notarization complete"

# ── Verify DMG ────────────────────────────────────────────────────────────────
step "Verifying DMG contents"
rm -rf "$MOUNT"
mkdir "$MOUNT"
hdiutil attach "$DMG" -mountpoint "$MOUNT" -quiet -nobrowse
DMG_VERSION=$(defaults read "$MOUNT/FilmStrip.app/Contents/Info.plist" CFBundleShortVersionString)
# Check the ticket on the copy that actually ships, not on the build product
# we stapled — those are the two that can drift apart. Captured before the
# detach so the volume is never left mounted on a failure.
if xcrun stapler validate "$MOUNT/FilmStrip.app" >/dev/null 2>&1; then
    DMG_APP_STAPLED=1
else
    DMG_APP_STAPLED=0
fi
# The installer window is these two files: the .DS_Store carrying the layout and
# the background art it points at. Without them the image opens as a plain folder.
DMG_DSSTORE=( "$MOUNT"/.DS_Store(N) )
DMG_BGART=( "$MOUNT"/.background.*(N) )
hdiutil detach "$MOUNT" -quiet
[[ "$DMG_APP_STAPLED" == 1 ]] || \
    fail "App inside the DMG carries no notarization ticket"
[[ "$DMG_VERSION" == "$VERSION" ]] || \
    fail "DMG version mismatch: expected $VERSION, got $DMG_VERSION"
(( ${#DMG_DSSTORE} && ${#DMG_BGART} )) || \
    fail "DMG has no installer window layout (.DS_Store and .background.* are not both present)"
ok "DMG contains $DMG_VERSION, with its installer window layout"

# ── Tag and push ──────────────────────────────────────────────────────────────
step "Tagging and pushing"
git tag "$TAG"
# REMOTE and BRANCH were resolved in preflight. One atomic push: the branch and
# the tag land together or not at all. As two pushes, a refused tag left the
# release commit on the branch with nothing tagging it. On failure nothing has
# been published, so the tag made just above is removed and a re-run starts clean.
if ! git push --atomic -u "$REMOTE" "HEAD:refs/heads/$BRANCH" "refs/tags/$TAG"; then
    git tag -d "$TAG" >/dev/null
    fail "Push to $REMOTE failed and nothing was published — the local $TAG tag has been removed"
fi
ok "Pushed $TAG to $REMOTE/$BRANCH"

# ── GitHub release ────────────────────────────────────────────────────────────
step "Creating GitHub release"
# A curated description at release-notes/v<version>.md wins over the generated
# commit list. Use it when the release needs prose the log can't produce —
# licensing notes, a known-gap disclosure, an explanation of what changed and
# what deliberately didn't. Without one, fall back to subjects since the last tag.
#
# NOTES_FILE is defined with the other paths and its absence is gated in
# preflight, so reaching the generated branch here means --generated-notes was
# passed deliberately.
if [[ -f "$NOTES_FILE" ]]; then
    ok "Using curated notes: release-notes/${TAG}.md"
    gh release create "$TAG" "$DMG" \
        --repo "$REPO" \
        --title "FilmStrip $TAG" \
        --notes-file "$NOTES_FILE"
else
    # App tags only: the ffmpeg-deps-* tags are cut at main's head whenever a
    # deps build is published, and one newer than the last release would
    # silently shorten these notes.
    PREV_TAG=$(git tag --list 'v[0-9]*' --sort=-creatordate | grep -v "^${TAG}$" | head -1 || true)
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
fi
ok "Release published"

# ── Remove old releases (keep the ${KEEP_RELEASES} most recent) ───────────────
KEEP_RELEASES=5
step "Removing old releases (keeping ${KEEP_RELEASES} most recent)"
# The `^v[0-9]` filter is what actually keeps ffmpeg-deps-* out of this loop:
# the deps tag begins with "f", so it never reaches the delete. The case below is
# a backstop in case that filter is ever loosened. Fresh clones download the
# bundled binaries from that release (see scripts/fetch-ffmpeg.sh) and it has no
# other source, so pruning it by date would make the repo unbuildable from a
# clean checkout — which is exactly what happened to WaxOnWaxOff during its
# v2.0.6 cut, and to ClipHack downstream of it.
OLD_TAGS=$(gh release list --repo "$REPO" --limit 100 --json tagName \
    --jq '.[].tagName' | grep -E '^v[0-9]' | tail -n +$((KEEP_RELEASES + 1)) || true)
if [[ -z "$OLD_TAGS" ]]; then
    ok "No old releases to remove"
else
    while IFS= read -r old_tag; do
        case "$old_tag" in
            ffmpeg-deps-*)
                ok "Skipped protected deps release $old_tag"
                continue
                ;;
        esac
        # No --cleanup-tag, and no `git tag -d`: the point is to keep the
        # Releases page short, not to destroy version history. A deleted tag
        # cannot be checked out, so an old version becomes unbuildable.
        gh release delete "$old_tag" --repo "$REPO" --yes 2>/dev/null || true
        ok "Pruned release page for $old_tag (tag kept)"
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
