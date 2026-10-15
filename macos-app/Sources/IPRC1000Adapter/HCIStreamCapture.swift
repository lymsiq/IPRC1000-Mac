import CoreAudio
import CoreBluetooth
import Foundation
import ObjectiveC
import XPC
import os

/// **macOS 版的「ETW 流式抓包」**：用 CoreBluetooth 私有的 `CBPacketLoggerClient`
/// 直接订阅 bluetoothd 的原始 HCI 包流（XPC + 回调），**不需要 PacketLogger、不需要文件**。
///
/// 对应关系：
///   Windows : `BthPort` ETW 实时会话 → 回调里拿到 ACL 字节
///   macOS   : `CBPacketLoggerClient`（CoreBluetooth 私有）→ `rawPacketHandler` 回调
///
/// 运行时枚举到的接口（21 个方法）：
///   `setDispatchQueue:` / `setRawPacketHandler:` / `activateWithCompletion:`
///   `setErrorHandler:` / `setInterruptionHandler:` / `setInvalidationHandler:` / `invalidate`
///
/// ⚠ 待验证：**包数据本身可能仍需 Apple 的蓝牙日志描述文件才流动**
/// （PacketLogger 也是靠这个 profile 才有数据）。本模式已把回调打通，
/// 装上描述文件后应能直接收到流。若收不到，控制台会明确提示。
///
/// 用法：
///   IPRC1000Adapter --hci-stream [--wav 文件]
private let kHeaderTail: [UInt8] = [0x00, 0x00, 0x00, 0x40, 0x01]
private let kAudioBytes = 640
private let kFrameLen = 653

@MainActor
enum HCIStreamCapture {
    private static let logger = Logger(subsystem: "local.iprc1000.adapter", category: "HCIStream")

    /// 滚动缓冲：把各条包拼起来，然后在里面找音频帧签名。
    private final class RollingBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [UInt8] = []
        private let limit = 64 * 1024
        var audioFrames = 0
        var packets = 0
        var totalBytes = 0
        var seenLengths: [Int: Int] = [:]
        var firstHeads: [String] = []
        var onPCM: (([Int16]) -> Void)?
        /// 原始包落盘（每条前 4 字节大端长度），供离线分析格式
        var dumpHandle: FileHandle?

        func append(_ bytes: [UInt8]) {
            guard !bytes.isEmpty else { return }
            lock.lock()
            if let dumpHandle {
                var header = UInt32(bytes.count).bigEndian
                dumpHandle.write(Data(bytes: &header, count: 4))
                dumpHandle.write(Data(bytes))
            }
            packets += 1
            totalBytes += bytes.count
            seenLengths[bytes.count, default: 0] += 1
            if firstHeads.count < 6 {
                firstHeads.append(bytes.prefix(20).map { String(format: "%02X", $0) }.joined(separator: " "))
            }
            storage.append(contentsOf: bytes)
            if storage.count > limit { storage.removeFirst(storage.count - limit) }
            let frames = extract(&storage)
            lock.unlock()
            for pcm in frames { onPCM?(pcm) }
        }

        struct Snapshot {
            let packets: Int, bytes: Int, frames: Int
            let lengths: [Int: Int], heads: [String]
        }
        func snapshot() -> Snapshot {
            lock.lock(); defer { lock.unlock() }
            return Snapshot(packets: packets, bytes: totalBytes, frames: audioFrames,
                            lengths: seenLengths, heads: firstHeads)
        }

        /// 在缓冲里找音频帧。两种布局都试：
        ///   ① 连续 653 字节（HID 报告完整给出）
        ///   ② 拆成 344 + 4 字节 ACL 头 + 313（HCI 分片）
        private func extract(_ buffer: inout [UInt8]) -> [[Int16]] {
            var out: [[Int16]] = []
            var searchStart = 0
            while searchStart + 13 + kAudioBytes <= buffer.count {
                guard let sig = findSignature(buffer, from: searchStart) else { break }
                var payload: [UInt8]? = nil
                var consumed = 0
                // ① 连续
                if sig + kFrameLen <= buffer.count {
                    payload = Array(buffer[sig..<(sig + kFrameLen)])
                    consumed = sig + kFrameLen
                }
                // ② 分片：首片 340 字节(签名起) + 4 字节 ACL 头 + 313 字节
                if payload == nil, sig + 344 + 4 + 313 <= buffer.count {
                    var joined = Array(buffer[sig..<(sig + 340)])
                    joined.append(contentsOf: buffer[(sig + 344)..<(sig + 344 + 313)])
                    if joined.count == kFrameLen { payload = joined; consumed = sig + 344 + 4 + 313 }
                }
                guard let payload, let audioStart = audioOffset(payload) else {
                    searchStart = sig + 3
                    continue
                }
                var samples = [Int16](repeating: 0, count: kAudioBytes / 2)
                for i in 0..<(kAudioBytes / 2) {
                    samples[i] = Int16(bitPattern: UInt16(payload[audioStart + i * 2])
                                       | (UInt16(payload[audioStart + i * 2 + 1]) << 8))
                }
                out.append(samples)
                audioFrames += 1
                buffer.removeFirst(consumed)
                searchStart = 0
            }
            return out
        }

