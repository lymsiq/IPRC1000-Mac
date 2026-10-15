#!/bin/zsh
# 为 IPRC1000 Adapter 建立本地自签名代码签名身份，并用它给 App 签名。
#
# 为什么需要：ad-hoc 签名没有稳定身份，macOS 的 TCC（输入监控 / 辅助功能）会按
# cdhash 记录授权 —— 每次重新编译 cdhash 一变，用户就得重新授权一次。用一张固定的
# 自签名证书签名后，设计好的「指定要求(DR)」保持不变，授权就能持久生效。
#
#   ./setup-local-signing.sh          # 建证书（幂等）+ 打包签名
#   ./setup-local-signing.sh --sign-only   # 只签名（证书已存在时）
set -u

CN="IPRC1000 Local Signing"
KC="$HOME/Library/Keychains/iprc-signing.keychain-db"
KCPASS="iprc1000"          # 本地开发用，非敏感；证书仅本机自签、仅用于本地签名
CERT=/tmp/iprc.crt
KEY=/tmp/iprc.key
P12=/tmp/iprc.p12
root_dir=${0:A:h:h}

sign_only=${1:-}

if [[ "$sign_only" != "--sign-only" ]]; then
    echo "== 1) 生成自签名证书（codeSigning EKU）=="
    cat > /tmp/iprc_openssl.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3_code
prompt = no
[dn]
CN = IPRC1000 Local Signing
O = IPRC1000
C = CN
[v3_code]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
    rm -f "$KEY" "$CERT" "$P12"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$KEY" -out "$CERT" -config /tmp/iprc_openssl.cnf >/dev/null 2>&1
    openssl pkcs12 -export -inkey "$KEY" -in "$CERT" -out "$P12" \
        -passout pass:"$KCPASS" -name "$CN" >/dev/null 2>&1

    echo "== 2) 重建独立钥匙串并导入 =="
    security delete-keychain "$KC" 2>/dev/null || true
    security create-keychain -p "$KCPASS" "$KC"
    security unlock-keychain -p "$KCPASS" "$KC"
    security import "$P12" -k "$KC" -P "$KCPASS" \
        -T /usr/bin/codesign -T /usr/bin/security -A
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KC" >/dev/null

    echo "== 3) 信任该证书（codeSign 策略）=="
    security add-trusted-cert -r trustRoot -p codeSign -k "$KC" "$CERT"

    # ⚠ 关键：codesign 的 --keychain 参数在新版 macOS 上不生效，签名身份必须在
    # 用户的钥匙串**搜索列表**里，否则一律报 "no identity found"。
    echo "== 3.5) 把签名钥匙串加入用户搜索列表 =="
    LOGIN="$HOME/Library/Keychains/login.keychain-db"
    security list-keychains -d user -s "$LOGIN" "$KC"
    security list-keychains -d user
fi

echo "== 4) 校验身份 =="
security unlock-keychain -p "$KCPASS" "$KC" 2>/dev/null || true
security find-identity -v -p codesigning

echo "== 5) 打包 + 用该身份签名 =="
security unlock-keychain -p "$KCPASS" "$KC" 2>/dev/null || true
IPRC1000_CODE_SIGN_IDENTITY="$CN" zsh "$root_dir/scripts/package-app.sh"

app="$root_dir/dist/IPRC1000 Adapter.app"
echo "== 6) 校验签名 =="
codesign --verify --strict "$app" && echo "✅ 签名校验通过"
codesign -dvv "$app" 2>&1 | grep -E "Authority|TeamIdentifier|Signature|Identifier"
