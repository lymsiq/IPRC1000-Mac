import CoreAudio
import Foundation
import IOKit.hid
import os

/// macOS 侧「语音桥」。
///
/// 原版 macOS 项目只走了 BLE（HOGP 0x1812 / Android TV Voice）路线，作者在
/// `docs/VOICE_EXPERIMENT_NOTES.md` 里承认**没在 Classic 通道上找到音频**。
/// 而 Windows 适配器（lymsiq/IPRC1000-Adapter）真机抓包证明了音频的真实位置：
///
///   · 遥控器是一个 **Bluetooth Classic HID** 设备（VID/PID 0A5C:8502）
///   · 按住【麦克风键】时，音频和键盘报告**复用同一条 HID 中断通道**
///   · 音频帧 = 653 字节 L2CAP 负载 = **13 字节帧头 + 640 字节音频**
///     640 字节 = 320 个 int16 LE 样本 @ 16 kHz（即 20 ms 一帧，约 50 帧/秒）
///   · 帧头固定为 `A1 F7 01 <seq> 00 81 00 <cnt> 00 00 00 40 01`
///     —— `A1` 是 HID 输入报告头，**`F7` 就是报告 ID 0xF7**（正是原本猜测的那个 F7！）
///
/// 因此 macOS 侧不需要任何额外设备/驱动：只要 IOHID 层把 0xF7 的报告交上来，
/// 我们就能解出 PCM，再用 `BlackHoleOutput` 灌进 BlackHole 虚拟声卡当麦克风用。
///
/// 注意：本机 HID 报告描述符只声明了 Report ID 1（最大 9 字节输入）。0xF7 是**超大且未声明**
/// 的报告，macOS 的 IOHIDFamily 有可能会把它截断或丢弃 —— 这正是需要真机实测确认的一点。
/// 所以本类内置了完整的**报告诊断日志**，`--voice-diag` 会逐条打印收到的原始报告。
final class VoiceHIDBridge: @unchecked Sendable {
    private static let logger = Logger(subsystem: "local.iprc1000.adapter", category: "VoiceBridge")

    // MARK: - 对外回调（与原 VoiceController 接口保持一致）

    var onStatus: @Sendable (String, Bool) -> Void = { _, _ in }
    var onLevel: @Sendable (Float) -> Void = { _ in }
    /// 诊断用：每收到一条原始报告都会回调（reportID, 长度, 前 32 字节, 时间戳）
    var onRawReport: (@Sendable (Int, Int, [UInt8], UInt64) -> Void)?
    /// 诊断用：解码出的一帧 16 kHz PCM（用于写 WAV）
    var onDecodedFrame: (@Sendable ([Int16]) -> Void)?
    /// 语音会话结束（一段时间没有音频帧）时回调。
    /// 遥控器语音键不会上报"松手"，所以用它来补一个释放动作。
    var onSessionEnd: (@Sendable () -> Void)?

    // MARK: - 常量（对齐 Windows 逆向后确认的帧格式）

    /// 13 字节帧头 + 640 字节音频
    private static let audioPayloadBytes = 640
    /// 320 个 int16 LE @ 16 kHz = 20 ms
    private static let samplesPerFrame = 320
    private static let sampleRate = 16000.0
    /// 帧头里用于自适应定位音频起点的固定标记
    private static let headerTail: [UInt8] = [0x00, 0x00, 0x00, 0x40, 0x01]
    /// 无帧多久算一次会话结束（与 Windows 端一致）
    private static let idleEndSeconds = 0.6

    // MARK: - 状态

    /// 自有 HID 管理器。**App 内运行时为 nil** ——
    /// 因为 `HIDController` 会以「独占（seize）」方式打开设备，同一个设备不能被
    /// 两个管理器同时独占。此时语音桥只是被动解析按键通道转发过来的原始报告。
    /// 只有独立诊断（`--voice-diag`）时才由本类自己开一个管理器。
    private let manager: IOHIDManager?
    private let output = BlackHoleOutput()
    private let lock = NSLock()

