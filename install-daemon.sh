#!/bin/bash
# SafeHalt 关机守护进程安装器。用法：./install-daemon.sh <config.json>
# 弹一次管理员密码，把二进制/配置/plist 落位并加载。
set -euo pipefail
# 先按调用者当前目录把配置解析成绝对路径，再切到脚本目录——否则相对路径会错解到脚本目录
CONFIG_ARG="${1:?用法: ./install-daemon.sh <config.json>}"
case "$CONFIG_ARG" in
  /*) CONFIG="$CONFIG_ARG" ;;
  *)  CONFIG="$PWD/$CONFIG_ARG" ;;
esac
cd "$(dirname "$0")"
[ -f "$CONFIG" ] || { echo "找不到配置文件: $CONFIG" >&2; exit 1; }

swift build -c release --product safehalt
BIN="$(swift build -c release --show-bin-path)/safehalt"

PLIST_TMP="$(mktemp /tmp/safehalt-plist.XXXXXX)"
"$BIN" --print-plist > "$PLIST_TMP"

SCRIPT_TMP="$(mktemp /tmp/safehalt-install.XXXXXX.sh)"
cat > "$SCRIPT_TMP" <<INSTALL
#!/bin/bash
set -e
mkdir -p /usr/local/bin "/Library/Application Support/SafeHalt"
cp "$BIN" /usr/local/bin/safehalt && chmod 755 /usr/local/bin/safehalt
install -m 600 "$CONFIG" "/Library/Application Support/SafeHalt/config.json"
cp "$PLIST_TMP" /Library/LaunchDaemons/com.safehalt.daemon.plist
chown root:wheel /Library/LaunchDaemons/com.safehalt.daemon.plist && chmod 644 /Library/LaunchDaemons/com.safehalt.daemon.plist
launchctl unload /Library/LaunchDaemons/com.safehalt.daemon.plist 2>/dev/null || true
launchctl load -w /Library/LaunchDaemons/com.safehalt.daemon.plist
echo SAFEHALT_DAEMON_INSTALLED
INSTALL

osascript -e "do shell script \"/bin/bash '$SCRIPT_TMP' 2>&1\" with prompt \"SafeHalt 断电保护正在安装后台守护进程\" with administrator privileges"
rm -f "$SCRIPT_TMP" "$PLIST_TMP"
echo "✅ 守护进程已安装并启动（日志：/var/log/safehalt.log）"
