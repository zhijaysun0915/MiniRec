#!/usr/bin/env bash
set -e

cd "$(dirname "$0")"

echo "🔨 正在編譯 MiniRec (Release 最佳化模式)..."
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/minirec"
if [ ! -f "$BIN_PATH" ]; then
    BIN_PATH=".build/out/Products/Release/minirec"
fi
if [ ! -f "$BIN_PATH" ]; then
    BIN_PATH=".build/release/minirec"
fi

APP_BUNDLE="MiniRec.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "📦 正在建立 macOS 應用程式 Bundle ($APP_BUNDLE)..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/minirec"
chmod +x "$MACOS_DIR/minirec"

cat << 'EOF' > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh-Hant</string>
    <key>CFBundleExecutable</key>
    <string>minirec</string>
    <key>CFBundleIdentifier</key>
    <string>com.jaysun.minirec</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>MiniRec</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>MiniRec 需要螢幕錄製權限以錄製高品質極小體積的螢幕影片與截圖。</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>MiniRec 需要麥克風權限以錄製語音旁白。</string>
</dict>
</plist>
EOF

# Ad-hoc sign the binary and bundle for ARM64 macOS
echo "🔏 正在簽署 (Ad-hoc codesign)..."
codesign --force --sign - "$MACOS_DIR/minirec"
codesign --force --deep --sign - "$APP_BUNDLE"

# Create a convenient CLI symlink in current directory
rm -f ./minirec
ln -sf "$MACOS_DIR/minirec" ./minirec

echo "✔ 建置完成！"
echo "  • 命令列工具 (CLI): $(pwd)/minirec"
echo "  • 選單列應用程式 (App): $(pwd)/MiniRec.app"
