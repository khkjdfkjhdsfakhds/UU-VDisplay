#!/bin/zsh
# 编译并打包 VDisplay.app；加 --install 则装到 /Applications
set -e
cd "${0:A:h}"
APP=build/VDisplay.app
rm -rf build && mkdir -p $APP/Contents/MacOS
swiftc -O -swift-version 5 -target arm64-apple-macos14 \
  -import-objc-header Sources/Private.h \
  -framework AppKit -framework CoreGraphics -framework IOKit -framework ServiceManagement \
  Sources/*.swift -o $APP/Contents/MacOS/VDisplay
cat > $APP/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.vdisplay</string>
  <key>CFBundleName</key><string>VDisplay</string>
  <key>CFBundleExecutable</key><string>VDisplay</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
# 优先用本机自签名证书（签名固定，重编译后“辅助功能”授权不失效）
ID=$(security find-identity -p codesigning 2>/dev/null | awk '/"VDisplay Local Signing"/{print $2; exit}')
codesign --force --sign "${ID:--}" $APP
echo "built $APP"
if [[ "$1" == "--install" ]]; then
  pkill -x VDisplay 2>/dev/null || true
  rm -rf /Applications/VDisplay.app
  cp -R $APP /Applications/
  echo "installed /Applications/VDisplay.app"
fi
