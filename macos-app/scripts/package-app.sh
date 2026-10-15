#!/bin/zsh
set -euo pipefail

root_dir=${0:A:h:h}
sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
cache_dir=/private/tmp/iprc1000-module-cache
app="$root_dir/dist/IPRC1000 Adapter.app"
sign_identity=${IPRC1000_CODE_SIGN_IDENTITY:--}
# 自签名证书放在独立钥匙串里（见 scripts/setup-local-signing.sh）。
# 用稳定身份签名后，TCC 授权能持久生效，重新编译也不用重新授权。
sign_keychain=${IPRC1000_CODE_SIGN_KEYCHAIN:-$HOME/Library/Keychains/iprc-signing.keychain-db}

mkdir -p "$cache_dir"
SDKROOT="$sdk" CLANG_MODULE_CACHE_PATH="$cache_dir" SWIFT_MODULECACHE_PATH="$cache_dir" \
    swift build --disable-sandbox -c release --sdk "$sdk"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root_dir/.build/arm64-apple-macosx/release/IPRC1000Adapter" \
    "$app/Contents/MacOS/IPRC1000Adapter"
cp "$root_dir/NOTICE.md" "$app/Contents/Resources/NOTICE.md"
cp "$root_dir/LICENSE" "$app/Contents/Resources/LICENSE"
# LGPL 合规用的 libsbc 上游源码包；本地缺失时不阻断打包（仅少一份许可证素材）。
if [[ -f "$root_dir/Vendor/Source/sbc-2.2.tar.xz" ]]; then
    cp "$root_dir/Vendor/Source/sbc-2.2.tar.xz" "$app/Contents/Resources/sbc-2.2.tar.xz"
else
    echo "[warn] 缺少 Vendor/Source/sbc-2.2.tar.xz，跳过（不影响运行）"
fi
cp "$root_dir/App/Assets/IPRC1000.icns" "$app/Contents/Resources/IPRC1000.icns"
cp "$root_dir/App/Assets/IPRC1000-Remote.png" "$app/Contents/Resources/IPRC1000-Remote.png"
# 语音实现说明并入 App 资源，便于查阅
if [[ -f "$root_dir/docs/MACOS_VOICE.md" ]]; then
    cp "$root_dir/docs/MACOS_VOICE.md" "$app/Contents/Resources/MACOS_VOICE.md"
fi
cp "$root_dir/App/Info.plist" "$app/Contents/Info.plist"
if [[ "$sign_identity" == "-" || -z "$sign_identity" ]]; then
    codesign --force --sign - "$app"
else
    # 注意：codesign 的 --keychain 参数在新版 macOS 上不生效 —— 签名身份必须位于
    # 用户的钥匙串**搜索列表**里（scripts/setup-local-signing.sh 会加进去）。
    # 所以这里不能传 --keychain，否则会报 "no identity found"。
    codesign --force --sign "$sign_identity" "$app"
fi

# 构建产物不要留在 LaunchServices 里：它和 /Applications 里装着的那份 bundle id 相同，
# 一旦被注册，Launchpad / 右键"打开方式"就会列出两个 IPRC1000。
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/"
LSREGISTER+="LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -u "$app" 2>/dev/null || true
# 同时别让 Spotlight 索引构建目录
touch "$(dirname "$app")/.metadata_never_index" "$(dirname "$app")/.noindex" 2>/dev/null || true

echo "$app"
