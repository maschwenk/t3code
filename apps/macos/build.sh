#!/bin/bash
set -euo pipefail
[[ "$(uname -m)" == arm64 ]] || { echo 'T3 Native requires Apple Silicon.' >&2; exit 1; }
macos_root="$(cd "$(dirname "$0")" && pwd)"
(cd "$macos_root/Vendor" && shasum -a 256 --check GHOSTTY_SHA256)
swift build --package-path "$macos_root" -c release
binary_dir="$(swift build --package-path "$macos_root" -c release --show-bin-path)"
bundle="${1:-$macos_root/.build/T3 Native.app}"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources/Licenses"
cp -f "$macos_root"/Licenses/* "$bundle/Contents/Resources/Licenses/"
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
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$bundle"
printf '%s\n' "$bundle"
