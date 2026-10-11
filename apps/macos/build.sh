#!/bin/bash
set -euo pipefail
macos_root="$(cd "$(dirname "$0")" && pwd)"
swift build --package-path "$macos_root" -c release
binary_dir="$(swift build --package-path "$macos_root" -c release --show-bin-path)"
bundle="${1:-$macos_root/.build/T3 Native.app}"
mkdir -p "$bundle/Contents/MacOS"
cp "$binary_dir/T3Native" "$bundle/Contents/MacOS/T3Native"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.t3.native-prototype</string>
<key>CFBundleName</key><string>T3 Native</string>
<key>CFBundleExecutable</key><string>T3Native</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$bundle"
printf '%s\n' "$bundle"
