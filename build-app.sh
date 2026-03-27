#!/bin/bash
set -e

APP_NAME="G309MouseTool"
BUNDLE_NAME="KMC"
BUNDLE_ID="com.jc.kmc"
VERSION="1.9.6"
BUILD_DIR=".build/release"
APP_DIR="build/KMC_v${VERSION}.app"

echo "=== 기존 빌드 삭제 ==="
rm -rf build/
pkill -f G309MouseTool 2>/dev/null || true
pkill -f KMC 2>/dev/null || true
sleep 1

echo "=== Building KMC v${VERSION} (Release) ==="
swift build -c release

echo "=== Creating .app bundle ==="
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

# Copy executable
cp "${BUILD_DIR}/${APP_NAME}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

# Generate Info.plist
cat > "${APP_DIR}/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${BUNDLE_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${BUNDLE_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.5</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key>
    <string>KMC - Keyboard Mouse Control by Jc</string>
</dict>
</plist>
PLIST

# Copy app icon
ICON_SRC="Sources/G309MouseTool/Resources/AppIcon.icns"
if [ -f "$ICON_SRC" ]; then
    cp "$ICON_SRC" "${APP_DIR}/Contents/Resources/AppIcon.icns"
    echo "아이콘 복사 완료"
fi

# PkgInfo
echo -n "APPL????" > "${APP_DIR}/Contents/PkgInfo"

# Ad-hoc code sign
echo "=== Code signing ==="
codesign --force --deep --sign - "${APP_DIR}"
echo "서명 완료: $(codesign -dv "${APP_DIR}" 2>&1 | grep Identifier)"

echo ""
echo "=== 빌드 완료! ==="
echo "앱: $(pwd)/${APP_DIR}"
echo ""
echo "실행: open \"${APP_DIR}\""
echo ""
