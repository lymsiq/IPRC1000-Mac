# macOS 语音输入实现说明（IPRC1000）

> ## ✅ 真机实测最终结论（2026-10-15 晚 · macOS 26.6.2 / 25G83 · IPRC1000 0A5C:8502）
>
> **遥控器的麦克风音频已经在 macOS 上抓到了 —— 而且不需要 Apple 的蓝牙日志描述文件。**
>
> ### 之前为什么失败（两个独立原因，现在都已解决）
>
> 1. **HID 层拿不到（这一条仍然成立，永远走不通）**：设备报告描述符只声明 Report ID 1、
>    最大 9 字节；而音频是 653 字节的 `A1 F7 …` 大报告。macOS 的 IOHIDFamily 严格按
>    描述符解析 → 直接丢弃。所以走 `IOHIDManager` 永远是死的
>    （`histogram={1:…}`、长度全是 9 字节，就是证据）。
> 2. **HCI 抓包通道没开**：`CBPacketLoggerClient`（CoreBluetooth 私有，**macOS 的 ETW 对应物**）
>    能 `activate` 成功，但 bluetoothd 以 **"Bluetooth Profile Required"** 拒绝投递数据 →
>    回调里 **0 个包**。
>
> ### 破解方式：打开 bluetoothd 的调试追踪
>
> 思路来自开源项目 **`luobosibing2/codex-siri-remote`**（做的正是「让遥控器当麦克风」），
> 键名已在本机 `strings /usr/sbin/bluetoothd` 中**逐字验证真实存在**
> （`HCITraces` / `HCISkipAuth` / `RawAudioTrace` / `HIDTrace` / `HCILiveTraces` /
> `HCIFileTraces`，以及闸门 `RequireEntitlementAndProfileOnInternalForLogging`）：
>
> ```sh
> # 本仓库已封装： ./enable-hci-trace.sh   （管理员，完全可逆）
> defaults write /Library/Preferences/com.apple.MobileBluetooth.debug HCITraces -dict \
>     StackDebugEnabled -bool true HCISkipAuth -bool true \
>     RawAudioTrace   -bool true HIDTrace    -bool true \
>     HCILiveTraces   -bool true HCIFileTraces -bool true
> defaults write /Library/Preferences/com.apple.MobileBluetooth.debug HCISkipAuth -bool true
> killall -9 bluetoothd        # ⚠ SIGUSR1(-30) 不足以重载，必须真正重启 bluetoothd
> ```
>
> **A/B 实测（同机同设备）**：
>
> | 检查项 | 开启前 | 开启后 |
> |---|---|---|
> | `BluetoothReporter --dumpPacketLog` | **0 字节** | **25972 字节** |
> | `CBPacketLoggerClient` 流式回调 | 连上但 **0 包** | **收到包** ✅ |
>
> ### 音频帧格式（真机实测，修正了 Windows 记录里的一处错误）
>
> HCI 流里每条音频记录 = **21 字节记录头 + 653 字节 HID 报告**（报文总长 674 字节）。
> 其中 653 = **13 字节帧头 + 640 字节 PCM**（320 个 int16 LE @16 kHz，即 20 ms/帧）。
>
> 帧头 13 字节：
> ```
> A1 F7 01 <seq> 00 <rolling> <n> <cnt> 00 00 00 40 01
> ```
> - `seq`：帧序号 0,1,2,…
> - `rolling`：**滚动计数器**（0x42, 0x82, 0xC2, 0x02 … 每帧 +0x40）
> - `cnt`：0, 9, 18, 27 …（每帧 +9）
>
> ⚠️ **Windows 适配器记录的固定 `…00 81 00…` 是错的** —— 第 5 字节逐帧在变。
> 照抄它会导致**一帧都匹配不上**（这正是本机 `--hci-stream` 一直报「音频帧 0」的根因）。
> 正确做法：只用**恒定**特征 `A1 F7 01` + `[4]==0` + 尾部 `00 00 00 40 01`。
>
> ### 已跑通的链路（单进程）
>
> ```
> ./enable-hci-trace.sh        → bluetoothd 开始吐 HCI 流
>   → App：CBPacketLoggerClient 私有流式回调      ← 不需要 PacketLogger、不需要描述文件
>   → 扫签名 A1 F7 01 → 取 640 字节 PCM
>   → BlackHole 2ch（虚拟麦克风）
> ```
>
> 用真机抓到的数据离线验证：**110 帧 → 2.20 秒 @16 kHz，RMS 356，46/110 帧非静音**
> （成品见仓库根目录 `voice-capture.wav`）。
>
> **注意：音频只在遥控器麦克风键被按住时才会出现在流里**，松开就停。