        /// 在字节流里定位 653 字节 HID 音频帧的起点。
        ///
        /// **真机实测的帧头**（macOS 26.6.2，遥控器 0A5C:8502）：
        ///   `A1 F7 01 <seq> 00 <rolling> <n> <cnt> 00 00 00 40 01`
        /// 其中：
        ///   `seq`     = 帧序号 0,1,2,…
        ///   `rolling` = 滚动计数（0x42, 0x82, 0xC2, 0x02 … 每帧 +0x40）
        ///   `cnt`     = 0, 9, 18, 27 …（每帧 +9）
        /// 注意：**第 5 字节不是固定值** —— Windows 适配器记录的 "0x81" 只对应某一帧，
        /// 照抄它会导致一帧都匹配不上（这就是之前「音频帧 0」的根因）。
        /// 因此只用**恒定**的特征：`A1 F7 01` + `[4]==0` + 尾部 `00 00 00 40 01`。
        /// 定位帧头。**复用 `HCIVoiceReceiver` 的唯一实现**，避免两处判定逻辑漂移
        /// （历史上就是因为只改了一处，才出现"命令行有帧、App 没帧"）。
        private func findSignature(_ b: [UInt8], from: Int) -> Int? {
            guard b.count >= 13 else { return nil }
            var i = max(0, from)
            while i + 13 <= b.count {
                if HCIVoiceReceiver.isFrameHeader(b, at: i) { return i }
                i += 1
            }
            return nil
        }

