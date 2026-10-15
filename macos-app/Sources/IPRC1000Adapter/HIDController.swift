import CoreGraphics
import Foundation
import IOKit.hid
import os

enum TargetRemote {
    static let vendorID = 0x0A5C
    static let productID = 0x8502
    static let productName = "IPRC1000"

    static func matches(vendorID: Int?, productID: Int?, productName: String?) -> Bool {
        vendorID == self.vendorID
            && productID == self.productID
    }

    static func matches(_ device: IOHIDDevice) -> Bool {
        matches(
            vendorID: numberProperty(device, key: kIOHIDVendorIDKey),
            productID: numberProperty(device, key: kIOHIDProductIDKey),
            productName: stringProperty(device, key: kIOHIDProductKey)
        )
    }

    private static func numberProperty(_ device: IOHIDDevice, key: String) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }

    private static func stringProperty(_ device: IOHIDDevice, key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }
}

/// **按键诊断日志**：把遥控器发来的每条按键报告原样记下来。
///
/// 用来回答"某个键按了没反应"这类问题 —— 到底是
///   ① 遥控器压根没发；② 发了但 report ID 不是 1（被我们忽略）；
///   ③ 发了但 usage 不在 `RemoteKey` 里；④ usage 认出来了却没发出按键。
///
/// 写到 `/tmp/iprc-keys.log`，超过 256 KB 自动重来。
enum KeyTrace {
    static let path = "/tmp/iprc-keys.log"
    private static let lock = NSLock()
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func log(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        let text = stamp.string(from: Date()) + "  " + line + "\n"
        let manager = FileManager.default
        if !manager.fileExists(atPath: path) {
            manager.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        if (try? handle.seekToEnd()) ?? 0 > 256 * 1024 {
            try? handle.truncate(atOffset: 0)
        }
        handle.write(Data(text.utf8))
    }
}

private func hidMatched(_ context: UnsafeMutableRawPointer?, _ result: IOReturn,
                        _ sender: UnsafeMutableRawPointer?, _ device: IOHIDDevice) {
    guard let context else { return }
    Unmanaged<HIDController>.fromOpaque(context).takeUnretainedValue().matched(device)
}

private func hidRemoved(_ context: UnsafeMutableRawPointer?, _ result: IOReturn,
                        _ sender: UnsafeMutableRawPointer?, _ device: IOHIDDevice) {
    guard let context else { return }
    Unmanaged<HIDController>.fromOpaque(context).takeUnretainedValue().removed(device)
}

private func hidReport(_ context: UnsafeMutableRawPointer?, _ result: IOReturn,
                       _ sender: UnsafeMutableRawPointer?, _ type: IOHIDReportType,
                       _ reportID: UInt32, _ report: UnsafeMutablePointer<UInt8>,
                       _ reportLength: CFIndex, _ timestamp: UInt64) {
    guard let context else { return }
    Unmanaged<HIDController>.fromOpaque(context).takeUnretainedValue()
        .receivedReport(
            Array(UnsafeBufferPointer(start: report, count: reportLength)),
            reportID: Int(reportID), timestamp: timestamp
        )
}

final class HIDController: @unchecked Sendable {
    private static let logger = Logger(subsystem: "local.iprc1000.adapter", category: "HIDReport")
    var onStatus: @Sendable (String, Bool) -> Void = { _, _ in }
    var onKey: @Sendable (RemoteKey) -> Void = { _ in }
    var onKeyRepeat: @Sendable (RemoteKey) -> Void = { _ in }
    var onKeyUp: @Sendable (RemoteKey) -> Void = { _ in }
    /// 每一条原始 HID 报告都会回调（reportID, 报告字节, 硬件时间戳）。
    /// 语音桥靠它拿 0xF7 音频报告，不必再单独开一个 IOHIDManager。
    var onRawReport: (@Sendable (Int, [UInt8], UInt64) -> Void)?

