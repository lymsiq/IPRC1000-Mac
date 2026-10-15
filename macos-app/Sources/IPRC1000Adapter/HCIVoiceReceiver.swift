import CoreBluetooth
import Foundation
import XPC
import os

/// **macOS 版「ETW 流式抓包」→ 语音 → 虚拟声卡**
///
/// 用 CoreBluetooth 私有的 `CBPacketLoggerClient` 订阅 bluetoothd 的 HCI 包流，
/// 从中抠出 **653 字节的 HID 音频报告（0xF7）**，再交给 `VoiceHIDBridge` 解码、
/// 高通滤波后写进 **BlackHole 2ch**（于是任何输入法/听写都能把它当麦克风用）。
///
/// ## 为什么必须走 HCI 而不能走 IOHID
/// 遥控器的报告描述符只声明了 Report ID 1、最大 9 字节输入；音频却是 **653 字节**的
/// 未声明报告 → macOS 的 IOHIDFamily 严格按描述符解析，**把音频直接丢掉**。
/// 所以 `IOHIDManager` 那条路永远是死的（实测：长度直方图恒为 `{9: N}`）。
///
/// ## 前置条件（一次性，管理员）
/// `./enable-hci-trace.sh` —— 打开 bluetoothd 的 `HCITraces` + `HCISkipAuth`。
/// 不做这一步，本类会 `activate` 成功但**一个包都收不到**。
///
/// ## 真机实测的帧结构（macOS 26.6.2 / IPRC1000 0A5C:8502）
/// HCI 记录 = 21 字节记录头 + 653 字节 HID 报告（报文总长 674）：
/// ```
/// A1 F7 01 <seq> 00 <rolling> <n> <cnt> 00 00 00 40 01 | 640 字节 PCM
/// └──────────────── 13 字节帧头 ────────────────┘
/// ```
/// `rolling` 是滚动计数器（0x42, 0x82, 0xC2, 0x02 … 每帧 +0x40），
/// 所以**不能**照抄 Windows 那份记录里的固定 `0x81` —— 只认恒定特征。
final class HCIVoiceReceiver: @unchecked Sendable {
    private static let logger = Logger(subsystem: "local.iprc1000.adapter", category: "HCIVoice")

    /// 恒定尾部：帧头第 8..12 字节
    static let headerTail: [UInt8] = [0x00, 0x00, 0x00, 0x40, 0x01]
    /// 一帧 HID 报告长度 = 13 字节帧头 + 640 字节 PCM
    static let frameLength = 653

    var onStatus: @Sendable (String, Bool) -> Void = { _, _ in }
    /// 每抠出一帧完整 HID 报告就回调（由 `AppModel` 转给 `VoiceHIDBridge` 解码）
    var onFrame: @Sendable ([UInt8]) -> Void = { _ in }

    /// ⚠ 关键：**不要把回调挂在主队列上**。
    /// 主队列同时跑着 App 的 UI、每 0.2 s 的 tick 和每 2 s 的状态文件写入 ——
    /// 包会被这些任务排在后面，实测能贡献几十毫秒的抖动/延迟。
    /// 用独立的 userInteractive 串行队列，让收包路径不被 App 其它工作干扰。
    let queue = DispatchQueue(label: "local.iprc1000.hci-voice", qos: .userInteractive)

    private let lock = NSLock()
    private var storage: [UInt8] = []
    private let storageLimit = 64 * 1024
    private var client: NSObject?
    private var started = false
    /// 通道是否仍然有效（中断/失效后置 false，便于诊断"在收空气"）
    private(set) var connected = false

    private(set) var packets = 0
    private(set) var totalBytes = 0
    private(set) var framesFound = 0

    // MARK: - 延迟计量
    //
    // HCI 记录头里带着「包到达主机」的时间戳（4 字节秒 + 4 字节微秒）。
    // 拿它和当前时间相减，就是**包从主机收到 → 我们回调拿到**的延迟 ——
    // 这一段包含 bluetoothd 的 HCI trace 开销 + XPC 投递，是我们能优化的部分。
    // 注意：该时间戳用**本地墙钟时间**表达的 Unix 秒（实测本机如此），
    // 所以要拿「本地时间当作 UTC 转成的秒」去比。
    private(set) var ageMsLast = 0.0
    private(set) var ageMsMax = 0.0
    private(set) var ageMsAvg = 0.0
    private(set) var ageSamples = 0
    private var ageSum = 0.0
    /// 从「回调进入」到「帧交给下游」的处理耗时峰值（ms）——用来确认我们自己的代码不慢
    private(set) var processMsMax = 0.0

