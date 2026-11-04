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
SIGN_STAMP="build/.sign-mode"
ARCHS=(x86_64 arm64)
SDK_PATH=$(xcrun --show-sdk-path)

echo "==> Building ${APP_NAME}.app v${VERSION}..."

mkdir -p "build/${APP_NAME}.app/Contents/MacOS"
mkdir -p "build/${APP_NAME}.app/Contents/Resources"

# Generate or copy AppIcon.icns if needed
if [ -f "Resources/leaf-app-icon.png" ]; then
    if [ ! -f "Resources/AppIcon.icns" ] || [ "Resources/leaf-app-icon.png" -nt "Resources/AppIcon.icns" ]; then
        echo "🎨 Generating AppIcon.icns from leaf-app-icon.png..."
        mkdir -p /tmp/AppIcon.iconset
        sips -z 16 16 Resources/leaf-app-icon.png --out /tmp/AppIcon.iconset/icon_16x16.png >/dev/null 2>&1
        sips -z 32 32 Resources/leaf-app-icon.png --out /tmp/AppIcon.iconset/icon_16x16@2x.png >/dev/null 2>&1
        sips -z 32 32 Resources/leaf-app-icon.png --out /tmp/AppIcon.iconset/icon_32x32.png >/dev/null 2>&1
        sips -z 64 64 Resources/leaf-app-icon.png --out /tmp/AppIcon.iconset/icon_32x32@2x.png >/dev/null 2>&1
        sips -z 128 128 Resources/leaf-app-icon.png --out /tmp/AppIcon.iconset/icon_128x128.png >/dev/null 2>&1
        sips -z 256 256 Resources/leaf-app-icon.png --out /tmp/AppIcon.iconset/icon_128x128@2x.png >/dev/null 2>&1
        sips -z 256 256 Resources/leaf-app-icon.png --out /tmp/AppIcon.iconset/icon_256x256.png >/dev/null 2>&1
        sips -z 512 512 Resources/leaf-app-icon.png --out /tmp/AppIcon.iconset/icon_256x256@2x.png >/dev/null 2>&1
        sips -z 512 512 Resources/leaf-app-icon.png --out /tmp/AppIcon.iconset/icon_512x512.png >/dev/null 2>&1
        sips -z 1024 1024 Resources/leaf-app-icon.png --out /tmp/AppIcon.iconset/icon_512x512@2x.png >/dev/null 2>&1
        iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns
        rm -rf /tmp/AppIcon.iconset
    fi
fi

if [ -d "Resources" ]; then
    cp -R Resources/* "build/${APP_NAME}.app/Contents/Resources/" 2>/dev/null || true
fi

BINARY="build/${APP_NAME}.app/Contents/MacOS/${APP_NAME}"

# Determine if any source files are newer than the existing signed binary.
# swiftc embeds non-deterministic UUIDs/timestamps, so recompiling always
# produces a different binary and therefore a new CDHash. macOS TCC ties
# permission grants to the CDHash, meaning a new signature invalidates the grant.
# We avoid this by skipping compile+sign when the sources haven't changed.
NEEDS_BUILD=true
if [ -f "${BINARY}" ]; then
    NEWEST_SOURCE=$(find Sources/SilentSpy -name '*.swift' -newer "${BINARY}" 2>/dev/null | head -n 1)
    if [ -z "${NEWEST_SOURCE}" ] && [ ! "build.sh" -nt "${BINARY}" ] && [ ! "Entitlements.plist" -nt "${BINARY}" ]; then
        NEEDS_BUILD=false
        # Force a rebuild when the signing mode changed
        if [ "$(cat "${SIGN_STAMP}" 2>/dev/null)" != "${SIGN_MODE}" ]; then
            NEEDS_BUILD=true
        fi
        # Force a rebuild if the existing binary is missing an architecture slice
        for ARCH in "${ARCHS[@]}"; do
            if ! lipo "${BINARY}" -verify_arch "${ARCH}" 2>/dev/null; then
                NEEDS_BUILD=true
            fi
        done
    fi
fi

if [ "${NEEDS_BUILD}" = true ]; then
    echo "==> Writing Info.plist (v${VERSION})..."
    cat <<EOF >"build/${APP_NAME}.app/Contents/Info.plist"
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

    echo "==> Compiling Universal 2 binary (x86_64 + arm64)..."
    SWIFT_FILES=$(find Sources/SilentSpy -name "*.swift")
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
    SLICES=()
    for ARCH in "${ARCHS[@]}"; do
        echo "   -> ${ARCH}"
        swiftc -O -sdk "${SDK_PATH}" -target "${ARCH}-apple-macos${MIN_MACOS}" -parse-as-library \
            "${FRAMEWORKS[@]}" ${SWIFT_FILES} -o "${OBJ_DIR}/${APP_NAME}_${ARCH}"
        SLICES+=("${OBJ_DIR}/${APP_NAME}_${ARCH}")
    done

    lipo -create "${SLICES[@]}" -output "${BINARY}"
    rm -rf "${OBJ_DIR}"

    for ARCH in "${ARCHS[@]}"; do
        lipo "${BINARY}" -verify_arch "${ARCH}" || { echo "❌ Missing ${ARCH} slice in ${BINARY}"; exit 1; }
    done
    echo "==> Architectures: $(lipo -archs "${BINARY}")"

    if [ -n "${SIGN_IDENTITY}" ]; then
        echo "==> Signing with \"${SIGN_IDENTITY}\" (hardened runtime, secure timestamp)..."
        codesign --force --options runtime --timestamp \
            --entitlements Entitlements.plist -s "${SIGN_IDENTITY}" "build/${APP_NAME}.app"
    else
        echo "==> Ad-hoc signing (hardened runtime, default cdhash requirement) — local use only."
        echo "    macOS will re-ask for Microphone/Screen Recording permission after each code change."
        codesign --force --options runtime \
            --entitlements Entitlements.plist -s - "build/${APP_NAME}.app"
    fi
    codesign --verify --strict "build/${APP_NAME}.app"
    echo "${SIGN_MODE}" >"${SIGN_STAMP}"

    echo "==> Registering updated application bundle with LaunchServices..."
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R -trusted "build/${APP_NAME}.app" || true
    touch "build/${APP_NAME}.app"
else
    echo "==> Sources unchanged, skipping compile & codesign (preserving TCC permissions)."
fi

echo "✅ Build successfully completed: build/${APP_NAME}.app (v${VERSION})"