    /// 打开设备时是否**独占**（seize）。
    ///
    /// ⚠ **实测结论（IPRC1000 + macOS 15/26）：蓝牙 HID 上绝不能独占。**
    /// `IOHIDManagerOpen(kIOHIDOptionsTypeSeizeDevice)` 会返回 `kIOReturnSuccess`，
    /// 但之后**一条报告都收不到**（数据被一起掐断）；而系统那头照样把它当键盘在打
    /// `i`(0x0C) / `m`(0x10) —— 等于既聋了又没挡住。
    /// 所以默认**不独占**，改用 `RemoteEventFilter`（CGEvent 过滤器）拦掉泄漏的原始键值。
    ///
    /// 想复现实验：`touch /tmp/iprc-force-seize` 后重启 App 即可重新打开独占。
    var seizesDevice = false
    private(set) var seizureActive = false
    /// 事件过滤器（拦截遥控器原始键值）是否已挂上。没挂上就拦不住 i / m。
    var eventFilterActive: Bool { eventFilter.isActive }
    /// 诊断用：打开设备的结果码（0 = kIOReturnSuccess）
    private(set) var openResult: Int32 = -9999
    private(set) var seizeResult: Int32 = -9999
    /// 诊断用：收到的报告总数 / 按报告 ID 的直方图
    private(set) var reportCount = 0
    private(set) var rawReportHistogram: [Int: Int] = [:]
    /// 诊断用：累计解析出的按键事件数 / 当前按下的 usage
    private(set) var keyEventCount = 0
    private(set) var lastUsages: [UInt8] = []
    /// 诊断用：见过的最大报告长度 + 长度分布。
    /// **判据**：音频帧是 653 字节的报告；如果 `maxReportLength` 一直 ≤ 9，
    /// 说明 macOS 的 HID 层把超大报告截断/丢弃了，HID 直读这条路走不通。
    /// 已经记过一笔的"被忽略的 report ID"，避免日志刷屏
    private var ignoredReportIDs: Set<Int> = []
    private(set) var maxReportLength = 0
    private(set) var lengthHistogram: [Int: Int] = [:]
    /// 诊断用：设备报告描述符（十六进制）与描述符声明的最大输入报告长度。
    /// 若描述符只声明了 Report ID 1 / 9 字节输入，那 653 字节的音频报告必然被丢弃。
    private(set) var reportDescriptorHex = "<none>"
    private(set) var declaredMaxInput = -1

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private let eventFilter = RemoteEventFilter()
    private var pressed: Set<UInt8> = []
    private var currentDevice: IOHIDDevice?

