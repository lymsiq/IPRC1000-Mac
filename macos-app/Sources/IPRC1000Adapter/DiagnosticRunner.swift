import CoreAudio
import CoreGraphics
import Darwin
import Foundation
import IOKit.hid

/// 诊断输出汇聚：同时写 stdout 与报告文件。
///
/// 为什么要写文件：用 `open -n --args` 让 **App 自己**跑诊断时（这样 TCC 权限身份
/// 才属于 App），stdout 拿不到，只能读文件。
final class ReportSink: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?

    func attach(path: String) {
        lock.lock()
        defer { lock.unlock() }
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
        try? handle?.truncate(atOffset: 0)
    }

    func write(_ message: String) {
        let data = Data((message + "\n").utf8)
        FileHandle.standardOutput.write(data)
        lock.lock()
        handle?.write(data)
        lock.unlock()
    }

    func close() {
        lock.lock()
        try? handle?.close()
        handle = nil
        lock.unlock()
    }
}

let diagnosticSink = ReportSink()

/// 语音链路诊断。
///
/// 这是判断「macOS 到底能不能拿到遥控器音频」的**决定性工具**：
/// 它会逐条打印 IOHID 交上来的原始报告（报告 ID、长度、前 32 字节），
/// 并把解码出的 PCM 写成 WAV。
///
/// 用法（先连好遥控器，再按住麦克风键说话）：
///   IPRC1000Adapter --voice-diag 30
///
/// 判读：
///   · 报告直方图里出现 **0xF7 且长度 ~653** → macOS 能拿到音频，语音桥可用。
///   · 只有 `1:9` 之类的小报告、没有任何 F7 → macOS 的 HID 层把超大报告吞了，
///     需要走 PacketLogger 抓 HCI（见 docs/MACOS_VOICE.md 的 B 方案）。
@MainActor
enum VoiceDiagnostic {
    static func run(seconds: Double, verbose: Bool, wavPath: String?,
                    reportPath: String? = nil) -> Int32 {
        if let reportPath { diagnosticSink.attach(path: reportPath) }

        write("== IPRC1000 语音诊断（\(Int(seconds)) 秒）==")
        write("Apple Silicon 建议：先按住遥控器麦克风键说话，再松开；可重复几次。")

        // ── 环境与权限 ──
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        let accessText: String
        switch access {
        case kIOHIDAccessTypeGranted: accessText = "已授权 ✅"
        case kIOHIDAccessTypeDenied: accessText = "已拒绝 ❌（去「隐私与安全性 → 输入监控」勾选本 App）"
        default: accessText = "未知/未决定 ⚠️（首次需要授权并重启 App）"
        }
        write("输入监控权限：\(accessText)")

        let bridge = VoiceHIDBridge()
        let wav = WaveWriter(path: wavPath)
        let counter = FrameCounter()

        bridge.onStatus = { message, ready in
            write("STATUS \(ready ? "READY" : "WAIT"): \(message)")
        }
        bridge.onLevel = { level in
            if level > 0.02 { write(String(format: "LEVEL %.3f", level)) }
        }
        if verbose {
            bridge.onRawReport = { reportID, length, prefix, _ in
                guard length <= 32 else { return }   // 音频帧不逐条打，避免刷屏
                let hex = prefix.map { String(format: "%02X", $0) }.joined(separator: " ")
                write("REPORT id=0x\(String(reportID, radix: 16, uppercase: true)) len=\(length) head=\(hex)")
            }
        }
        bridge.onDecodedFrame = { samples in
            counter.add(samples.count)
            wav.append(samples)
        }

        bridge.start()

        // 泄漏探针：直接量一下遥控器原始键值有没有打进系统（只监听、不修改）。
        let leakProbe = KeyLeakProbe()
        let probeInstalled = leakProbe.start()
        write("泄漏探针：\(probeInstalled ? "已挂载（只监听，不改事件）" : "挂载失败 —— 缺「辅助功能」权限")")
        write(">>> 现在请按住遥控器麦克风键说话，并顺便按几下 UP / 方向键 <<<")

        // 既跑 run loop，又周期性 tick（空闲检测）。
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            bridge.tick()
        }

        wav.finalize()

        let snapshot = bridge.snapshot()
        write("")
        write("== 结果 ==")
        let leak = leakProbe.summary()
        write("系统收到的按键总数：\(leak.total)（含你自己敲的真键盘）")
        if !probeInstalled {
            write("泄漏量：无法测量（探针没挂上，需「辅助功能」权限）")
        } else if leak.watched.isEmpty {
            write("遥控器相关键码被系统收到：**0 次** ✅ —— 原始键值没有泄漏")
        } else {
            write("遥控器相关键码被系统收到（= 泄漏！）：")
            for (label, count) in leak.watched {
                write("   \(label)：\(count) 次")
            }
        }
        write("匹配设备：\(bridge.matchedDeviceDescription())")
        write("匹配回调次数：\(bridge.matchedDevices)")
        write("独占(seize)结果：\(bridge.seizeResult)   实际打开结果：\(bridge.openResult)   (0 = kIOReturnSuccess)")
        let histogram = snapshot.histogram
            .sorted { $0.key < $1.key }
            .map { "0x\(String($0.key, radix: 16, uppercase: true))×\($0.value)" }
            .joined(separator: "  ")
        write("报告直方图：\(histogram.isEmpty ? "<无>" : histogram)")
        write(String(format: "解码音频帧：%d（约 %.1f 秒）", snapshot.audioFrames, snapshot.seconds))
        write("丢弃的短报告：\(snapshot.shortAudioReports)  最大填充率：\(String(format: "%.2f", snapshot.maxFillRatio))")
        if let wavPath, snapshot.audioFrames > 0 {
            write("PCM 已写入：\(wavPath)")
        }

