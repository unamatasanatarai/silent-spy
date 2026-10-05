#!/usr/bin/env bash
set -euo pipefail

APP_NAME="SilentSpy"
VERSION="1.0.0"
if [ -f "VERSION" ]; then
    VERSION=$(tr -d ' \n\r' <VERSION)
fi

echo "==> Creating ${APP_NAME} v${VERSION} DMG installer..."

# 1. Ensure SilentSpy.app is built
if [ ! -d "build/${APP_NAME}.app" ]; then
    echo "==> Building ${APP_NAME}.app first..."
    ./build.sh
fi

# 2. Generate high-resolution Retina background
echo "🎨 Rendering DMG background image..."
swift scripts/generate_dmg_background.swift

if [ -f "Resources/dmg/background.png" ] && [ -f "Resources/dmg/background@2x.png" ]; then
    /usr/bin/tiffutil -cathidpicheck \
        Resources/dmg/background.png \
        Resources/dmg/background@2x.png \
        -out Resources/dmg/background.tiff 2>/dev/null || true
fi

# 3. Detach any stale mounted volume
hdiutil detach "/Volumes/${APP_NAME}" 2>/dev/null || true

# 4. Create temporary read-write disk image
TEMP_DMG="build/temp_${APP_NAME}.dmg"
FINAL_DMG="build/${APP_NAME}.dmg"
rm -f "${TEMP_DMG}" "${FINAL_DMG}"

echo "💿 Creating staging volume..."
hdiutil create -size 40m -fs HFS+ -volname "${APP_NAME}" -ov "${TEMP_DMG}" >/dev/null

DEV=$(hdiutil attach -readwrite -noverify -noautoopen "${TEMP_DMG}" | grep -E '^/dev/' | head -n 1 | awk '{print $1}')
echo "Mounted at: ${DEV} -> /Volumes/${APP_NAME}"

# 5. Populate volume assets
mkdir -p "/Volumes/${APP_NAME}/.background"
cp "Resources/dmg/background.png" "/Volumes/${APP_NAME}/.background/background.png"
if [ -f "Resources/dmg/background@2x.png" ]; then
    cp "Resources/dmg/background@2x.png" "/Volumes/${APP_NAME}/.background/background@2x.png"
fi
if [ -f "Resources/dmg/background.tiff" ]; then
    cp "Resources/dmg/background.tiff" "/Volumes/${APP_NAME}/.background/background.tiff"
fi

cp -R "build/${APP_NAME}.app" "/Volumes/${APP_NAME}/"
ln -s /Applications "/Volumes/${APP_NAME}/Applications"

if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "/Volumes/${APP_NAME}/.VolumeIcon.icns"
    /usr/bin/SetFile -c icnC "/Volumes/${APP_NAME}/.VolumeIcon.icns" 2>/dev/null || true
    /usr/bin/SetFile -a C "/Volumes/${APP_NAME}" 2>/dev/null || true
fi
/usr/bin/SetFile -a V "/Volumes/${APP_NAME}/.background" 2>/dev/null || true

# 6. Apply Finder styling via AppleScript
echo "📐 Applying Finder layout, icon positions & background..."
osascript -e '
tell application "Finder"
    tell disk "'"${APP_NAME}"'"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 840, 540}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 110
        set text size of theViewOptions to 12
        set background picture of theViewOptions to file ".background:background.png"
        set position of item "'"${APP_NAME}"'.app" of container window to {160, 210}
        set position of item "Applications" of container window to {480, 210}
        close container window
        open
        delay 2
        close container window
    end tell
end tell'

sync
sleep 1

# 7. Detach temporary volume
echo "Ejecting staging volume..."
hdiutil detach "${DEV}" >/dev/null

# 8. Convert to compressed, read-only distribution DMG
echo "📦 Compressing final DMG..."
hdiutil convert "${TEMP_DMG}" -format UDZO -imagekey zlib-level=9 -o "${FINAL_DMG}" -ov >/dev/null
rm -f "${TEMP_DMG}"
rm -rf build/dmg_stage build/*_test.dmg

DMG_SIZE=$(du -h "${FINAL_DMG}" | cut -f1)
echo "✅ DMG successfully built: ${FINAL_DMG} (${DMG_SIZE})"