        /// 求 640 字节音频在帧内的起点。标准布局就是帧头 13 字节之后。
        private func audioOffset(_ payload: [UInt8]) -> Int? {
            guard payload.count >= 13 + kAudioBytes else { return nil }
            if payload[0] == 0xA1, payload[1] == 0xF7, payload[2] == 0x01,
               Array(payload[8..<13]) == kHeaderTail {
                return 13
            }
            // 兜底：帧头可能整体有偏移，就在前 40 字节里找恒定尾部
            for i in 0...(min(40, payload.count - kHeaderTail.count)) where i >= 1 {
                if Array(payload[i..<(i + kHeaderTail.count)]) == kHeaderTail {
                    let start = i + kHeaderTail.count
                    if start + kAudioBytes <= payload.count { return start }
                }
            }
            return nil
        }
    }

    static func run(wavPath: String?, seconds: Int = 60, dumpPath: String? = nil) -> Int32 {
        let output = BlackHoleOutput()
        let started = output.start()
        VoiceDiagnostic.write("BlackHole 输出：\(started.ok ? "就绪 ✅" : "失败 ❌ \(started.message)")")

        // 加载私有框架
        let imagePath = "/System/Library/Frameworks/CoreBluetooth.framework/CoreBluetooth"
        guard dlopen(imagePath, RTLD_NOW) != nil else {
            VoiceDiagnostic.write("❌ dlopen CoreBluetooth 失败：\(String(cString: dlerror()))")
            return 1
        }
        guard let cls = NSClassFromString("CBPacketLoggerClient") as? NSObject.Type else {
            VoiceDiagnostic.write("❌ 找不到 CBPacketLoggerClient（系统版本不支持？）")
            return 1
        }

        let buffer = RollingBuffer()
        let wav = SimpleWavWriter(path: wavPath)
        buffer.onPCM = { samples in
            output.enqueue16kMono(samples)
            wav?.append(samples)
        }

        if let dumpPath {
            FileManager.default.createFile(atPath: dumpPath, contents: nil)
            buffer.dumpHandle = FileHandle(forWritingAtPath: dumpPath)
        }
        let client = cls.init()
        typealias Handler = @convention(block) (AnyObject?) -> Void
        let rawHandler: Handler = { packet in
            guard let bytes = rawBytes(from: packet) else {
                logger.error("收到包但无法取出字节：\(String(describing: packet).prefix(120), privacy: .public)")
                return
            }
            buffer.append(bytes)
        }
        let errHandler: Handler = { error in
            VoiceDiagnostic.write("⚠️ 抓包错误：\(String(describing: error))")
        }
        let completion: Handler = { error in
            VoiceDiagnostic.write(error == nil
                ? "✅ 已连上 bluetoothd 抓包通道（流式）"
                : "❌ 激活失败：\(String(describing: error))")
        }

        func call(_ name: String, _ arg: AnyObject?) {
            let sel = NSSelectorFromString(name)
            guard client.responds(to: sel) else {
                VoiceDiagnostic.write("✗ 无此方法：\(name)")
                return
            }
            _ = client.perform(sel, with: arg)
        }
        call("setDispatchQueue:", DispatchQueue.main as AnyObject)
        call("setRawPacketHandler:", unsafeBitCast(rawHandler, to: AnyObject.self))
        call("setErrorHandler:", unsafeBitCast(errHandler, to: AnyObject.self))
        call("activateWithCompletion:", unsafeBitCast(completion, to: AnyObject.self))

        VoiceDiagnostic.write(">>> 按住遥控器【麦克风键】说话（系统输入切到 BlackHole 2ch） <<<")

        let deadline = Date().addingTimeInterval(Double(seconds))
        var lastReport = Date()
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            if Date().timeIntervalSince(lastReport) > 5 {
                lastReport = Date()
                let s = buffer.snapshot()
                VoiceDiagnostic.write("包 \(s.packets)  共 \(s.bytes) B  音频帧 \(s.frames)"
                                      + "  长度分布 \(s.lengths.sorted { $0.key < $1.key }.prefix(6).map { "\($0.key)B×\($0.value)" }.joined(separator: " "))")
                if s.packets == 0 {
                    VoiceDiagnostic.write("   （还没有任何包）")
                } else {
                    for (i, head) in s.heads.prefix(3).enumerated() {
                        VoiceDiagnostic.write("   包#\(i) 前20字节：\(head)")
                    }
                }
            }
        }

        try? buffer.dumpHandle?.close()
        buffer.dumpHandle = nil
        let final = buffer.snapshot()
        VoiceDiagnostic.write("")
        VoiceDiagnostic.write("===== 结束：包 \(final.packets)  共 \(final.bytes) B  音频帧 \(final.frames) =====")
        VoiceDiagnostic.write("长度分布："
            + final.lengths.sorted { $0.key < $1.key }.map { "\($0.key)B×\($0.value)" }.joined(separator: "  "))
        return final.frames > 0 ? 0 : 2
    }

    /// 从私有 API 回调给的对象里抠出原始字节。
    ///
    /// **实测**：`CBPacketLoggerClient` 的 `rawPacketHandler` 交上来的是
    /// `OS_xpc_data`（XPC 对象），**不是** NSData、也不是 KVC 容器 ——
    /// 所以必须走 XPC 的 C API（`xpc_get_type` / `xpc_data_get_bytes_ptr`），
    /// 用 `valueForKey:` 会直接抛 `NSUnknownKeyException` 把进程干掉。
    private static func rawBytes(from packet: AnyObject?) -> [UInt8]? {
        guard let packet else { return nil }
        // 有些系统版本直接桥接成 NSData / Data
        if let data = packet as? Data { return [UInt8](data) }
        if let nsdata = packet as? NSData { return [UInt8](Data(referencing: nsdata)) }

        // Swift 里 xpc_* 系列要的是 `OS_xpc_object`；实际对象是它的子类 OS_xpc_data。
        guard let xo = packet as? OS_xpc_object else { return nil }
        let type = xpc_get_type(xo)

        if type == XPC_TYPE_DATA {
            let length = xpc_data_get_length(xo)
            guard length > 0, let ptr = xpc_data_get_bytes_ptr(xo) else { return [] }
            return [UInt8](UnsafeRawBufferPointer(start: ptr, count: length))
        }

        if type == XPC_TYPE_DICTIONARY {
            for key in ["data", "packetData", "packet", "bytes", "payload", "rawData", "value"] {
                if let inner = xpc_dictionary_get_value(xo, key),
                   let bytes = rawBytes(from: inner as AnyObject), !bytes.isEmpty {
                    return bytes
                }
            }
            return nil
        }

        if type == XPC_TYPE_ARRAY {
            var merged: [UInt8] = []
            let count = xpc_array_get_count(xo)
            for index in 0..<count {
                let item = xpc_array_get_value(xo, index)
                if let bytes = rawBytes(from: item as AnyObject) {
                    merged.append(contentsOf: bytes)
                }
            }
            return merged.isEmpty ? nil : merged
        }

        let typeName = String(cString: xpc_type_get_name(type))
        if !reportedUnknownType {
            reportedUnknownType = true
            VoiceDiagnostic.write("⚠️ 未知的包类型：\(typeName)（每包都跳过）")
        }
        return nil
    }

    private nonisolated(unsafe) static var reportedUnknownType = false
}

/// 极简 WAV 写入（与 DiagnosticRunner 里那个同级，供本处可选导出）
final class SimpleWavWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?
    private var dataBytes = 0
    private let active: Bool

    init?(path: String?) {
        guard let path else { active = false; return nil }
        active = true
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
        guard let handle else { return nil }
        var h = Data()
        h.append(contentsOf: Array("RIFF".utf8)); h.append(contentsOf: [0, 0, 0, 0])
        h.append(contentsOf: Array("WAVEfmt ".utf8)); h.append(contentsOf: le32(16))
        h.append(contentsOf: le16(1)); h.append(contentsOf: le16(1))
        h.append(contentsOf: le32(16000)); h.append(contentsOf: le32(32000))
        h.append(contentsOf: le16(2)); h.append(contentsOf: le16(16))
        h.append(contentsOf: Array("data".utf8)); h.append(contentsOf: le32(0))
        handle.write(h)
    }

    func append(_ samples: [Int16]) {
        lock.lock(); defer { lock.unlock() }
        guard active, let handle else { return }
        var bytes = Data(capacity: samples.count * 2)
        for s in samples { bytes.append(contentsOf: le16(UInt16(bitPattern: s))) }
        handle.write(bytes); dataBytes += bytes.count
    }

    private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
}
