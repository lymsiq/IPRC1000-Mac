#!/bin/zsh
# 还原 `enable-hci-trace.sh` 对蓝牙调试偏好做的改动。
# 会把 /Library/Preferences/com.apple.MobileBluetooth.debug 恢复成"不存在"。
set -u

DEBUG_DOMAIN="/Library/Preferences/com.apple.MobileBluetooth.debug"
DEBUG_PLIST="/Library/Preferences/com.apple.MobileBluetooth.debug.plist"

if [[ "${1:-}" != "--now" ]]; then
    self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    exec osascript -e "do shell script \"'$self' --now\" with administrator privileges"
fi

echo "== 删除本工具写入的键 =="
defaults delete "$DEBUG_DOMAIN" HCITraces 2>/dev/null
defaults delete "$DEBUG_DOMAIN" HCISkipAuth 2>/dev/null
defaults delete "$DEBUG_DOMAIN" EnablePerPacketLogging 2>/dev/null

if defaults read "$DEBUG_DOMAIN" >/dev/null 2>&1; then
    echo "[i] 该域还有其它键（不是本工具写的），保留："
    defaults read "$DEBUG_DOMAIN"
else
    rm -f "$DEBUG_PLIST"
    echo "[✓] 该域已空，plist 已删除（回到未启用状态）"
fi

echo "== 重启 bluetoothd =="
killall -9 bluetoothd 2>/dev/null
sleep 4
pgrep -lf bluetoothd >/dev/null && echo "✅ 已还原" || echo "[!] bluetoothd 未运行，请重启电脑"