---

## 延迟（2026-10-15 第二轮实测与优化）

「感觉慢」是可以量化的。链路拆成四段，各自独立测量：

| 环节 | 优化前 | 优化后 | 怎么测的 |
|---|---|---|---|
| ① 包到主机 → App 拿到 | **53 ms** | **2–3 ms** | HCI 记录头自带到达时间戳，回调里相减 |
| ② App 自己的解码/重采样 | ~0 ms | ~0 ms | 回调进入/退出计时（`hciProcessMsMax`） |
| ③ 抖动缓冲 + 设备缓冲 | 60 + 5 ms | **40 + 5 ms** | 环形缓冲积压 + `kAudioDevicePropertyBufferFrameSize` |
| ④ 蓝牙链路 + 输入法 ASR | 平台固有 | 平台固有 | 不可控 |
| **我们可控的合计** | **118 ms** | **≈ 47 ms** | |

### ① 的元凶：`EnablePerPacketLogging`
A/B 实测（同机同设备）：

| HCITraces 配置 | 到达延迟（平均 / 峰值） | 包量 |
|---|---|---|
| 含 `EnablePerPacketLogging` + `HCIFileTraces` | 53 / 71 ms | 正常 |
| **去掉这两个** | **2 / 15 ms** | **正常（不减）** |

逐包记录让 bluetoothd 做了大量额外工作，**白白多出 50 ms**。
所以 `enable-hci-trace.sh` 里**刻意不加回它们**。

另外把 `CBPacketLoggerClient` 的回调队列从 `DispatchQueue.main` 换成
独立的 `.userInteractive` 串行队列 —— 主队列还跑着 App 的 UI、0.2 s 的 tick 和
2 s 的状态写入，会把包堵在后面（峰值从 71 ms 降到 56 ms 的那一步就是它）。

### ③ 抖动缓冲：必须有，但要有界
实测帧到达间隔：**中位数 24 ms，最小 3 ms，最大 50 ms**（成簇到达），
而虚拟声卡按稳定时钟拉取。原实现是无上限的 5 s 环形缓冲 → 积压会变成成百毫秒延迟。
现在：
- 起播前攒够 **40 ms** 才出声（防一上来就断音）；
- 积压超过 **64 ms** 就把最旧的丢掉（把「越来越慢」换成「偶尔丢一点」）；
- 距上次写入 > 0.4 s 视为新会话 → 清空重来，避免上一段的积压带进新会话；
- 设备 IO 缓冲从默认 512 帧降到 **256 帧**（10.7 ms → 5.3 ms）。

### ④ 剩下的延迟不归我们
蓝牙链路本身（遥控器采集 + 传输）和输入法的语音识别缓冲都在我们之外。
**判断方法**：把默认输入切回内置麦克风（`./voice-input.sh --input mic`），
对着同一个输入法说话 —— 如果延迟"感觉差不多"，那剩下的主要就是输入法本身的识别缓冲；
如果明显更快，那差值就是我们这条链路（当前约 47 ms）。

自查命令：`./voice-input.sh`（会直接打印 ①②③ 的实时数字）。


>
> ### 另外两条路也已实测排除（2026-10-15）
>
> **① 自己当 HID 主机（IOBluetooth 直开 L2CAP 通道）—— 行不通。**
> 写了 `Sources/IPRC1000Adapter/L2CAPProbe.swift`（`--l2cap-probe`）实测：
> - 设备已连接时：`openL2CAPChannelSync(PSM 0x13 / 0x11)` 返回 `-536870212`（非标准 IOKit 码）→ 失败
> - 先 `closeConnection()` 再抢：返回 `-536870186`（`kIOReturnTimeout`）→ 失败
> - 结论：**bluetoothd 始终占着 HID 通道，系统不肯让出**；断开后又变成"设备离线"。
>
> **② 想不开描述文件就抓包 —— 也不行。**
> 试过系统自带的 `/System/Library/Frameworks/IOBluetooth.framework/Resources/BluetoothReporter --dumpPacketLog`，
> 输出 **0 字节**；再试 `defaults write /Library/Preferences/com.apple.Bluetooth
> BluetoothHCIEnableDebugKeys/BluetoothLogFlags/BluetoothLogLevel` + 重启 bluetoothd，**仍是 0 字节**。
> → **Apple 的蓝牙日志描述文件是硬门槛**（macOS 14.5+ 起）。

---

## 一、原理速查（为什么原版找不到、Windows 版怎么找到的）


