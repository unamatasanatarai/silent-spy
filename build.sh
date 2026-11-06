#!/usr/bin/env bash
set -euo pipefail

APP_NAME="SilentSpy"
BUNDLE_ID="com.silentspy.app"
VERSION="1.0.0"
if [ -f "VERSION" ]; then
    VERSION=$(tr -d ' \n\r' <VERSION)
fi
MIN_MACOS="12.3"
# Code signing:
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" ./build.sh   -> distributable, hardened runtime
#   (unset)                                                           -> ad-hoc, local use only
# Never override the designated requirement with an identifier-only rule: TCC would then accept ANY
# binary claiming "com.silentspy.app" as SilentSpy and hand it our Microphone/Screen Recording grants.
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
SIGN_MODE="${SIGN_IDENTITY:-adhoc}"
# FORCE=1 ./build.sh  -> always recompile + re-sign (used for DMG/release builds).
FORCE="${FORCE:-0}"
ARCHS=(x86_64 arm64)
SDK_PATH=$(xcrun --show-sdk-path)

APP_DIR="build/${APP_NAME}.app"
BINARY="${APP_DIR}/Contents/MacOS/${APP_NAME}"
# Touched after every successful package + sign: the reference point for "did any bundle input change?"
SIGN_STAMP="build/.sign-mode"

echo "==> Building ${APP_NAME}.app v${VERSION}..."

mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

# Generate AppIcon.icns if needed (before the staleness checks: it is a bundle input)
if [ -f "Resources/leaf-app-icon.png" ]; then
    if [ ! -f "Resources/AppIcon.icns" ] || [ "Resources/leaf-app-icon.png" -nt "Resources/AppIcon.icns" ]; then
        echo "🎨 Generating AppIcon.icns from leaf-app-icon.png..."
        ICON_TMP=$(mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}-icon.XXXXXX")
        ICONSET="${ICON_TMP}/AppIcon.iconset"
        mkdir -p "${ICONSET}"
        for SPEC in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x 128:icon_128x128 \
            256:icon_128x128@2x 256:icon_256x256 512:icon_256x256@2x 512:icon_512x512 1024:icon_512x512@2x; do
            SIZE="${SPEC%%:*}"
            NAME="${SPEC#*:}"
            sips -z "${SIZE}" "${SIZE}" Resources/leaf-app-icon.png --out "${ICONSET}/${NAME}.png" >/dev/null 2>&1
        done
        iconutil -c icns "${ICONSET}" -o Resources/AppIcon.icns
        rm -rf "${ICON_TMP}"
    fi
fi

# --- Staleness checks -------------------------------------------------------------------------
# swiftc embeds non-deterministic UUIDs/timestamps, and macOS TCC ties permission grants to the
# CDHash, so we avoid recompiling / re-signing when nothing changed. But anything that ends up in
# the signed bundle (sources, Info.plist inputs, resources, entitlements) MUST trigger a re-sign:
# modifying a sealed bundle without re-signing breaks its signature.

# A bundle copied/synced without mode bits leaves a non-executable binary, which launchd refuses
# to spawn ("Launchd job spawn failed", POSIX 111). File mode isn't part of the code signature, so
# restoring it keeps the CDHash (and TCC grants) intact.
if [ -f "${BINARY}" ] && [ ! -x "${BINARY}" ]; then
    echo "⚠️  ${BINARY} lost its executable bit — restoring."
    chmod 755 "${BINARY}"
fi

NEEDS_COMPILE=false
if [ "${FORCE}" = "1" ] || [ ! -f "${BINARY}" ]; then
    NEEDS_COMPILE=true
elif [ -n "$(find Sources/SilentSpy -name '*.swift' -newer "${BINARY}" 2>/dev/null | head -n 1)" ] \
    || [ "build.sh" -nt "${BINARY}" ]; then
    NEEDS_COMPILE=true
else
    for ARCH in "${ARCHS[@]}"; do
        if ! lipo "${BINARY}" -verify_arch "${ARCH}" 2>/dev/null; then
            NEEDS_COMPILE=true
        fi
    done
fi

NEEDS_PACKAGE=${NEEDS_COMPILE}
if [ "${NEEDS_PACKAGE}" = false ]; then
    if [ ! -f "${SIGN_STAMP}" ] || [ "$(cat "${SIGN_STAMP}" 2>/dev/null)" != "${SIGN_MODE}" ]; then
        NEEDS_PACKAGE=true
    elif [ -n "$(find Resources VERSION Entitlements.plist build.sh -newer "${SIGN_STAMP}" 2>/dev/null | head -n 1)" ]; then
        NEEDS_PACKAGE=true
    elif ! codesign --verify --strict "${APP_DIR}" 2>/dev/null; then
        echo "⚠️  Existing bundle signature is invalid — re-signing."
        NEEDS_PACKAGE=true
    fi
