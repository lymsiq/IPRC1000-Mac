#!/bin/zsh
# IPRC1000 Adapter 一键体检
#
#   ./status.sh
#
# 读取运行中 App 写的实时状态文件，判断：
#   ① 权限给没给  ② 能不能读到遥控器  ③ 独占了没有  ④ 有没有语音
set -u

f=/tmp/iprc-status.json
if [[ ! -f "$f" ]]; then
    echo "❌ 找不到 $f —— App 没在运行？"
    echo "   请先启动：open -a \"IPRC1000 Adapter\"，等 3 秒再跑本脚本。"
    exit 1
fi

/usr/bin/python3 - "$f" <<'PY'
import json, sys, time

path = sys.argv[1]
with open(path) as fh:
    s = json.load(fh)

acc = {0: "已授权", 1: "已拒绝", 2: "未决定"}.get(s.get("inputMonitoring"), "?")
print(f"状态更新时间：{s.get('updatedAt')}")
print(f"输入监控权限：{acc}   辅助功能：{'已授权' if s.get('accessibility') else '未授权'}")
print(f"独占设备(seize)：{'成功' if s.get('seizureActive') else '未使用'}"
      f"   (seize={s.get('seizeResult')}, open={s.get('openResult')})")

hist = s.get("histogram") or {}
reports = s.get("reports", 0)
print(f"收到的 HID 报告总数：{reports}   按键事件：{s.get('keyEvents', 0)}   直方图：{hist or '<无>'}")
print(f"报告长度分布：{s.get('lengthHistogram') or '<无>'}   最大长度：{s.get('maxReportLength', 0)}")
print(f"泄漏计数（系统真收到的按键）：i={s.get('leakI', 0)}  m={s.get('leakM', 0)}"
      f"  总按键={s.get('leakTotal', 0)}")

vhist = s.get("voiceHistogram") or {}
frames = s.get("audioFrames", 0)
print(f"语音：匹配设备 {s.get('voiceMatchedDevices', 0)} 个，"
      f"解码音频帧 {frames}（约 {s.get('audioSeconds', 0)} 秒）   语音报告直方图：{vhist or '<无>'}")

print()
print("== 结论 ==")
maxlen = s.get("maxReportLength", 0)
if s.get("inputMonitoring") != 0:
    print("❌ 输入监控没授权 —— 第一顺位问题。")
    print("   系统设置 → 隐私与安全性 → 输入监控 → 用 ＋ 添加本 App 并打开开关。")
elif reports == 0:
    print("⚠️ 权限已给，但还没收到任何报告 —— 请按几下遥控器按键再看。")
elif frames > 0:
    print("🎉 语音链路已通！把系统输入切成 BlackHole 2ch，")
    print("   并把遥控器麦克风键映射到「听写」/豆包快捷键即可。")
elif maxlen <= 9 and "247" not in vhist:
    print("❌ **macOS 把音频报告截断/丢掉了**：报告最大长度只有 "
          f"{maxlen} 字节，从没出现 653 字节的 0xF7 音频帧。")
    print("   → 蓝牙 HID 直读这条路走不通，需要走 PacketLogger 抓 HCI（方案 B）。")
    print("   见 macos-app/docs/MACOS_VOICE.md")
else:
    print(f"⚠️ 见过较长的报告（最大 {maxlen} 字节）但没解出音频。")
    print("   请按住遥控器【麦克风键】说话，再看「语音报告直方图」是否出现 247 (=0xF7)。")
PY