    deinit {
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func start() {
        eventFilter.onRepeat = { [weak self] keyCode in
            guard let self,
                  let key = Self.repeatingKey(for: keyCode, pressed: self.pressed) else { return }
            self.onKeyRepeat(key)
        }
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: TargetRemote.vendorID,
            kIOHIDProductIDKey as String: TargetRemote.productID
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, hidMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, hidRemoved, context)
        IOHIDManagerRegisterInputReportWithTimeStampCallback(manager, hidReport, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        // 先尽力独占设备，让系统彻底不再把遥控器当键盘。
        performOpen()
        // 按键过滤只在“没能独占”时才真正派上用场；拿不到辅助功能权限也不该阻断 HID。
        if !eventFilter.start(), !seizureActive {
            onStatus("无法启动按键过滤；请允许辅助功能与输入监控", false)
        }
    }

    private func performOpen() {
        //
        // ⚠ 但**只有在「输入监控」已授权时才独占**：否则我们会把设备锁住却读不到任何
        // 报告（TCC 会拦掉报告投递），结果是遥控器彻底失灵 —— 比泄漏成 i / m 更糟。
        // 没权限时退回普通打开，遥控器至少还能当键盘用。
        let canRead = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        // 默认不独占（见 seizesDevice 说明）。想复现："touch /tmp/iprc-force-seize" 再重启 App。
        let forceSeize = FileManager.default.fileExists(atPath: "/tmp/iprc-force-seize")
        if (seizesDevice || forceSeize) && canRead {
            seizeResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        }
        var result = seizeResult
        if seizeResult == kIOReturnSuccess {
            seizureActive = true
        } else {
            if seizesDevice && canRead {
                let code = seizeResult
                Self.logger.error("seize 失败（\(code)），回退为普通打开")
            }
            result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            seizureActive = false
        }
        openResult = result
        if result == kIOReturnSuccess {
            onStatus(
                seizureActive
                    ? "IPRC1000 已连接并独占，按键适配已启用"
                    : "IPRC1000 已连接（未独占，依赖事件过滤兜底）",
                true
            )
        } else {
            onStatus("无法打开遥控器 HID 通道（\(result)）；请检查「输入监控」权限", false)
        }
    }

    /// 权限是**运行中**才被授予时，重新打开设备 —— 否则必须手动重启 App 才生效。
    func reopen() {
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        seizureActive = false
        openResult = -9999
        seizeResult = -9999
        performOpen()
    }

    fileprivate func matched(_ device: IOHIDDevice) {
        guard TargetRemote.matches(device), currentDevice == nil else { return }
        currentDevice = device
        logDescriptor(for: device)
        onStatus(
            seizureActive
                ? "IPRC1000 已连接并独占：原始键值不再进系统，按键适配已启用"
                : "IPRC1000 已连接（未独占，依赖事件过滤兜底）",
            true
        )
    }


    private func logDescriptor(for device: IOHIDDevice) {
        func number(_ key: String) -> Int {
            (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? -1
        }
        let descriptor = (IOHIDDeviceGetProperty(
            device, kIOHIDReportDescriptorKey as CFString
        ) as? Data)?.map { String(format: "%02X", $0) }.joined() ?? "<none>"
        reportDescriptorHex = descriptor
        declaredMaxInput = number(kIOHIDMaxInputReportSizeKey)
        let elements = (IOHIDDeviceCopyMatchingElements(
            device, nil, IOOptionBits(kIOHIDOptionsTypeNone)
        ) as? [IOHIDElement]) ?? []
        let reports = Set(elements.map {
            "\(IOHIDElementGetType($0).rawValue):\(IOHIDElementGetReportID($0))"
        }).sorted().joined(separator: ",")
        Self.logger.notice(
            "matched descriptor=\(descriptor, privacy: .public) maxInput=\(number(kIOHIDMaxInputReportSizeKey), privacy: .public) maxOutput=\(number(kIOHIDMaxOutputReportSizeKey), privacy: .public) maxFeature=\(number(kIOHIDMaxFeatureReportSizeKey), privacy: .public) elementTypeReports=\(reports, privacy: .public)"
        )
    }

    fileprivate func removed(_ device: IOHIDDevice) {
        if currentDevice === device {
            currentDevice = nil
            for usage in pressed where usage != 0x0C {
                if let key = RemoteKey(rawValue: usage) { onKeyUp(key) }
            }
            pressed = []
            onStatus("等待 IPRC1000 连接", false)
        }
    }

    fileprivate func receivedReport(_ report: [UInt8], reportID: Int, timestamp: UInt64) {
        // 先把原始报告交给语音桥（0xF7 音频帧就是从这里走的）。
        onRawReport?(reportID, report, timestamp)
        reportCount += 1
        rawReportHistogram[reportID, default: 0] += 1
        if report.count > maxReportLength { maxReportLength = report.count }
        lengthHistogram[report.count, default: 0] += 1

        // ⚠ 只有键盘报告（report ID 1）才代表按键状态。
        //   音频帧（0xF7）等其它报告如果也走下面的逻辑，`rawUsages` 会返回空集，
        //   于是 `removed = 全部已按下键` —— **收音期间会给按住的键发假松手**。
        guard reportID == HIDReportParser.keyboardReportID else {
            // 短报告也记一笔：万一某个键用的是别的 report ID，这里能看出来
            if report.count <= 32 {
                let bytes = report.map { String(format: "%02X", $0) }.joined(separator: " ")
                Self.logger.debug(
                    "report id=\(reportID, privacy: .public) timestamp=\(timestamp, privacy: .public) bytes=\(bytes, privacy: .public)"
                )
                if !ignoredReportIDs.contains(reportID) {
                    ignoredReportIDs.insert(reportID)
                    KeyTrace.log("⚠️ 收到被忽略的 report id=\(reportID) len=\(report.count) bytes=\(bytes)")
                }
            }
            return
        }

        let next = HIDReportParser.rawUsages(from: report, reportID: reportID)
        let removed = pressed.subtracting(next)
        let added = next.subtracting(pressed)
        if !added.isEmpty || !removed.isEmpty {
            let bytes = report.map { String(format: "%02X", $0) }.joined(separator: " ")
            var detail = "report id=\(reportID) len=\(report.count) bytes=\(bytes)"
            for usage in added.sorted() {
                let name = RemoteKey(rawValue: usage)?.title ?? "❌未映射"
                detail += "  |按下 0x\(String(format: "%02X", usage)) \(name)"
            }
            for usage in removed.sorted() {
                let name = RemoteKey(rawValue: usage)?.title ?? "❌未映射"
                detail += "  |松开 0x\(String(format: "%02X", usage)) \(name)"
            }
            KeyTrace.log(detail)
        }
        for usage in removed {
            eventFilter.note(usage: usage, isDown: false, hidTimestamp: timestamp)
            if usage != 0x0C, let key = RemoteKey(rawValue: usage) { onKeyUp(key) }
        }
        for usage in added {
            eventFilter.note(usage: usage, isDown: true, hidTimestamp: timestamp)
            if usage != 0x0C, let key = RemoteKey(rawValue: usage) { onKey(key) }
        }
        if !added.isEmpty { keyEventCount += 1 }
        lastUsages = next.sorted()
        pressed = next
    }

    /// 强制释放某个 usage。
    ///
    /// 遥控器的**语音键在收音期间会一直保持按下**（不会上报全零的"松手"报告），
    /// 于是 `pressed` 里会一直留着它：① 映射出去的动作永远收不到 release
    /// （比如 Fn 会卡住，豆包就一直录）；② 下次再按它时 `added` 为空，
    /// **根本不会再触发一次**。所以必须由"音频流结束"来补一个释放。
    func forceRelease(usage: UInt8) {
        guard pressed.contains(usage) else { return }
        pressed.remove(usage)
        if usage != 0x0C, let key = RemoteKey(rawValue: usage) { onKeyUp(key) }
    }

    static func repeatingKey(for keyCode: CGKeyCode, pressed: Set<UInt8>) -> RemoteKey? {
        guard let usage = pressed.first(where: {
            $0 != 0x0C && RemoteEventFilter.virtualKeyCode(for: $0) == keyCode
        }) else { return nil }
        return RemoteKey(rawValue: usage)
    }
}
