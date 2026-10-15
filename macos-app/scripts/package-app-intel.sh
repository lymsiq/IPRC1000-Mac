#!/bin/zsh
set -euo pipefail

root_dir=${0:A:h:h}
sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
cache_dir=/private/tmp/iprc1000-intel-module-cache
library_dir="$root_dir/Vendor/lib-intel"
app="$root_dir/dist/IPRC1000 Adapter Intel.app"
sign_identity=${IPRC1000_CODE_SIGN_IDENTITY:--}

if [[ ! -f "$library_dir/libsbc.a" ]]; then
    "$root_dir/scripts/build-libsbc-intel.sh"
fi

mkdir -p "$cache_dir"
SDKROOT="$sdk" \
CLANG_MODULE_CACHE_PATH="$cache_dir" \
SWIFT_MODULECACHE_PATH="$cache_dir" \
IPRC1000_SBC_LIBRARY_PATH="$library_dir" \
    swift build --disable-sandbox -c release --sdk "$sdk" \
    --triple x86_64-apple-macosx14.0

bin_path=$(SDKROOT="$sdk" \
    CLANG_MODULE_CACHE_PATH="$cache_dir" \
    SWIFT_MODULECACHE_PATH="$cache_dir" \
    IPRC1000_SBC_LIBRARY_PATH="$library_dir" \
    swift build --disable-sandbox -c release --sdk "$sdk" \
    --triple x86_64-apple-macosx14.0 --show-bin-path)

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_path/IPRC1000Adapter" "$app/Contents/MacOS/IPRC1000Adapter"
cp "$root_dir/NOTICE.md" "$app/Contents/Resources/NOTICE.md"
cp "$root_dir/LICENSE" "$app/Contents/Resources/LICENSE"
cp "$root_dir/Vendor/Source/sbc-2.2.tar.xz" "$app/Contents/Resources/sbc-2.2.tar.xz"
cp "$root_dir/App/Assets/IPRC1000.icns" "$app/Contents/Resources/IPRC1000.icns"
cp "$root_dir/App/Assets/IPRC1000-Remote.png" "$app/Contents/Resources/IPRC1000-Remote.png"
cp "$root_dir/App/Info.plist" "$app/Contents/Info.plist"
codesign --force --deep --sign "$sign_identity" "$app"
echo "$app"