fi

if [ "${NEEDS_PACKAGE}" = false ]; then
    echo "==> Nothing changed, skipping compile & codesign (preserving TCC permissions)."
    echo "✅ Build successfully completed: ${APP_DIR} (v$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "${APP_DIR}/Contents/Info.plist"))"
    exit 0
fi

# --- Compile ----------------------------------------------------------------------------------
if [ "${NEEDS_COMPILE}" = true ]; then
    echo "==> Compiling Universal 2 binary (x86_64 + arm64)..."
    SWIFT_FILES=()
    while IFS= read -r FILE; do SWIFT_FILES+=("${FILE}"); done < <(find Sources/SilentSpy -name "*.swift" | sort)
    FRAMEWORKS=(
        -framework Foundation
        -framework AppKit
        -framework SwiftUI
        -framework AVFoundation
        -framework AudioToolbox
        -framework ScreenCaptureKit
        -framework CoreMedia
        -framework CoreAudio
        -framework Accelerate
    )

    OBJ_DIR=$(mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}-build.XXXXXX")
    trap 'rm -rf "${OBJ_DIR}"' EXIT
    SLICES=()
    for ARCH in "${ARCHS[@]}"; do
        echo "   -> ${ARCH}"
        swiftc -O -sdk "${SDK_PATH}" -target "${ARCH}-apple-macos${MIN_MACOS}" -parse-as-library \
            "${FRAMEWORKS[@]}" "${SWIFT_FILES[@]}" -o "${OBJ_DIR}/${APP_NAME}_${ARCH}"
        SLICES+=("${OBJ_DIR}/${APP_NAME}_${ARCH}")
    done

    lipo -create "${SLICES[@]}" -output "${BINARY}"
    chmod 755 "${BINARY}"

    for ARCH in "${ARCHS[@]}"; do
        lipo "${BINARY}" -verify_arch "${ARCH}" || { echo "❌ Missing ${ARCH} slice in ${BINARY}"; exit 1; }
    done
    echo "==> Architectures: $(lipo -archs "${BINARY}")"
else
    echo "==> Sources unchanged, reusing compiled binary (bundle inputs changed: re-packaging)."
fi

# --- Package ----------------------------------------------------------------------------------
echo "==> Syncing resources..."
# Mirror Resources/ into the bundle (removing stale files). DMG installer artwork is not app content.
rsync -a --delete --exclude 'dmg/' --exclude '.DS_Store' Resources/ "${APP_DIR}/Contents/Resources/"

echo "==> Writing Info.plist (v${VERSION})..."
cat <<EOF >"${APP_DIR}/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS}</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>SilentSpy needs microphone access to record your voice on a separate channel.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>SilentSpy needs system audio capture access to record computer sounds on a separate channel.</string>
    <key>NSMusicUsageDescription</key>
    <string>SilentSpy needs access to save audio recordings to your Music folder.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>SilentSpy needs access to save audio recordings to your Downloads folder.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>SilentSpy needs access to save audio recordings to your Documents folder.</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>SilentSpy needs access to save audio recordings to your Desktop folder.</string>
</dict>
</plist>
EOF

# --- Sign -------------------------------------------------------------------------------------
if [ -n "${SIGN_IDENTITY}" ]; then
    echo "==> Signing with \"${SIGN_IDENTITY}\" (hardened runtime, secure timestamp)..."
    codesign --force --options runtime --timestamp \
        --entitlements Entitlements.plist -s "${SIGN_IDENTITY}" "${APP_DIR}"
else
    echo "==> Ad-hoc signing (hardened runtime, default cdhash requirement) — local use only."
    echo "    macOS will re-ask for Microphone/Screen Recording permission after each code change."
    codesign --force --options runtime \
        --entitlements Entitlements.plist -s - "${APP_DIR}"
fi
codesign --verify --strict "${APP_DIR}"
echo "${SIGN_MODE}" >"${SIGN_STAMP}"

echo "==> Registering updated application bundle with LaunchServices..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R -trusted "${APP_DIR}" || true
touch "${APP_DIR}"

echo "✅ Build successfully completed: ${APP_DIR} (v${VERSION})"