    private var lastFrameAt: Date?
    private var inSession = false
    private var level = 0.0
    private var filters: [Biquadish] = []
    private var started = false

    // 统计
    private(set) var reportHistogram: [UInt32: Int] = [:]
    private(set) var audioFrames = 0
    private(set) var samplesProduced = 0
    private(set) var shortAudioReports = 0
    private(set) var audioFillRatio = 0.0
    /// 诊断用：是否匹配到目标设备、打开/独占结果
    private(set) var matchedDevices = 0
    private(set) var openResult: Int32 = -9999
    private(set) var seizeResult: Int32 = -9999
    private(set) var usingOwnManager = false

    /// 与 Windows 端一致的级联一阶高通（2 次级联 = 二阶），去掉直流/低频隆隆声。
    private struct Biquadish {
        var a: Float = 0
        var prevX: Float = 0
        var prevY: Float = 0
        init(cutoff: Float, sampleRate: Float) {
            a = exp(-2 * Float.pi * cutoff / sampleRate)
        }
        mutating func process(_ x: Float) -> Float {
            let y = a * (prevY + x - prevX)
            prevX = x
            prevY = y
            return y
        }
    }

    /// - Parameter ownsManager: `true` 时本类自己开一个 IOHIDManager（独立诊断用）；
    ///   `false` 时**不自带管理器**，只处理外部（`HIDController.onRawReport`）转发来的报告。
    init(ownsManager: Bool = true) {
        manager = ownsManager
            ? IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            : nil
        filters = [
            Biquadish(cutoff: 70, sampleRate: Float(Self.sampleRate)),
            Biquadish(cutoff: 70, sampleRate: Float(Self.sampleRate))
        ]
    }

    deinit {
        if let manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }

    // MARK: - 生命周期

    func start() {
        guard !started else { return }
        started = true

        let audioStatus = output.start()
        if !audioStatus.ok {
            onStatus("语音输出未就绪：\(audioStatus.message)", false)
        } else {
            onStatus("BlackHole 2ch 已就绪，等待遥控器语音…", false)
        }

        // 不自带管理器：报告由 HIDController（已独占设备）转发过来。
        guard let manager else { return }
        usingOwnManager = true

        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: TargetRemote.vendorID,
            kIOHIDProductIDKey as String: TargetRemote.productID
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, voiceHIDMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, voiceHIDRemoved, context)
        IOHIDManagerRegisterInputReportWithTimeStampCallback(manager, voiceHIDReport, context)
        IOHIDManagerScheduleWithRunLoop(
            manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue
        )

