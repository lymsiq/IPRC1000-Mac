import AppKit
import ApplicationServices
import Foundation
import IOKit.hid

@MainActor
final class AppModel: ObservableObject {
    let mappings = MappingStore()

    @Published var hidStatus = "正在启动按键适配…"
    @Published var hidReady = false
    @Published var voiceStatus = "正在启动语音适配…"
    @Published var voiceReady = false
    @Published var voiceLevel: Float = 0
    @Published var lastKey = "—"
    @Published var lastRemoteKey: RemoteKey?

    private let hid = HIDController()
    /// 语音解码 + 输出（高通滤波 → 16k→48k 重采样 → 写 BlackHole 2ch）。
    /// **不自带 HID 管理器**：音频走的是 HCI 流（见 `hciVoice`），不是 HID 报告。
    private let voice = VoiceHIDBridge(ownsManager: false)
    /// **语音数据源**：订阅 bluetoothd 的 HCI 包流，抠出 653 字节的 0xF7 音频帧。
    ///
    /// 必须这样做的原因：遥控器报告描述符只声明 Report ID 1（最大 9 字节），
    /// 653 字节的音频报告会被 macOS 的 IOHIDFamily **直接丢弃** —— 所以
    /// HID 那条路（`hid.onRawReport`）拿不到任何音频，只能走 HCI。
    private let hciVoice = HCIVoiceReceiver()
    /// 泄漏探针：直接量系统有没有把遥控器原始键值（`i`/`m`）当真按键收下。
    /// 它挂在 **session tap** 上，而 App 自己的拦截挂在 **HID tap** 上 ——
    /// 所以被成功拦掉的按键不会出现在这里的计数里，正好用来验证拦截是否生效。
    private let leakProbe = KeyLeakProbe()
    private var started = false
    private var hidStarted = false
    private var heldBindings: [RemoteKey: KeyBinding] = [:]

