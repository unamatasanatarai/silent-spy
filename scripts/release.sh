#!/usr/bin/env bash
set -euo pipefail

DRY_RUN=false
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=true
fi

APP_NAME="SilentSpy"
VERSION="1.0.0"
if [ -f "VERSION" ]; then
    VERSION=$(tr -d ' \n\r' <VERSION)
fi

TAG="v${VERSION}"
DMG_FILE="build/${APP_NAME}.dmg"

echo "=========================================="
echo "🚀 Preparing Release for ${APP_NAME} (${TAG})"
if [ "${DRY_RUN}" = true ]; then
    echo "   [MODE: DRY-RUN - No remote changes will be made]"
fi
echo "=========================================="

# 1. Check gh CLI availability
if ! command -v gh >/dev/null 2>&1; then
    echo "❌ Error: GitHub CLI ('gh') is not installed. Please install it with 'brew install gh'."
    exit 1
fi

# 2. Check Git clean status
UNCOMMITTED=$(git status --porcelain -unormal | grep -v 'build/' || true)
if [ -n "${UNCOMMITTED}" ]; then
    echo "⚠️  Warning: You have uncommitted changes in working directory:"
    echo "${UNCOMMITTED}"
    if [ "${DRY_RUN}" = false ]; then
        echo "❌ Please commit or stash your changes before releasing."
        exit 1
    fi
fi

# 3. Build DMG package if not already built or stale
echo "📦 Step 1: Building distribution DMG..."
if [ "${DRY_RUN}" = true ]; then
    echo "==> Running 'make dmg' to verify build artifacts..."
    make dmg
else
    make dmg
fi

if [ ! -f "${DMG_FILE}" ]; then
    echo "❌ Error: Build artifact ${DMG_FILE} was not found."
    exit 1
fi

echo "✅ Distribution asset ready: ${DMG_FILE} ($(du -h "${DMG_FILE}" | cut -f1))"

# 4. Handle Tagging & GitHub Release
echo "🏷️  Step 2: Tagging & Publishing Release (${TAG})..."

# Unset invalid GITHUB_TOKEN if present to fall back to gh keyring auth
export GITHUB_TOKEN=""

if [ "${DRY_RUN}" = true ]; then
    echo "------------------------------------------"
    echo "[DRY-RUN] The following actions would be executed:"
    if git rev-parse "refs/tags/${TAG}" >/dev/null 2>&1; then
        echo "  • Local Tag: ${TAG} already exists."
    else
        echo "  • Git Tag: git tag -a ${TAG} -m \"Release ${TAG}\""
    fi
    echo "  • Git Push: git push origin ${TAG}"
    echo "  • GitHub Release: gh release create ${TAG} ${DMG_FILE} --title \"${TAG}\" --generate-notes"
    echo "------------------------------------------"
    echo "✅ Dry run complete! Everything is ready for 'make release'."
    exit 0
fi

# Create tag if it doesn't exist locally
if ! git rev-parse "refs/tags/${TAG}" >/dev/null 2>&1; then
    echo "==> Creating local git tag ${TAG}..."
    git tag -a "${TAG}" -m "Release ${TAG}"
else
    echo "==> Tag ${TAG} already exists locally."
fi

# Push tag to remote
echo "==> Pushing tag ${TAG} to origin..."
git push origin "${TAG}"

# Create or update GitHub release
if gh release view "${TAG}" >/dev/null 2>&1; then
    echo "==> Release ${TAG} already exists on GitHub. Uploading/updating release asset..."
    gh release upload "${TAG}" "${DMG_FILE}" --clobber
else
    echo "==> Creating GitHub release ${TAG}..."
    gh release create "${TAG}" "${DMG_FILE}" --title "${TAG}" --generate-notes
fi

echo "=========================================="
echo "🎉 Successfully published release ${TAG}!"
echo "   URL: https://github.com/unamatasanatarai/silent-spy/releases/tag/${TAG}"
echo "=========================================="