    func start() {
        guard !started else { return }
        started = true

        let imagePath = "/System/Library/Frameworks/CoreBluetooth.framework/CoreBluetooth"
        guard dlopen(imagePath, RTLD_NOW) != nil else {
            onStatus("无法加载 CoreBluetooth：\(String(cString: dlerror()))", false)
            return
        }
        guard let cls = NSClassFromString("CBPacketLoggerClient") as? NSObject.Type else {
            onStatus("本机不支持 CBPacketLoggerClient（系统版本过旧？）", false)
            return
        }

        let client = cls.init()
        self.client = client

        typealias Handler = @convention(block) (AnyObject?) -> Void
        let rawHandler: Handler = { [weak self] packet in
            guard let self, let bytes = Self.rawBytes(from: packet) else { return }
            self.ingest(bytes)
        }
        let errorHandler: Handler = { [weak self] error in
            self?.onStatus("HCI 抓包出错：\(String(describing: error))", false)
        }
        let completion: Handler = { [weak self] error in
            guard let self else { return }
            if error == nil {
                self.connected = true
                self.onStatus("监听遥控器语音中（HCI 流式）…", false)
            } else {
                self.onStatus("HCI 通道激活失败：\(String(describing: error))"
                              + "（请先跑 ./enable-hci-trace.sh）", false)
            }
        }

        func call(_ name: String, _ argument: AnyObject?) {
            let selector = NSSelectorFromString(name)
            guard client.responds(to: selector) else {
                Self.logger.error("CBPacketLoggerClient 无此方法：\(name, privacy: .public)")
                return
            }
            _ = client.perform(selector, with: argument)
        }
        // bluetoothd 重启 / 睡眠唤醒 / XPC 断开时，回调会**静默停掉**。
        // 不接这两个处理器的话，界面会一直显示"监听中"却在收空气 —— 用户完全看不出来。
        let interruption: Handler = { [weak self] reason in
            self?.connected = false
            self?.onStatus("HCI 通道被中断：\(String(describing: reason))", false)
        }
        let invalidation: Handler = { [weak self] reason in
            self?.connected = false
            self?.onStatus("HCI 通道已失效：\(String(describing: reason))"
                           + "（重启 App 或重跑 ./enable-hci-trace.sh）", false)
        }

        call("setDispatchQueue:", queue as AnyObject)
        call("setRawPacketHandler:", unsafeBitCast(rawHandler, to: AnyObject.self))
        call("setErrorHandler:", unsafeBitCast(errorHandler, to: AnyObject.self))
        call("setInterruptionHandler:", unsafeBitCast(interruption, to: AnyObject.self))
        call("setInvalidationHandler:", unsafeBitCast(invalidation, to: AnyObject.self))
        call("activateWithCompletion:", unsafeBitCast(completion, to: AnyObject.self))
    }

    // MARK: - 收包 → 抠帧

    private func ingest(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        if let stamp = Self.recordTimestamp(bytes) {
            let age = Self.nowAsRecordClock() - stamp
            // 只统计合理范围，避免时间戳解析异常污染数据
            if age >= 0, age < 5 {
                lock.lock()
                ageMsLast = age * 1000
                if ageMsLast > ageMsMax { ageMsMax = ageMsLast }
                ageSum += ageMsLast
                ageSamples += 1
                ageMsAvg = ageSum / Double(ageSamples)
                lock.unlock()
            }
        }
        let startedAt = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        packets += 1
        totalBytes += bytes.count
        storage.append(contentsOf: bytes)
        if storage.count > storageLimit {
            storage.removeFirst(storage.count - storageLimit)
        }
        let found = Self.extractFrames(from: &storage)
        framesFound += found.count
        lock.unlock()
        for frame in found { onFrame(frame) }
        if !found.isEmpty {
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
            lock.lock()
            if elapsedMs > processMsMax { processMsMax = elapsedMs }
            lock.unlock()
        }
    }

    /// 从缓冲里就地抠出所有**完整**的 653 字节帧，并把已消费的字节移出缓冲。
    ///
    /// 抽成静态函数是为了能被自检覆盖（这条路径曾经有过一个越界崩溃）。
    static func extractFrames(from storage: inout [UInt8]) -> [[UInt8]] {
        var found: [[UInt8]] = []
        while storage.count >= frameLength {
            guard let start = findFrameStart(storage, from: 0) else { break }
            found.append(Array(storage[start..<(start + frameLength)]))
            storage.removeFirst(start + frameLength)
        }
        return found
    }

