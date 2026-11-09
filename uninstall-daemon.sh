#!/bin/bash
# SafeHalt 关机守护进程卸载器。
set -euo pipefail
SCRIPT_TMP="$(mktemp /tmp/safehalt-uninstall.XXXXXX.sh)"
cat > "$SCRIPT_TMP" <<'UNINSTALL'
#!/bin/bash
launchctl unload /Library/LaunchDaemons/com.safehalt.daemon.plist 2>/dev/null || true
rm -f /Library/LaunchDaemons/com.safehalt.daemon.plist
rm -f /usr/local/bin/safehalt
rm -f "/Library/Application Support/SafeHalt/config.json"
rm -f "/Library/Application Support/SafeHalt/pairing.json"
rm -f "/Library/Application Support/SafeHalt/events.json"
rm -f /tmp/safehalt-cancel-shutdown
echo SAFEHALT_DAEMON_UNINSTALLED
UNINSTALL
osascript -e "do shell script \"/bin/bash '$SCRIPT_TMP' 2>&1\" with prompt \"SafeHalt 断电保护正在卸载后台守护进程\" with administrator privileges"
rm -f "$SCRIPT_TMP"
echo "✅ 守护进程已卸载"