原版 macOS 项目（`wangchll/IPRC1000`）只做了按键映射，语音**没实现**。作者在
`docs/VOICE_EXPERIMENT_NOTES.md` 里把 BLE HOGP、Android TV Voice、RFCOMM、自定义
L2CAP 都试了一遍，结论是「找不到音频」。

但 Windows 版（`lymsiq/IPRC1000-Adapter`）**真机逆向了音频的真实位置**，两边一对照就清楚了：

| | macOS 原版找的地方 | 音频实际所在 |
|---|---|---|
| 通道 | BLE GATT 服务 `0x1812` / Android TV Voice | **Bluetooth Classic HID 中断通道** |
| 报告 | 猜的 F7/F8（但要走 BLE 通知） | **确实是报告 ID `0xF7`**，但走 **Classic HID** |
| 编码 | 猜 mSBC / IMA-ADPCM | **未压缩 16-bit LE PCM**（不是 mSBC！） |

**音频帧格式（Windows 真机逐字节确认）：**

```
L2CAP 负载 653 字节
┌────────────── 13 字节帧头 ──────────────┬──── 640 字节音频 ────┐
A1 F7 01 <seq> 00 81 00 <cnt> 00 00 00 40 01    320 × int16 LE @16kHz
└A1=input报告 └F7=报告ID                          = 20 ms/帧，约 50 帧/秒
```

ACL 上被拆成两片：首片 `dlen=344`（含 4 字节 L2CAP 头）+ 续片 `dlen=313`。

> 注意：640 字节**不是** 57 的整数倍，所以它不是 mSBC —— 项目里那个 `libsbc`
> 是为 BLE 路线准备的，对这只遥控器用不上。这也解释了 macOS 作者为什么一直解不出来。

**因此 macOS 侧完全不需要额外硬件/驱动**，只要能从 HID 层拿到 `0xF7` 报告，
就能解出 PCM，再灌进 **BlackHole** 虚拟声卡当麦克风。

---

## 二、方案 A：HID 直读 —— ❌ 真机实测**不可行**

`Sources/IPRC1000Adapter/VoiceHIDBridge.swift` 已按 Windows 版逆向出的帧格式实现：
订阅遥控器 HID 报告 → 命中 `0xF7` → 解出 320 个样本 → 高通 → 交给
`BlackHoleOutput`（16k→48k 重采样 → 写入 BlackHole 2ch）。

**但真机实测证明 macOS 不会把这个报告交上来**（证据见文首结论）。
判定方法（已内建，无需真机也能自查）：

```sh
cd <本仓库目录> && ./status.sh
```

| 状态文件里的字段 | 含义 |
|---|---|
| `histogram = {1: N}` | 只收到报告 ID 1；**没有 247(=0xF7)** |
| `lengthHistogram = {9: N}`、`maxReportLength = 9` | 收到的报告**全是 9 字节**，音频帧(653B)从未出现 |
| `descriptor` | 设备报告描述符，可解码确认只声明了 Report ID 1 |

只要 `maxReportLength` 一直是 9，方案 A 就无解 —— 必须走方案 B。

---

## 三、方案 B：**流式订阅** bluetoothd 的包流（= macOS 版的 ETW）

> 这一节回答「Windows 用 ETW 流式拿蓝牙数据，macOS 用什么」。

**对应关系**

| Windows | macOS |
|---|---|
| `BthPort` ETW 实时会话（`ferrisetw` 订阅 provider） | **`CBPacketLoggerClient`**（CoreBluetooth 私有类） |
| 回调里直接拿到 ACL 字节 | `setRawPacketHandler:` 回调 |
| 需要管理员权限 | 需要 Apple 的**蓝牙日志描述文件** |

**怎么找到的**：写了运行时探针（`dlopen` CoreBluetooth/IOBluetooth + `objc_copyClassNamesForImage`
+ `class_copyMethodList`），扫出与抓包相关的类与方法，命中：

```
[CBPacketLoggerClient]  共 21 个方法
    setDispatchQueue:           必须
    setRawPacketHandler:        ← 收包回调（流式！）
    activateWithCompletion:     ← 启动
    setErrorHandler: / setInterruptionHandler: / setInvalidationHandler:
    invalidate
[CBManager]
    sendRawCommand:data:completionHandler:   ← 能「发」HCI 原始命令
```

**已实装**：`Sources/IPRC1000Adapter/HCIStreamCapture.swift`

```sh
IPRC1000Adapter --hci-stream            # 或直接 ./voice-input.sh
```