        // 诊断模式也优先独占，才能真实反映 App 内运行时系统是否还会打出 i / m。
        seizeResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        if seizeResult != kIOReturnSuccess {
            openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        } else {
            openResult = seizeResult
        }
        if openResult != kIOReturnSuccess {
            onStatus("无法打开遥控器 HID 通道（\(openResult)）；请检查「输入监控」权限", false)
        } else {
            onStatus("等待 IPRC1000（0A5C:8502）语音报告…", false)
        }
    }

    /// 诊断用：枚举当前匹配到的设备（不依赖是否已打开）。
    func matchedDeviceDescription() -> String {
        guard let manager else { return "<无管理器>" }
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              !devices.isEmpty else { return "<0 个匹配设备>" }
        return devices.map { device in
            func number(_ key: String) -> Int {
                (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? -1
            }
            let name = (IOHIDDeviceGetProperty(device, "Product" as CFString) as? String) ?? "?"
            return "\(name)(VID=\(String(number(kIOHIDVendorIDKey), radix: 16)),PID=\(String(number(kIOHIDProductIDKey), radix: 16)),maxIn=\(number(kIOHIDMaxInputReportSizeKey)))"
        }.joined(separator: " | ")
    }

    // MARK: - HID 回调

    fileprivate func matched(_ device: IOHIDDevice) {
        guard TargetRemote.matches(device) else { return }
        matchedDevices += 1
        onStatus("IPRC1000 已连接，等待语音报告", true)
    }

    fileprivate func removed(_ device: IOHIDDevice) {
        guard TargetRemote.matches(device) else { return }
        onStatus("IPRC1000 已断开", false)
    }

    /// 处理一条原始报告。App 内由 `HIDController.onRawReport` 调用；
    /// 独立诊断时由本类自己的 HID 回调调用。
    func handleReport(_ report: [UInt8], reportID: Int, timestamp: UInt64) {
        lock.lock()
        reportHistogram[UInt32(reportID), default: 0] += 1
        lock.unlock()

        onRawReport?(reportID, report.count, Array(report.prefix(32)), timestamp)

        // 只有 0xF7 报告承载音频；但为稳妥，也接受“看起来像音频帧”的其它报告。
        let looksLikeAudio = reportID == 0xF7 || frameAudioOffset(report) != nil
        guard looksLikeAudio else { return }

        guard let offset = frameAudioOffset(report) else {
            lock.lock()
            shortAudioReports += 1
            let ratio = Double(report.count) / 653.0
            if ratio > audioFillRatio { audioFillRatio = ratio }
            lock.unlock()
            Self.logger.error(
                "F7 报告无法定位音频起点：len=\(report.count, privacy: .public) id=\(reportID, privacy: .public)"
            )
            return
        }

        let end = offset + Self.audioPayloadBytes
        guard report.count >= end else {
            lock.lock()
            shortAudioReports += 1
            lock.unlock()
            return
        }

        // 640 字节 = 320 × int16 LE
        var samples = [Int16](repeating: 0, count: Self.samplesPerFrame)
        for index in 0..<Self.samplesPerFrame {
            let low = report[offset + index * 2]
            let high = report[offset + index * 2 + 1]
            samples[index] = Int16(bitPattern: UInt16(low) | (UInt16(high) << 8))
        }

        // 级联高通 + 预热丢帧（与 Windows 端一致，前 2 帧丢弃）
        for index in samples.indices {
            var value = Float(samples[index])
            for filterIndex in filters.indices {
                value = filters[filterIndex].process(value)
            }
            samples[index] = Int16(max(-32768, min(32767, value).rounded()))
        }

        lock.lock()
        audioFrames += 1
        samplesProduced += Self.samplesPerFrame
        let firstFrames = audioFrames <= 2
        if !inSession {
            inSession = true
            Self.logger.notice("语音会话开始（首帧）")
        }
        lastFrameAt = Date()
        lock.unlock()

        guard !firstFrames else { return }

        onDecodedFrame?(samples)
        output.enqueue16kMono(samples)

        let peak = samples.reduce(Int16(0)) { max($0, Int16(clamping: abs(Int($1)))) }
        // level 同时会被主线程的 tick() 读写 —— 统一放到锁里，别裸写
        lock.lock()
        level = Double(peak) / Double(Int16.max)
        let currentLevel = level
        lock.unlock()
        onLevel(Float(currentLevel))
    }

    /// 在一段报告里定位 640 字节音频的起点。
    ///
    /// 帧头（13 字节）：`A1 F7 01 <seq> 00 81 00 <cnt> 00 00 00 40 01`
    ///                                            └── 固定尾部 ──┘
    /// macOS 交上来的 buffer 是否带 `A1 F7` 前缀、是否已剥离报告 ID 都不确定，
    /// 所以用帧头的固定尾部 `00 00 00 40 01`（5 字节）反查，对偏移完全鲁棒：
    /// 命中尾部后，音频必然紧跟其后（13 字节帧头 = 8 字节前缀 + 5 字节尾部）。
    private func frameAudioOffset(_ report: [UInt8]) -> Int? {
        guard report.count >= 13 + Self.audioPayloadBytes else { return nil }
        let limit = min(40, report.count - Self.headerTail.count)
        guard limit >= 0 else { return nil }
        var fallback: Int?
        for marker in 0...limit {
            guard Array(report[marker..<marker + Self.headerTail.count]) == Self.headerTail else {
                continue
            }
            let audioStart = marker + Self.headerTail.count
            guard audioStart + Self.audioPayloadBytes <= report.count else { continue }
            // 帧头里 `<cnt>` 前一位固定是 0x81 —— 命中它说明这确实是帧头而不是巧合。
            if marker >= 3, report[marker - 3] == 0x81 { return audioStart }
            if fallback == nil { fallback = audioStart }
        }
        return fallback
    }

    /// 空闲检测：没有新帧就结束会话（用于把状态/电平归零）。
    func tick() {
        lock.lock()
        let shouldEnd = inSession && (lastFrameAt.map { Date().timeIntervalSince($0) } ?? 0) > Self.idleEndSeconds
        if shouldEnd { inSession = false }
        lock.unlock()
        if shouldEnd {
            lock.lock()
            level = 0
            lock.unlock()
            onLevel(0)
            onSessionEnd?()
        }
    }

    /// 音频输出环节的延迟指标（透传给状态文件，用于判断"慢"到底慢在哪一环）
    struct OutputStats {
        let started: Bool
        let bufferedMs: Double
        let deviceBufferFrames: Int
        let deviceBufferMs: Double
        let addedMs: Double
        let underruns: Int
        let droppedFrames: Int
        let peakBufferedMs: Double
    }

    func outputStats() -> OutputStats {
        OutputStats(
            started: output.started,
            bufferedMs: output.bufferedMs,
            deviceBufferFrames: output.deviceBufferFrames,
            deviceBufferMs: output.deviceBufferMs,
            addedMs: output.addedLatencyMs,
            underruns: output.underruns,
            droppedFrames: output.droppedFrames,
            peakBufferedMs: Double(output.peakBufferedFrames) / output.sampleRate * 1000
        )
    }

    struct Snapshot {
        let histogram: [UInt32: Int]
        let audioFrames: Int
        let seconds: Double
        let shortAudioReports: Int
        let maxFillRatio: Double
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            histogram: reportHistogram,
            audioFrames: audioFrames,
            seconds: Double(samplesProduced) / Self.sampleRate,
            shortAudioReports: shortAudioReports,
            maxFillRatio: audioFillRatio
        )
    }
}

