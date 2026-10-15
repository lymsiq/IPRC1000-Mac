#!/bin/zsh
# IPRC1000 遥控器语音输入 · 状态检查 / 调试工具
#
# 日常用法：什么都不用跑 —— 菜单栏 App（IPRC1000 Adapter）**常驻**完成整条链路：
#
#     bluetoothd HCI 流 → App 抠出 653B 音频帧 → 解码 → BlackHole 2ch → 系统默认输入 → 输入法
#
# 这个脚本用来查状态和排障：
#     ./voice-input.sh              # 查状态（权限 / 收包 / 解码帧数 / 默认输入 / 追踪开关）
#     ./voice-input.sh --cli 120    # 临时用命令行收流 120 秒（App 要退出，避免抢通道）
#     ./voice-input.sh --follow F   # 兜底：跟随 PacketLogger 抓包文件
#     ./voice-input.sh --input bh   # 默认输入切到 BlackHole 2ch
#     ./voice-input.sh --input mic  # 默认输入切回内置麦克风
set -u

APP="/Applications/IPRC1000 Adapter.app/Contents/MacOS/IPRC1000Adapter"
[[ -x "$APP" ]] || { echo "[!] 没找到 App，请先运行 ./install.sh"; exit 1; }

DEBUG_DOMAIN="/Library/Preferences/com.apple.MobileBluetooth.debug"

case "${1:-}" in
    --cli)
        SECONDS_TO_RUN="${2:-120}"
        echo "模式：命令行收流 ${SECONDS_TO_RUN}s（请先退出菜单栏 App）"
        echo ">>> 按住遥控器【麦克风键】说话 <<<"
        exec "$APP" --hci-stream "$SECONDS_TO_RUN"
        ;;
    --follow)
        FILE="${2:-/tmp/iprc.pklg}"; POLL="${3:-100}"
        echo "模式：跟随抓包文件 $FILE"
        exec "$APP" --follow-capture "$FILE" --poll "$POLL"
        ;;
    --keys)
        # 打印按键诊断日志（遥控器发了什么 / 我们发了什么）
        LOG=/tmp/iprc-keys.log
        if [[ ! -f "$LOG" ]]; then
            echo "还没有按键记录。按住遥控器按键按几下再看。"
            exit 0
        fi
        echo "== 最近 40 条按键记录 =="
        tail -40 "$LOG"
        echo
        echo "== 统计 =="
        /usr/bin/python3 - <<'PY'
import collections, re
lines = open('/tmp/iprc-keys.log', encoding='utf-8', errors='replace').read().splitlines()
recv = [l for l in lines if '|按下' in l]
emit = [l for l in lines if '准备发出' in l]
print(f"  遥控器按键报告：{len(recv)} 条   我们发出按键：{len(emit)} 次")
unknown = collections.Counter(re.findall(r'按下 0x([0-9A-F]{2}) ❌未映射', '
'.join(lines)))
if unknown:
    print("  ❌ 未映射的 usage（遥控器发了、但我们不认识）：", dict(unknown))
PY
        ;;
    --input)
        case "${2:-}" in
            bh|blackhole) exec "$APP" --input-blackhole ;;
            mic)         exec "$APP" --input-restore ;;
            *)           exec "$APP" --input-status ;;
        esac
        ;;
esac

echo "== IPRC1000 语音输入 · 状态 =="
echo
echo "① App 是否在跑"
if pgrep -f "IPRC1000Adapter" >/dev/null; then
    echo "   ✅ 运行中"
else
    echo "   ✗ 未运行（语音不会有声音）→ 打开：/Applications/IPRC1000 Adapter.app"
fi
echo
echo "② HCI 追踪开关（没有它收不到任何包）"
if defaults read "$DEBUG_DOMAIN" HCITraces >/dev/null 2>&1; then
    echo "   ✅ 已开启"
else
    echo "   ✗ 未开启 → 执行： ./enable-hci-trace.sh"
fi
echo
echo "③ 实时状态（来自 App 每 2 秒写出的 /tmp/iprc-status.json）"
if [[ -f /tmp/iprc-status.json ]]; then
    /usr/bin/python3 - <<'PY'
import json
s = json.load(open('/tmp/iprc-status.json'))
acc = {0: "已授权", 1: "已拒绝", 2: "未决定"}.get(s.get("inputMonitoring"), "?")
print(f"   更新时间 {s.get('updatedAt')}")
print(f"   输入监控权限：{acc}   辅助功能：{'已授权' if s.get('accessibility') else '未授权'}")
print(f"   HCI 收包：{s.get('hciPackets', 0)} 个 / {s.get('hciBytes', 0)} 字节")
print(f"   抠出音频帧：{s.get('hciFramesFound', 0)}   已解码：{s.get('audioFrames', 0)} 帧"
      f" = {s.get('audioSeconds', 0)} 秒")
print(f"   到达延迟：平均 {s.get('hciAgeMsAvg',0)} ms / 峰值 {s.get('hciAgeMsMax',0)} ms"
      f"（包到主机 → App 拿到）")
if s.get("outStarted"):
    print(f"   输出缓冲：{s.get('outBufferedMs',0)} ms 积压 + {s.get('outDeviceBufferMs',0)} ms 设备缓冲"
          f" = 附加 {s.get('outAddedMs',0)} ms")
    print(f"   断音(欠载) {s.get('outUnderruns',0)} 次，丢样本 {s.get('outDroppedFrames',0)} 个")
if s.get("hciFramesFound", 0) == 0:
    print("   ℹ️ 还没有音频帧 —— 音频只在按住【麦克风键】时才出现，按住说句话再看。")
else:
    print("   ✅ 音频正在流进 BlackHole 2ch")
PY
else
    echo "   ✗ 没有状态文件（App 没在跑？）"
fi
echo
echo "④ 系统默认输入（输入法用的是它）"
"$APP" --input-status
echo
echo "如果上面都正常，按住遥控器麦克风键说话，输入法就应该能识别。"