        var code: Int32 = 0
        if snapshot.audioFrames > 0 {
            write("✅ 结论：macOS 能收到 0xF7 音频帧，语音链路可用。")
        } else if access != kIOHIDAccessTypeGranted {
            write("❌ 结论：**输入监控权限没给**，HID 通道根本没打开 —— 这也会导致遥控器原始键值继续打进系统。")
            write("   → 隐私与安全性 → 输入监控 / 辅助功能 勾选「IPRC1000 Adapter」，然后**退出重开 App**。")
            code = 4
        } else if snapshot.histogram.keys.contains(0xF7) {
            write("⚠️ 结论：收到了 0xF7 但长度不足（被 HID 层截断），需进一步处理。")
            code = 2
        } else if !histogram.isEmpty {
            write("❌ 结论：能收到 HID 报告，但**没有任何音频报告** —— macOS 的 IOHID 层没把超大报告交上来。")
            write("   下一步请按 docs/MACOS_VOICE.md 的 B 方案用 PacketLogger 抓 HCI 验证。")
            code = 3
        } else {
            write("❌ 结论：一条 HID 报告都没收到。")
            write("   请确认：① 遥控器已在「系统设置 → 蓝牙」中连接；② 输入监控权限已给并重启过 App。")
            code = 5
        }
        diagnosticSink.close()
        return code
    }

    nonisolated static func write(_ message: String) {
        diagnosticSink.write(message)
    }
}

/// 直接测量「遥控器原始键值有没有泄漏进系统」。
///
/// 挂一个**只监听**（listenOnly，不修改事件）的 CGEvent tap，统计系统实际收到的
/// 按键。遥控器的 UP 会打成 `i`（虚拟键码 34）、语音键会打成 `m`（46）——
/// 诊断期间用户没碰真键盘的话，这两个键码的计数就是泄漏量。
final class KeyLeakProbe: @unchecked Sendable {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let lock = NSLock()
    private var counts: [CGKeyCode: Int] = [:]
    private var total = 0
    private(set) var installed = false

    /// 遥控器原始 usage 对应到 macOS 的虚拟键码（见 RemoteEventFilter.virtualKeyCode）
    static let watched: [CGKeyCode: String] = [
        34: "i (UP/杂散 0x0C)",
        46: "m (语音键 0x10)",
        126: "↑ (0x52)",
        125: "↓ (0x51)",
        123: "← (0x50)",
        124: "→ (0x4F)"
    ]

    @discardableResult
    func start() -> Bool {
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: leakTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        installed = true
        return true
    }

    fileprivate func note(_ keyCode: CGKeyCode) {
        lock.lock()
        counts[keyCode, default: 0] += 1
        total += 1
        lock.unlock()
    }

    func summary() -> (total: Int, watched: [(String, Int)]) {
        lock.lock()
        defer { lock.unlock() }
        let watchedList = Self.watched.map { (key, label) in
            (label, counts[key] ?? 0)
        }.filter { $0.1 > 0 }
        return (total, watchedList)
    }

    /// 原始计数（供 App 状态文件使用）
    func rawCounts() -> (total: Int, i: Int, m: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (total, counts[34] ?? 0, counts[46] ?? 0)
    }
}

private func leakTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
    context: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let context else { return Unmanaged.passUnretained(event) }
    let probe = Unmanaged<KeyLeakProbe>.fromOpaque(context).takeUnretainedValue()
    if type == .keyDown {
        probe.note(CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)))
    }
    return Unmanaged.passUnretained(event)
}

/// 线程安全的帧计数（HID 回调线程写入）。
private final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    func add(_ count: Int) {
        lock.lock(); total += count; lock.unlock()
    }
}

/// 极简 16 kHz 单声道 16-bit WAV 写入器（HID 回调线程写入）。
private final class WaveWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?
    private var dataBytes = 0
    private let path: String?

    init(path: String?) {
        self.path = path
        guard let path else { return }
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
        guard let handle else { return }
        var header = Data()
        header.append(contentsOf: Array("RIFF".utf8))
        header.append(contentsOf: [0, 0, 0, 0]) // 占位，结束时回填
        header.append(contentsOf: Array("WAVEfmt ".utf8))
        header.append(contentsOf: le32(16))
        header.append(contentsOf: le16(1)) // PCM
        header.append(contentsOf: le16(1)) // 单声道
        header.append(contentsOf: le32(16000))
        header.append(contentsOf: le32(16000 * 2))
        header.append(contentsOf: le16(2))
        header.append(contentsOf: le16(16))
        header.append(contentsOf: Array("data".utf8))
        header.append(contentsOf: le32(0)) // 占位
        handle.write(header)
    }

    func append(_ samples: [Int16]) {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return }
        var bytes = Data(capacity: samples.count * 2)
        for sample in samples {
            bytes.append(contentsOf: le16(UInt16(bitPattern: sample)))
        }
        handle.write(bytes)
        dataBytes += bytes.count
    }

    func finalize() {
        lock.lock()
        defer { lock.unlock() }
        guard let handle, path != nil else { return }
        // 回填 RIFF 大小与 data 大小
        try? handle.seek(toOffset: 4)
        handle.write(Data(le32(UInt32(36 + dataBytes))))
        try? handle.seek(toOffset: 40)
        handle.write(Data(le32(UInt32(dataBytes))))
        try? handle.close()
        self.handle = nil
    }

    private func le16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }
    private func le32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
         UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }
}

@MainActor
enum DiagnosticRunner {
    static func run() -> Int32 {
        VoiceDiagnostic.run(seconds: 8, verbose: true, wavPath: nil)
    }
}
