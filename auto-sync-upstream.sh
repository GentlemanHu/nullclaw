#!/bin/bash
# Auto-sync with upstream while preserving local Android build configuration
# This script performs a safe merge from upstream, keeping local build configurations

set -e

echo "🔄 Starting upstream synchronization..."

# Ensure we're on main branch
current_branch=$(git rev-parse --abbrev-ref HEAD)
if [ "$current_branch" != "main" ]; then
    echo "❌ Error: Must be on 'main' branch, currently on '$current_branch'"
    exit 1
fi

# Fetch latest from both origin and upstream
echo "📥 Fetching from origin and upstream..."
git fetch origin
git fetch upstream

# Check if there are uncommitted changes
if ! git diff-index --quiet HEAD --; then
    echo "❌ Error: Uncommitted changes found. Please commit or stash your changes first."
    exit 1
fi

# Show status before merge
echo ""
echo "📊 Status before merge:"
echo "  Local:    $(git rev-parse --short HEAD)"
echo "  Upstream: $(git rev-parse --short upstream/main)"
echo ""

# Perform merge with local strategy for conflicts
echo "🔀 Merging upstream/main..."
if git merge -X ours upstream/main -m "chore(sync): merge upstream changes while preserving local Android build config"; then
    echo "✅ Merge successful"
else
    echo "⚠️  Merge had conflicts - resolving with local strategy"
fi

# Critical: Remove upstream's problematic Android build checking functions
# (These conflict with local musl-based Android cross-compilation approach)
if grep -q "ensureAndroidBuildEnvironment" build.zig; then
    echo "🔧 Removing upstream Android build environment checks..."
    # Remove the envExists and ensureAndroidBuildEnvironment functions
    sed -i '/^fn envExists/,/^}/d' build.zig
    sed -i '/^fn ensureAndroidBuildEnvironment/,/^}/d' build.zig
    # Remove the Android check call
    sed -i '/if (target.result.abi == .android) {/,/^    }/d' build.zig
    git add build.zig
    git commit -m "fix(build): remove conflicting upstream Android checks" || true
fi

echo ""
echo "✨ Sync complete!"
echo ""
echo "📋 Next steps:"
echo "  1. Review changes: git log --oneline origin/main..HEAD"
echo "  2. Test build: zig build test --summary all (if you have zig installed locally)"
echo "  3. Push to origin: git push origin main"
echo ""
echo "💡 To push changes to your fork:"
echo "  git push origin main"