    /// 在字节流里定位 653 字节帧的起点。
    ///
    /// 只使用**恒定**特征：`A1 F7 01` + `[4]==0` + 尾部 `00 00 00 40 01`。
    /// （帧头的 `rolling` / `cnt` 字段逐帧变化，不能拿来匹配。）
    ///
    /// ⚠ 必须同时确认**整帧都还在缓冲里**（`index + frameLength <= count`）：
    /// 只检查 13 字节头部的话，当一个包被分片、或 64KB 裁剪正好切在帧中间时，
    /// 调用方按 `start + 653` 取子数组就会**数组越界崩溃**。
    /// 帧不完整时正确行为是"等更多数据"，而不是返回一个取不满的起点。
    static func findFrameStart(_ buffer: [UInt8], from: Int) -> Int? {
        guard buffer.count >= frameLength else { return nil }
        var index = max(0, from)
        while index + frameLength <= buffer.count {
            if isFrameHeader(buffer, at: index) { return index }
            index += 1
        }
        return nil
    }

    /// 判定 `index` 处是否是音频帧头。
    ///
    /// **只认恒定特征**：`A1 F7 01` + `[4]==0` + `00 00 00 40 01`。
    /// 帧头第 5 字节是滚动计数器（0x42/0x82/0xC2/0x02…），**不能**当固定值匹配
    /// —— 照抄别处记录的 `0x81` 会导致一帧都匹配不上。
    ///
    /// 这是**唯一**的帧头判定实现：命令行模式（`HCIStreamCapture`）也调它，
    /// 避免两处各写一份、改一处漏一处（历史上就这样漏过一次）。
    static func isFrameHeader(_ buffer: [UInt8], at index: Int) -> Bool {
        guard index >= 0, index + 13 <= buffer.count else { return false }
        return buffer[index] == 0xA1
            && buffer[index + 1] == 0xF7
            && buffer[index + 2] == 0x01
            && buffer[index + 4] == 0x00
            && Array(buffer[(index + 8)..<(index + 13)]) == headerTail
    }

    // MARK: - 时间戳

    /// 解析 HCI 记录头里的到达时间。
    ///
    /// 布局（实测）：`[4B 记录长度][4B 秒 BE][4B 微秒 BE][9B 协议头][653B HID 报告]`
    /// 返回值为「本地墙钟时间表达的 Unix 秒 + 微秒小数」。
    static func recordTimestamp(_ bytes: [UInt8]) -> Double? {
        guard bytes.count >= 12 else { return nil }
        let seconds = UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16
            | UInt32(bytes[6]) << 8 | UInt32(bytes[7])
        let micros = UInt32(bytes[8]) << 24 | UInt32(bytes[9]) << 16
            | UInt32(bytes[10]) << 8 | UInt32(bytes[11])
        guard seconds > 1_600_000_000, seconds < 1_900_000_000, micros < 1_000_000 else {
            return nil
        }
        return Double(seconds) + Double(micros) / 1_000_000
    }

    /// 当前时间，换算到与 `recordTimestamp` 同一套坐标（本地墙钟当作 UTC）。
    static func nowAsRecordClock() -> Double {
        var now = timeval()
        gettimeofday(&now, nil)
        var broken = tm()
        var seconds = time_t(now.tv_sec)
        localtime_r(&seconds, &broken)
        broken.tm_isdst = -1
        let asUTC = timegm(&broken)
        return Double(asUTC) + Double(now.tv_usec) / 1_000_000
    }

    // MARK: - XPC 取字节

    /// `CBPacketLoggerClient` 的 `rawPacketHandler` 交上来的是 **`OS_xpc_data`**：
    /// 既不是 `NSData` 也不是 KVC 容器 —— 必须走 XPC 的 C API，
    /// 用 `valueForKey:` 会抛 `NSUnknownKeyException` 直接杀掉进程。
    static func rawBytes(from packet: AnyObject?) -> [UInt8]? {
        guard let packet else { return nil }
        if let data = packet as? Data { return [UInt8](data) }
        if let nsdata = packet as? NSData { return [UInt8](Data(referencing: nsdata)) }

        guard let xo = packet as? OS_xpc_object else { return nil }
        let type = xpc_get_type(xo)

        if type == XPC_TYPE_DATA {
            let length = xpc_data_get_length(xo)
            guard length > 0, let pointer = xpc_data_get_bytes_ptr(xo) else { return [] }
            return [UInt8](UnsafeRawBufferPointer(start: pointer, count: length))
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
            for index in 0..<xpc_array_get_count(xo) {
                let item = xpc_array_get_value(xo, index)
                if let bytes = rawBytes(from: item as AnyObject) {
                    merged.append(contentsOf: bytes)
                }
            }
            return merged.isEmpty ? nil : merged
        }
        return nil
    }
}
