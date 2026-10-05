#!/usr/bin/env bash
set -euo pipefail

APP_NAME="SilentSpy"
BUNDLE_ID="com.silentspy.app"
VERSION="1.0.0"
if [ -f "VERSION" ]; then
    VERSION=$(tr -d ' \n\r' <VERSION)
fi
TARGET="arm64-apple-macos14.0"
SDK_PATH=$(xcrun --show-sdk-path)

echo "==> Building ${APP_NAME}.app v${VERSION}..."

mkdir -p "build/${APP_NAME}.app/Contents/MacOS"
mkdir -p "build/${APP_NAME}.app/Contents/Resources"

# Generate or copy AppIcon.icns if needed
if [ -f "Resources/leaf-app-icon.png" ]; then
    if [ ! -f "Resources/AppIcon.icns" ] || [ "Resources/leaf-app-icon.png" -nt "Resources/AppIcon.icns" ]; then
        echo "🎨 Generating AppIcon.icns from leaf-app-icon.png..."
        mkdir -p /tmp/AppIcon.iconset
        sips -z 16 16     Resources/leaf-app-icon.png --out /tmp/AppIcon.iconset/icon_16x16.png >/dev/null 2>&1
        sips -z 32 32     Resources/leaf-app-icon.png --out /tmp/AppIcon.iconset/icon_16x16@2x.png >/dev/null 2>&1
        sips -z 32 32     Resources/leaf-app-icon.png --out /tmp/AppIcon.iconset/icon_32x32.png >/dev/null 2>&1
        sips -z 64 64     Resources/leaf-app-icon.png --out /tmp/AppIcon.iconset/icon_32x32@2x.png >/dev/null 2>&1
        sips -z 128 128   Resources/leaf-app-icon.png --out /tmp/AppIcon.iconset/icon_128x128.png >/dev/null 2>&1
        sips -z 256 256   Resources/leaf-app-icon.png --out /tmp/AppIcon.iconset/icon_128x128@2x.png >/dev/null 2>&1
        sips -z 256 256   Resources/leaf-app-icon.png --out /tmp/AppIcon.iconset/icon_256x256.png >/dev/null 2>&1
        sips -z 512 512   Resources/leaf-app-icon.png --out /tmp/AppIcon.iconset/icon_256x256@2x.png >/dev/null 2>&1
        sips -z 512 512   Resources/leaf-app-icon.png --out /tmp/AppIcon.iconset/icon_512x512.png >/dev/null 2>&1
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
    <string>13.0</string>
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

    echo "==> Compiling Swift sources with swiftc..."
    SWIFT_FILES=$(find Sources/SilentSpy -name "*.swift")
    swiftc \
        -O \
        -sdk "${SDK_PATH}" \
        -target "${TARGET}" \
        -parse-as-library \
        -framework Foundation \
        -framework AppKit \
        -framework SwiftUI \
        -framework AVFoundation \
        -framework AudioToolbox \
        -framework ScreenCaptureKit \
        -framework CoreMedia \
        -framework CoreAudio \
        ${SWIFT_FILES} \
        -o "${BINARY}"

    echo "==> Signing application bundle with ad-hoc signature..."
    codesign -s - --force --deep -r="designated => identifier \"${BUNDLE_ID}\"" --entitlements Entitlements.plist "build/${APP_NAME}.app"

    echo "==> Registering updated application bundle with LaunchServices..."
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R -trusted "build/${APP_NAME}.app" || true
    touch "build/${APP_NAME}.app"
else
    echo "==> Sources unchanged, skipping compile & codesign (preserving TCC permissions)."
fi

echo "✅ Build successfully completed: build/${APP_NAME}.app (v${VERSION})"
