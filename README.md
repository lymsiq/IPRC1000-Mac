# IPRC1000 · macOS 遥控器语音输入与按键映射

把 **IPRC1000（Broadcom 蓝牙语音遥控器，`0A5C:8502`）** 接到 macOS 上：
**遥控器自己的麦克风变成系统麦克风**（输入法 / 听写直接用），同时支持**按键映射与组合键注入**。

> **不需要 Apple 开发者账号、不需要蓝牙日志描述文件、不需要 PacketLogger。**

---

## 功能

| 能力 | 状态 |
|---|---|
| 遥控器**本机麦克风** → 系统麦克风（BlackHole 2ch） | ✅ 已实测 |
| 按键映射：方向键 / 媒体键 / 任意组合键 / 多配置组 | ✅ |
| 麦克风键 → `Fn`（对口豆包输入法等） | ✅ 默认 |
| 免 Apple 蓝牙日志描述文件抓取音频 | ✅ 核心成果 |
| 附加延迟（软件侧可控部分） | ≈ 47 ms |

---

## 大概流程

```
bluetoothd（打开 HCI 追踪）
   ↓  HCI 流
App：CBPacketLoggerClient 收包 → 定位 653 字节音频帧 → 解出 PCM
   ↓
BlackHole 2ch 虚拟声卡 → 系统默认输入 → 输入法 / 听写

按键：遥控器 HID 报告 → 映射表 → 注入组合键
```

---

## 快速开始

```sh
# ① 一次性：打开 bluetoothd 的 HCI 追踪（需要管理员密码，完全可逆）
./enable-hci-trace.sh

# ② 编译打包 App（首次需要；需 Xcode Command Line Tools）
( cd macos-app && zsh scripts/package-app.sh )

# ③ 安装（会顺带装 BlackHole 虚拟声卡）
./install.sh

# ④ 打开 App（常驻菜单栏），并授权「输入监控」「辅助功能」
open -a "IPRC1000 Adapter"

# ⑤ 把系统默认输入切到 BlackHole 2ch
./voice-input.sh --input bh
```

然后**按住遥控器麦克风键说话**，输入法即可识别。

### 常用命令

```sh
./voice-input.sh                 # 体检：权限 / 收包 / 解码帧数 / 延迟 / 默认输入
./voice-input.sh --keys          # 按键诊断日志
./voice-input.sh --input mic     # 默认输入切回内置麦克风
./voice-input.sh --mapping       # 打印当前生效的按键映射
./disable-hci-trace.sh           # 还原 ① 的改动

APP="/Applications/IPRC1000 Adapter.app/Contents/MacOS/IPRC1000Adapter"
"$APP" --reconnect               # 遥控器"连上了但按键没反应"时重连（自动重试）
"$APP" --self-test               # 内置自检
```

---

## 几个关键点

- **音频只能从 HCI 层拿**：设备报告描述符只声明 9 字节输入，653 字节的音频报告会被 macOS 丢弃。
- **免描述文件**：写 `com.apple.MobileBluetooth.debug` 的 `HCITraces`+`HCISkipAuth` 后重启 `bluetoothd`。
  不要开 `EnablePerPacketLogging`（会让延迟从 2 ms 涨到 53 ms）。
- **帧格式**：`13 字节帧头 + 640 字节 PCM`（320 × int16 LE @16 kHz），匹配只用恒定特征
  （帧头第 5 字节是滚动计数器，网上流传的固定 `0x81` 是错的）。
- **组合键必须真的按下修饰键**（`.flagsChanged`），否则部分应用不认。
- 遥控器会自动休眠断连；"显示已连接但按键全无效" = HID 通道没建起来 → `--reconnect`。

更详细的原理与实测结论见 `macos-app/docs/MACOS_VOICE.md`。

---

## 目录结构

```
├── enable-hci-trace.sh / disable-hci-trace.sh   打开/还原 HCI 追踪
├── install.sh                                   一键安装（App + BlackHole）
├── voice-input.sh                               体检 / 按键日志 / 切换输入 / 调试
├── status.sh                                    轻量体检
└── macos-app/                                   完整可编译源码（Swift）
    ├── Sources/IPRC1000Adapter/
    │   ├── HCIVoiceReceiver.swift               HCI 流 → 音频帧
    │   ├── VoiceHIDBridge.swift                 解码 → 滤波 → BlackHole
    │   ├── BlackHoleOutput.swift                有界抖动缓冲 + 虚拟声卡输出
    │   ├── HIDController.swift                  按键通道 + 诊断日志
    │   ├── KeyEmitter.swift                     按键注入（含组合键）
    │   ├── AudioInputSwitcher.swift             切换系统默认输入设备
    │   └── ...
    ├── docs/MACOS_VOICE.md                      原理与实测结论文档
    └── tools/iprc_voice_extract.py              离线从抓包提取音频
```

自行编译：`macos-app/scripts/package-app.sh`（可用 `setup-local-signing.sh` 生成自签名身份，
权限不会因重装失效）。

---

## 已知限制

- 依赖未公开的蓝牙调试键，系统更新后可能失效。
- `killall -9 bluetoothd` 会让蓝牙设备短暂断开几秒（会自动回连）。
- 默认输入切到 BlackHole 后，内置麦克风不再是默认输入（`--input mic` 切回）。
- 需要管理员权限（改蓝牙调试偏好）。

---

## 致谢 / 许可

- 上游 macOS 项目：[`wangchll/IPRC1000`](https://github.com/wangchll/IPRC1000)（MIT）
- Windows 语音适配器（帧格式参考）：[`lymsiq/IPRC1000-Adapter`](https://github.com/lymsiq/IPRC1000-Adapter)
- 免描述文件打开 HCI 抓包的思路：[`luobosibing2/codex-siri-remote`](https://github.com/luobosibing2/codex-siri-remote)
- 虚拟声卡：[`ExistentialAudio/BlackHole`](https://github.com/ExistentialAudio/BlackHole)

本项目沿用上游 **MIT License**（见 `macos-app/LICENSE`），第三方组件见 `macos-app/NOTICE.md`。
