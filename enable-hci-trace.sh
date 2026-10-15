#!/bin/zsh
# 开启 macOS 蓝牙 HCI 追踪（含跳过 PacketLogger 鉴权）
#
# 为什么需要它：macOS 默认把蓝牙包数据锁住，直接调私有 CBPacketLoggerClient 会
# 连得上但**收不到任何包**（bluetoothd 回 "Bluetooth Profile Required"）。
# 打开下面这几个开关，bluetoothd 就会把原始 HCI 流转出来 —— **不需要 Apple 的
# 蓝牙日志描述文件、也不需要 PacketLogger**。
#
# 完全可逆：./disable-hci-trace.sh 还原。
# 需要管理员密码；重启 bluetoothd 会让蓝牙设备短暂断开几秒（会自动回连）。
set -u

DEBUG_DOMAIN="/Library/Preferences/com.apple.MobileBluetooth.debug"
self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

if [[ "${1:-}" != "--now" ]]; then
    exec osascript -e "do shell script \"'$self' --now\" with administrator privileges"
fi

echo "== ① 写入 HCITraces 字典（★ 低延迟组合，实测调过）=="
# 实测 A/B（同机同设备，空载）：
#   含 EnablePerPacketLogging  → 到达延迟 平均 53 ms / 峰值 71 ms
#   去掉它（下面这套）          → 到达延迟 平均  2 ms / 峰值 15 ms，且包量不减
# 所以**千万别加回 EnablePerPacketLogging / HCIFileTraces**，它会让 bluetoothd
# 做大量额外工作，直接把语音延迟推高 50 ms。
defaults write "$DEBUG_DOMAIN" HCITraces -dict \
    StackDebugEnabled   -bool true \
    HCISkipAuth         -bool true \
    RawAudioTrace       -bool true \
    HIDTrace            -bool true \
    HCILiveTraces       -bool true

echo "== ② 顶层开关（跳过 PacketLogger 鉴权）=="
defaults write "$DEBUG_DOMAIN" HCISkipAuth -bool true

echo "== ③ 回读确认 =="
defaults read "$DEBUG_DOMAIN"

echo "== ④ 重启 bluetoothd（SIGUSR1 不足以让它重载，必须重启）=="
killall -9 bluetoothd 2>/dev/null
sleep 4
pgrep -lf bluetoothd || echo "[!] bluetoothd 没起来，请重启电脑"

echo ""
echo "✅ HCI 追踪已开启（低延迟组合）。现在可以："
echo "   cd \"$(dirname "$self")/..\" && ./voice-input.sh"
