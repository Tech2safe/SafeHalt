#!/bin/bash
# 构建 SafeHalt .pkg 安装包（引导式安装；出厂哑，配对后由 Mac UPS Link 激活）。
# 用法: ./make-pkg.sh [版本号]
#   环境变量 SIGN_ID 设置时用 Developer ID Installer 证书签名（公证仍需人工 notarytool）。
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:-1.0.0}"
IDENT="com.safehalt.daemon"

echo "==> 构建 release 二进制"
swift build -c release --product safehalt
BIN="$(swift build -c release --show-bin-path)/safehalt"

STAGE="$(mktemp -d /tmp/safehalt-pkg.XXXXXX)"
SCRIPTS="$(mktemp -d /tmp/safehalt-scripts.XXXXXX)"
trap 'rm -rf "$STAGE" "$SCRIPTS"' EXIT

echo "==> 组装 payload"
mkdir -p "$STAGE/usr/local/bin" "$STAGE/Library/LaunchDaemons"
cp "$BIN" "$STAGE/usr/local/bin/safehalt"
chmod 755 "$STAGE/usr/local/bin/safehalt"
"$BIN" --print-plist > "$STAGE/Library/LaunchDaemons/com.safehalt.daemon.plist"
chmod 644 "$STAGE/Library/LaunchDaemons/com.safehalt.daemon.plist"

echo "==> 生成 postinstall"
cat > "$SCRIPTS/postinstall" <<'POST'
#!/bin/bash
set -e
PLIST="/Library/LaunchDaemons/com.safehalt.daemon.plist"
chown root:wheel "$PLIST"; chmod 644 "$PLIST"
mkdir -p "/Library/Application Support/SafeHalt"
chmod 700 "/Library/Application Support/SafeHalt"
chown root:wheel "/Library/Application Support/SafeHalt"
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load -w "$PLIST"
# 生成配对码并弹品牌对话框引导用户到 App 激活
CODE_LINE="$(/usr/local/bin/safehalt pair-init || true)"
CODE="${CODE_LINE#PAIRING_CODE=}"
if [ -n "$CODE" ] && [ "$CODE" != "$CODE_LINE" ]; then
  /usr/local/bin/safehalt show-pairing-dialog "$CODE" || true
fi
exit 0
POST
chmod 755 "$SCRIPTS/postinstall"

mkdir -p dist
RAW="dist/SafeHalt-unsigned.pkg"
FINAL="dist/SafeHalt.pkg"
echo "==> pkgbuild"
pkgbuild --root "$STAGE" --scripts "$SCRIPTS" \
    --identifier "$IDENT" --version "$VERSION" \
    --install-location / "$RAW"

if [ -n "${SIGN_ID:-}" ]; then
  echo "==> productsign（${SIGN_ID}）"
  productsign --sign "$SIGN_ID" "$RAW" "$FINAL"
  rm -f "$RAW"
else
  mv "$RAW" "$FINAL"
  echo "⚠ 未签名（设 SIGN_ID 可签名；分发前仍需 notarytool 公证）"
fi
echo "✅ 生成 ${FINAL}（版本 ${VERSION}）"