它 activate 到 bluetoothd，收到包后**不管包是什么格式**，直接在字节流里搜音频帧签名
（`A1 F7 01 … 00 81 00 … 00 00 00 40 01`）并抠出 640 字节 PCM → 写 BlackHole；
同时兼容「连续 653 字节」和「344 + 4 字节 ACL 头 + 313」两种布局。**不需要 PacketLogger。**

**实测结论（重要）**：

```
✅ 已连上 bluetoothd 抓包通道（流式）
包 0  共 0 B  音频帧 0
```

**通道能连上、零错误，但收不到任何包 —— 说明数据本身被 Apple 的蓝牙日志描述文件锁着。**
装上描述文件后这个模式应该直接可用（届时连 PacketLogger 都不用开）。

> 顺带排除的其它「直连」路子（都不行）：
> `IOBluetoothHostController` 只有 RSSI/链路质量，没有原始 HCI；
> 开 `com.apple.Bluetooth` 的 debug keys + `log config` 也拿不到包内容；
> 自己用 `IOBluetoothDevice.openL2CAPChannelSync` 抢 HID 通道被 bluetoothd 挡住
> （`kIOReturnTimeout`，见 `--l2cap-probe`）。

---

## 四、方案 B2：跟随 PacketLogger 的抓包文件（兜底，已自测通过）

如果流式模式装上描述文件后仍然收不到包，就用这条：

```sh
cd <本仓库目录>
./voice-input.sh /tmp/iprc.pklg      # 即 IPRC1000Adapter --follow-capture /tmp/iprc.pklg
```

App 自己 tail PacketLogger 正在写的 btsnoop 文件 → 增量解析 → 重组 344+313 分片 →
抠 PCM → 写 BlackHole。**单进程，无 Python、无 UDP。**

「跟随 → 解析 → 写 BlackHole」这段**已用合成抓包端到端自测**：边写边解，
`ACL包 == 2 × 音频帧`，**写进去多少帧就解出多少帧，不丢帧**。
未验证的只是 PacketLogger 是否边录边落盘。

---

---

## 方案 C（推荐，立刻可用，不需要任何额外软件）

既然拿不到遥控器自己的麦克风，那就**让遥控器当"语音键"，用电脑自带麦克风说话**：

1. 遥控器**麦克风键默认已经映射为 `Fn`**（本项目已改，见 `MappingStore.defaults`）
   —— 正好对上**豆包输入法**的默认语音键。
2. 在豆包里把语音键确认为 `Fn`，然后：
   **按住遥控器麦克风键 → 对着电脑说话 → 松开**，文字就落到光标处。

这样就得到了「遥控器一键语音输入」的完整体验，只是收音用的是 Mac 的麦克风而不是遥控器的。

> 想改成 macOS 自带听写也行：系统设置 → 键盘 → 听写 → 打开并设自定义快捷键（如 `⌃⌥D`），
> 再把 App「按键映射」页里的**麦克风**键改绑成该组合键。

---

## 四、让「遥控器话筒」变成系统麦克风

### 1. 装 BlackHole（免费的虚拟声卡）

```sh
brew install --cask blackhole-2ch
```

装完在「系统设置 → 声音 → 输入」里应能看到 **BlackHole 2ch**。
（本 App 会自动把解出的音频写进它，无需手动配置。）

### 2. 把系统输入切到 BlackHole

系统设置 → 声音 → 输入 → 选 **BlackHole 2ch**。

> ⚠️ BlackHole 是纯回环设备，**不含真实麦克风的直通**，所以在切到 BlackHole 期间，
> 你的笔记本自带麦克风会「静音」。这和 Windows 版把默认录音设备设成 `CABLE Output`
> 是同一个取舍。
>
> 想两者兼得：在「音频 MIDI 设置」里新建一个**聚合设备**，勾选
> `BlackHole 2ch` + `MacBook 麦克风`，再把它设为输入。

### 3. 把遥控器麦克风键映射到「听写」快捷键

系统设置 → 键盘 → 听写 → 打开，并把快捷键设为「自定义」，例如 `⌃⌥D`；
然后在 App 的「按键映射」页把遥控器的 `麦克风` 键映射为 `⌃⌥D`。
之后：按一下麦克风键开始听写 → 对着遥控器说话 → 再按一下结束。
（听写会把识别结果直接打到你当前光标处，效果等同于豆包输入法的「长按说话」。）

---

## 五、与 Windows 版的对应关系

