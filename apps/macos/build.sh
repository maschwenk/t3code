#!/bin/bash
set -euo pipefail
[[ "$(uname -m)" == arm64 ]] || { echo 'T3 Native requires Apple Silicon.' >&2; exit 1; }
macos_root="$(cd "$(dirname "$0")" && pwd)"
(cd "$macos_root/Vendor" && shasum -a 256 --check GHOSTTY_SHA256)
(cd "$macos_root" && shasum -a 256 --check Vendor/PLAYWRIGHT_SHA256)
swift build --package-path "$macos_root" -c release
binary_dir="$(swift build --package-path "$macos_root" -c release --show-bin-path)"
bundle="${1:-$macos_root/.build/T3 Native.app}"
sign_identity="${T3_NATIVE_SIGN_IDENTITY:--}"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources/Licenses"
cp -f "$macos_root"/Licenses/* "$bundle/Contents/Resources/Licenses/"
cp -R "$binary_dir/T3Native_T3Native.bundle" "$bundle/Contents/Resources/"
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
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/><key>NSAllowsArbitraryLoadsInWebContent</key><true/></dict>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
revision="$(git -C "$macos_root" -c core.fsmonitor=false rev-parse HEAD 2>/dev/null || printf unknown)"
modified=false
if [[ -n "$(git -C "$macos_root" -c core.fsmonitor=false status --porcelain -- . 2>/dev/null)" ]]; then
  modified=true
fi
/usr/libexec/PlistBuddy -c "Add :T3SourceRevision string $revision" "$bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :T3SourceModified bool $modified" "$bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :T3BuildDate string $(date -u +%Y-%m-%dT%H:%M:%SZ)" "$bundle/Contents/Info.plist"
node "$macos_root/package-backend.mjs" "$bundle"
node "$macos_root/../desktop/scripts/ensure-electron-runtime.mjs"
node "$macos_root/build-chromium-helper.mjs" \
  --output "$bundle/Contents/Resources/chromium-helper" \
  --runtime "$macos_root/../desktop/node_modules/electron/dist/Electron.app" \
  --sign "$sign_identity"
codesign --force --sign "$sign_identity" "$bundle"
printf '%s\n' "$bundle"
