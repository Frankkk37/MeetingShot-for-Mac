#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="MeetingShot"
BUNDLE_ID="com.frank.meetingshot"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

cd "$ROOT"

echo "[1/5] 检查 Swift 编译环境"
if ! command -v xcrun >/dev/null 2>&1; then
    echo "错误：未找到 xcrun。请运行 xcode-select --install 安装 Apple 命令行工具。" >&2
    exit 1
fi

SWIFTC="$(xcrun --find swiftc 2>/dev/null || true)"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"

if [[ -z "$SWIFTC" || ! -x "$SWIFTC" ]]; then
    echo "错误：未找到 Swift 编译器。请运行 xcode-select --install。" >&2
    exit 1
fi
if [[ -z "$SDK_PATH" || ! -d "$SDK_PATH" ]]; then
    echo "错误：未找到 macOS SDK。请运行 xcode-select --install。" >&2
    exit 1
fi

"$SWIFTC" --version | head -n 1
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

echo "[2/5] 编译 MeetingShot v0.3（方案二 MVP）"
"$SWIFTC" \
    -swift-version 5 \
    -O \
    -sdk "$SDK_PATH" \
    "$ROOT/Sources/MeetingShot/Models.swift" \
    "$ROOT/Sources/MeetingShot/ScreenshotService.swift" \
    "$ROOT/Sources/MeetingShot/ControlWindowController.swift" \
    "$ROOT/Sources/MeetingShot/AppDelegate.swift" \
    "$ROOT/Sources/MeetingShot/main.swift" \
    -framework AppKit \
    -framework CoreGraphics \
    -framework ImageIO \
    -framework PDFKit \
    -o "$MACOS/$APP_NAME"
chmod +x "$MACOS/$APP_NAME"

echo "[3/5] 写入应用信息和图标"
cp "$ROOT/Resources/MeetingShot.icns" "$RESOURCES/MeetingShot.icns"
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>MeetingShot</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.3</string>
    <key>CFBundleVersion</key>
    <string>30</string>
    <key>CFBundleIconFile</key>
    <string>MeetingShot</string>
    <key>LSMinimumSystemVersion</key>
    <string>10.15</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>MeetingShot 需要读取主显示器画面，以检测画面变化并在用户手动开始后保存截图。</string>
</dict>
</plist>
PLIST

echo "[4/5] 签名并验证"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
plutil -lint "$CONTENTS/Info.plist"

echo "[5/5] 构建完成"
echo "应用位置：$APP"