| Windows 版 | macOS 版（本项目） |
|---|---|
| BthPort ETW 抓 L2CAP | IOHID 报告回调（方案 A） |
| etw_consumer.exe（Rust 语音桥） | `VoiceHIDBridge.swift`（内置，无需额外进程） |
| 16k→48k 内插 + 70 Hz 高通 | `BlackHoleOutput` 重采样 + 同参数高通 |
| VB-CABLE 虚拟声卡 | **BlackHole 2ch** |
| 注入右 Alt 触发豆包长按 | 映射麦克风键到 macOS「听写」快捷键 |
| 设备驱动切到非键盘 | 不需要（macOS 不做驱动切换） |

---

## 六、权限与排障

**必需权限**（系统设置 → 隐私与安全性）：
- **输入监控**：读取遥控器 HID 报告（方案 A 必需）。
- **辅助功能**：发送映射后的按键（按键功能必需）。
- 蓝牙：让 App 能看到遥控器。

**排障清单**

| 现象 | 处理 |
|---|---|
| `--voice-diag` 完全没有任何报告 | 遥控器没连上 / 没给输入监控权限 |
| 只有 Report 1、没有 F7 | 走方案 B 验证；说明 IOHID 层吞了超大报告 |
| 音频帧在涨但听不到 | 没装 BlackHole，或系统输入没切到 BlackHole 2ch |
| 声音断断续续 | 蓝牙链路抖动；靠近遥控器、减少 2.4G 干扰 |
| 听写不触发 | 听写没开 / 快捷键没设成自定义 / 没给辅助功能权限 |

---

## 七、遥控器原始键值泄漏（打出 `i` / `m`）的根治

**现象**：按遥控器 **UP** 会打出字母 `i`；按**语音键**会打出 `m` 且**一直重复、不弹起**。

**原因**：遥控器对 macOS 而言就是一只**蓝牙键盘**。它的原始 HID usage 会被系统键盘驱动
直接翻成真实按键送进前台 App：

| 遥控器键 | 原始 usage | macOS 翻成 | 虚拟键码 |
|---|---|---|---|
| UP（以及松键时多吐的杂散报告） | `0x0C` | `i` | 34 |
| 语音键 | `0x10` | `m` | 46 |

原项目试图用 `RemoteEventFilter`（CGEvent 时间戳关联）事后拦截，有两个致命问题：

1. **时间戳单位不匹配**：`IOHID` 报告回调给的是 **mach 绝对时间（tick）**，
   而 `CGEvent.timestamp` 是**纳秒**。Apple Silicon 上两者差 `timebase` 因子
   （125/3 ≈ 41.67）。原来直接相减 + 容差 2 ms ⇒ **永远匹配不上** ⇒ 拦截完全失效。
   → 已修：`closestDistance()` 同时按两种单位关系比对，并把容差放宽到 20 ms。
2. **语音键在收音期间持续上报同一个 usage**，系统就一路自动重复；只要第一次
   keydown 没被拦下，后面每个 repeat 都不会被拦（因为 `suppressedDownKeyCodes`
   里根本没有它）—— 这就是「一直出 `m` 不弹起」。

**根治**：`HIDController` 现在以 `kIOHIDOptionsTypeSeizeDevice` **独占**该设备，
macOS 不再把它当键盘 ⇒ 原始键值根本不会进系统。等价于 Windows 版把驱动从
“HID Keyboard Device” 切成 “HID-compliant device”。

> 前提是「输入监控」权限。若独占失败会自动回退为普通打开，此时靠上面修好的
> 事件过滤兜底。App 的连接状态文案会告诉你走的是哪条路：
> 「已连接并独占…」= 独占成功。

**副作用**：独占期间**退出 App**，遥控器会重新被系统当成键盘（`i`/`m` 又回来）。
想彻底避免就保持 App 常驻。

**验证方法**：连上遥控器后，随便打开一个文本编辑器，依次按 UP / 语音键 ——
不应该再出现任何字符。

---

## 八、代码位置

| 文件 | 作用 |
|---|---|
| `Sources/IPRC1000Adapter/VoiceHIDBridge.swift` | **语音桥**：HID → 帧解析 → 高通 → PCM |
| `Sources/IPRC1000Adapter/HIDController.swift` | 独占设备 + 原始报告分发（含 `onRawReport`） |
| `Sources/IPRC1000Adapter/RemoteEventFilter.swift` | 时间戳关联修正 + CGEvent 拦截兜底 |
| `Sources/IPRC1000Adapter/BlackHoleOutput.swift` | 原项目已有：PCM → BlackHole 虚拟声卡 |
| `Sources/IPRC1000Adapter/DiagnosticRunner.swift` | `--voice-diag` 诊断 + WAV 导出 |
| `tools/iprc_voice_extract.py` | 方案 B：从 PacketLogger 抓包提取音频 |