    func start() {
        guard !started else { return }
        started = true

        hid.onStatus = { [weak self] message, ready in
            Task { @MainActor in
                self?.hidStatus = message
                self?.hidReady = ready
            }
        }
        hid.onKey = { [weak self] key in
            Task { @MainActor in
                guard let self else { return }
                self.lastKey = key.title
                self.lastRemoteKey = key
                if key == .unknown16 {
                    if let profileName = self.mappings.selectNextProfile() {
                        self.lastKey = "已切换：\(profileName)"
                    }
                    return
                }
                let binding = self.mappings.values[key] ?? .none
                if binding.requiresReleaseEvent { self.heldBindings[key] = binding }
                KeyEmitter.emit(binding)
            }
        }
        hid.onKeyRepeat = { [weak self] key in
            Task { @MainActor in
                guard let self else { return }
                guard key != .unknown16 else { return }
                KeyEmitter.emitRepeat(self.mappings.values[key] ?? .none)
            }
        }
        hid.onKeyUp = { [weak self] key in
            Task { @MainActor in
                guard let self else { return }
                guard key != .unknown16 else { return }
                let binding = self.heldBindings.removeValue(forKey: key)
                    ?? self.mappings.values[key] ?? .none
                KeyEmitter.release(binding)
            }
        }
        voice.onStatus = { [weak self] message, ready in
            Task { @MainActor in
                self?.voiceStatus = message
                self?.voiceReady = ready
            }
        }
        voice.onLevel = { [weak self] level in
            Task { @MainActor in self?.voiceLevel = level }
        }
        // 否则映射出来的动作（比如 Fn）会永远卡在按下状态。
        // 遥控器语音键不会上报「松手」，所以用「音频流结束」补一个释放：
        // 否则映射出来的动作（比如 Fn）会永远卡在按下状态。
        voice.onSessionEnd = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if let binding = self.heldBindings.removeValue(forKey: .microphone) {
                    KeyEmitter.release(binding)
                }
                self.hid.forceRelease(usage: RemoteKey.microphone.rawValue)
            }
        }
        // HID 通道拿不到音频（报告描述符只声明 9 字节 → 653 字节报告被系统丢弃），
        // 这条转发只保留作诊断记录；真正的语音数据源是下面的 HCI 流。
        let voiceBridge = voice
        hid.onRawReport = { reportID, report, timestamp in
            voiceBridge.handleReport(report, reportID: reportID, timestamp: timestamp)
        }

        // ★ 真正的语音数据源：从 HCI 流里抠出 653 字节 0xF7 帧 → 语音桥解码 → BlackHole
        hciVoice.onStatus = { [weak self] message, ready in
            Task { @MainActor in
                self?.voiceStatus = message
                self?.voiceReady = ready
            }
        }
        hciVoice.onFrame = { frame in
            voiceBridge.handleReport(frame, reportID: 0xF7, timestamp: 0)
        }

        preparePermissions()
        voice.start()
        hciVoice.start()
        startStatusReporting()
    }

    /// 每 2 秒把运行状态写到 `/tmp/iprc-status.json`。
    ///
    /// 为什么需要：App 是纯菜单栏程序，界面状态拿不到；而用命令行跑诊断时 TCC 权限
    /// 身份会被判给「终端」而不是本 App，结果不可信。写状态文件是唯一能**真实反映
    /// 运行中的 App 到底看到了什么**的手段。
    private func startStatusReporting() {
        let statusPath = "/tmp/iprc-status.json"
        let hid = self.hid
        let voice = self.voice
        let hciVoice = self.hciVoice
        let probe = self.leakProbe
        Task { @MainActor in
            // 空闲检测（语音会话结束 → 补释放麦克风键、把电平归零）
            let tickTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
                voice.tick()
            }
            RunLoop.main.add(tickTimer, forMode: .common)

            let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                // 权限是运行中才授予的 → 自动重新打开设备（省得用户手动重启 App）
                if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted,
                   hid.openResult != kIOReturnSuccess {
                    hid.reopen()
                }
                var out = "{"
                out += "\"updatedAt\":\"\(ISO8601DateFormatter().string(from: Date()))\","
                out += "\"inputMonitoring\":\(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent).rawValue),"
                out += "\"accessibility\":\(AXIsProcessTrusted()),"
                out += "\"reports\":\(hid.reportCount),"
                out += "\"seizureActive\":\(hid.seizureActive),"
                out += "\"eventFilterActive\":\(hid.eventFilterActive),"
                out += "\"leakProbeInstalled\":\(probe.installed),"
                out += "\"openResult\":\(hid.openResult),"
                out += "\"seizeResult\":\(hid.seizeResult),"
                out += "\"keyEvents\":\(hid.keyEventCount),"
                out += "\"maxReportLength\":\(hid.maxReportLength),"
                out += "\"declaredMaxInput\":\(hid.declaredMaxInput),"
                out += "\"descriptor\":\"\(hid.reportDescriptorHex)\","
                out += "\"lengthHistogram\":{"
                out += hid.lengthHistogram
                    .sorted { $0.key < $1.key }
                    .map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",")
                out += "},"
                let leak = probe.rawCounts()
                out += "\"leakTotal\":\(leak.total),\"leakI\":\(leak.i),\"leakM\":\(leak.m),"
                out += "\"lastUsages\":["
                out += hid.lastUsages.map(String.init).joined(separator: ",")
                out += "],"
                out += "\"histogram\":{"
                out += hid.rawReportHistogram
                    .sorted { $0.key < $1.key }
                    .map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",")
                out += "},"
                let vs = voice.snapshot()
                out += "\"voiceMatchedDevices\":\(voice.matchedDevices),"
                out += "\"audioFrames\":\(vs.audioFrames),"
                out += "\"audioSeconds\":\(vs.seconds),"
                out += "\"hciPackets\":\(hciVoice.packets),"
                out += "\"hciBytes\":\(hciVoice.totalBytes),"
                out += "\"hciFramesFound\":\(hciVoice.framesFound),"
                out += "\"hciConnected\":\(hciVoice.connected),"
                out += "\"hciAgeMsLast\":\(Int(hciVoice.ageMsLast.rounded())),"
                out += "\"hciAgeMsAvg\":\(Int(hciVoice.ageMsAvg.rounded())),"
                out += "\"hciAgeMsMax\":\(Int(hciVoice.ageMsMax.rounded())),"
                out += "\"hciProcessMsMax\":\(Int(hciVoice.processMsMax.rounded())),"
                let outputStats = voice.outputStats()
                out += "\"outStarted\":\(outputStats.started),"
                out += "\"outBufferedMs\":\(Int(outputStats.bufferedMs.rounded())),"
                out += "\"outPeakBufferedMs\":\(Int(outputStats.peakBufferedMs.rounded())),"
                out += "\"outDeviceBufferFrames\":\(outputStats.deviceBufferFrames),"
                out += "\"outDeviceBufferMs\":\(Int(outputStats.deviceBufferMs.rounded())),"
                out += "\"outAddedMs\":\(Int(outputStats.addedMs.rounded())),"
                out += "\"outUnderruns\":\(outputStats.underruns),"
                out += "\"outDroppedFrames\":\(outputStats.droppedFrames),"
                out += "\"voiceHistogram\":{"
                out += vs.histogram
                    .sorted { $0.key < $1.key }
                    .map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",")
                out += "}}"
                try? out.write(toFile: statusPath, atomically: true, encoding: .utf8)
            }
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    /// 权限准备。
    ///
    /// ⚠ 原版在「已经弹过窗」时会**直接 return，不启动 HID** —— 后果是：用户若当时
    /// 没去系统设置里勾选，App 会一直静默地收不到任何报告（语音没声音、原始键值也拦不住）。
    /// 现在改成：① 只要权限还是「未决定」就请求一次（保证本 App 出现在
    /// 「隐私与安全性 → 输入监控」列表里）；② **无论权限如何都尝试打开 HID**，
    /// 失败时把错误码写进状态文件，而不是静默什么都不做。
    private func preparePermissions() {
        // 只要没授权就请求一次：macOS 每个 App 只会弹一次窗，重复调用是安全的，
        // 关键是保证本 App 一定出现在「隐私与安全性 → 输入监控」列表里。
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        // 辅助功能：没授权则引导一次系统弹窗（同样每个 App 只弹一次）。
        if !AXIsProcessTrusted() {
            let key = "accessibilityPromptRequested"
            if !UserDefaults.standard.bool(forKey: key) {
                UserDefaults.standard.set(true, forKey: key)
                let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
        }
        startHID()
    }

    private func startHID() {
        guard !hidStarted else { return }
        hidStarted = true
        hid.start()
    }

    /// User-initiated permission action. This is the only path allowed to show a prompt again.
    func requestPermissions() {
        if !AXIsProcessTrusted() {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted:
            startHID()
        case kIOHIDAccessTypeUnknown:
            UserDefaults.standard.set(true, forKey: "inputMonitoringPromptRequested")
            if IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) { startHID() }
        default:
            openPrivacySettings()
        }
    }

    private func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else { return }
        NSWorkspace.shared.open(url)
    }
}
