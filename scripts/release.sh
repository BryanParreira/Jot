#!/usr/bin/env bash
# Usage: ./scripts/release.sh 1.0.1 "What changed"
# Bumps version, builds, zips, creates GitHub release.

set -euo pipefail

VERSION="${1:?Usage: $0 <version> [release-notes]}"
NOTES="${2:-}"
TAG="v$VERSION"

PLIST="Jot/Info.plist"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE="$BUILD_DIR/Jot.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
ZIP="$BUILD_DIR/Jot-$VERSION.zip"

cd "$PROJECT_DIR"

# ── 1. Bump version in Info.plist ───────────────────────────────────────────
echo "→ Setting version to $VERSION"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$PLIST"

# ── 2. Commit version bump ───────────────────────────────────────────────────
git add "$PLIST"
git commit -m "chore: bump version to $VERSION"

# ── 3. Archive ───────────────────────────────────────────────────────────────
echo "→ Archiving…"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

xcodebuild \
  -project Jot.xcodeproj \
  -scheme Jot \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  archive \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  | grep -E "error:|warning:|Touching|Build succeeded|Build FAILED" \
  || true

if [ ! -d "$ARCHIVE" ]; then
  echo "✗ Archive failed"; exit 1
fi

# ── 4. Export .app ───────────────────────────────────────────────────────────
echo "→ Exporting .app…"
mkdir -p "$EXPORT_DIR"
cp -R "$ARCHIVE/Products/Applications/Jot.app" "$EXPORT_DIR/Jot.app"

# ── 5. Zip ───────────────────────────────────────────────────────────────────
echo "→ Zipping…"
cd "$EXPORT_DIR"
zip -r --symlinks "$ZIP" Jot.app
cd "$PROJECT_DIR"

echo "→ Built: $ZIP ($(du -sh "$ZIP" | cut -f1))"

# ── 6. Tag + push ────────────────────────────────────────────────────────────
echo "→ Tagging $TAG and pushing…"
git tag "$TAG"
git push origin HEAD
git push origin "$TAG"

# ── 7. Create GitHub Release ─────────────────────────────────────────────────
echo "→ Creating GitHub release $TAG…"

if [ -z "$NOTES" ]; then
  gh release create "$TAG" "$ZIP" \
    --title "Jot $VERSION" \
    --generate-notes
else
  gh release create "$TAG" "$ZIP" \
    --title "Jot $VERSION" \
    --notes "$NOTES"
fi

echo ""
echo "✓ Released Jot $VERSION"
echo "  https://github.com/BryanParreira/Jot/releases/tag/$TAG"