// MARK: - C 回调桥

private func voiceHIDMatched(_ context: UnsafeMutableRawPointer?, _ result: IOReturn,
                             _ sender: UnsafeMutableRawPointer?, _ device: IOHIDDevice) {
    guard let context else { return }
    Unmanaged<VoiceHIDBridge>.fromOpaque(context).takeUnretainedValue().matched(device)
}

private func voiceHIDRemoved(_ context: UnsafeMutableRawPointer?, _ result: IOReturn,
                             _ sender: UnsafeMutableRawPointer?, _ device: IOHIDDevice) {
    guard let context else { return }
    Unmanaged<VoiceHIDBridge>.fromOpaque(context).takeUnretainedValue().removed(device)
}

private func voiceHIDReport(_ context: UnsafeMutableRawPointer?, _ result: IOReturn,
                            _ sender: UnsafeMutableRawPointer?, _ type: IOHIDReportType,
                            _ reportID: UInt32, _ report: UnsafeMutablePointer<UInt8>,
                            _ reportLength: CFIndex, _ timestamp: UInt64) {
    guard let context else { return }
    let bytes = Array(UnsafeBufferPointer(start: report, count: reportLength))
    Unmanaged<VoiceHIDBridge>.fromOpaque(context).takeUnretainedValue()
        .handleReport(bytes, reportID: Int(reportID), timestamp: timestamp)
}
