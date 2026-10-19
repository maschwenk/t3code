#!/bin/bash
set -euo pipefail
[[ "$(uname -m)" == arm64 ]] || { echo 'GhosttyKit requires Apple Silicon.' >&2; exit 1; }
macos_root="$(cd "$(dirname "$0")/.." && pwd)"
deps="$macos_root/.build/terminal-deps"
revision="$(cat "$macos_root/Vendor/GHOSTTY_VERSION")"
mkdir -p "$deps"
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0=false
if [[ ! -d "$deps/ghostty/.git" ]]; then
  git clone --no-checkout https://github.com/Yash-Singh1/ghostty.git "$deps/ghostty"
  git -C "$deps/ghostty" checkout --detach "$revision"
fi
[[ "$(git -C "$deps/ghostty" rev-parse HEAD)" == "$revision" ]] || {
  echo "Check out Ghostty revision $revision in $deps/ghostty before rebuilding." >&2; exit 1;
}
[[ "${GHOSTTY_ALLOW_LOCAL_CHANGES:-0}" == 1 ]] || git -C "$deps/ghostty" diff --exit-code HEAD --quiet || {
  echo 'The Ghostty source contains local changes. Preserve them before rebuilding the vendored library.' >&2; exit 1;
}
if [[ ! -x "$deps/zig/zig" ]]; then
  archive="$deps/zig-aarch64-macos-0.16.0.tar.xz"
  curl --fail --location https://ziglang.org/download/0.16.0/zig-aarch64-macos-0.16.0.tar.xz --output "$archive"
  echo "b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489  $archive" | shasum -a 256 --check
  mkdir -p "$deps/zig"
  tar -xJf "$archive" --strip-components=1 -C "$deps/zig"
fi
[[ "$("$deps/zig/zig" version)" == 0.16.0 ]] || { echo 'Zig 0.16.0 is required.' >&2; exit 1; }
xcrun metal --version >/dev/null || {
  echo 'Install the Metal compiler with: xcodebuild -downloadComponent MetalToolchain' >&2; exit 1;
}
cd "$deps/ghostty"
"$deps/zig/zig" build -Dapp-runtime=none -Demit-xcframework=true \
  -Demit-macos-app=false -Demit-exe=false -Demit-docs=false \
  -Demit-webdata=false -Demit-helpgen=false -Demit-terminfo=false \
  -Demit-termcap=false -Demit-themes=false -Doptimize=ReleaseFast \
  -Dstrip -Dsentry=false -Dxcframework-target=native -j4
built="$deps/ghostty/macos/GhosttyKit.xcframework"
library='macos-arm64/libghostty-internal.a'
[[ "$(lipo -archs "$built/$library")" == arm64 ]] || { echo 'Expected an arm64 library.' >&2; exit 1; }
xcrun strip -S -x "$built/$library"
stage="$(mktemp -d "$macos_root/.build/ghostty-vendor.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
ditto "$built" "$stage/GhosttyKit.xcframework"
python3 "$macos_root/scripts/ghostty-notices.py" "$deps/ghostty" "$stage/Ghostty-THIRD-PARTY-NOTICES.txt"
rm -rf "$macos_root/Vendor/GhosttyKit.xcframework"
mv "$stage/GhosttyKit.xcframework" "$macos_root/Vendor/"
cp "$deps/ghostty/LICENSE" "$macos_root/Licenses/Ghostty-LICENSE.txt"
cp "$stage/Ghostty-THIRD-PARTY-NOTICES.txt" "$macos_root/Licenses/"
cd "$macos_root/Vendor"
shasum -a 256 "GhosttyKit.xcframework/$library" > GHOSTTY_SHA256
