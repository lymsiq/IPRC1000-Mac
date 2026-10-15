import CoreGraphics
import Foundation
import os

struct RemoteEventCorrelator {
    struct Pending {
        let keyCode: CGKeyCode
        let isDown: Bool
        let timestamp: UInt64
    }

    private(set) var pending: [Pending] = []
    private(set) var suppressedDownKeyCodes: Set<CGKeyCode> = []
    private(set) var passthroughDownKeyCodes: Set<CGKeyCode> = []
    /// 遥控器报告与系统按键之间的允许时间差。
    ///
    /// ⚠ 原来是 2 ms —— 太紧：按住麦克风键时音频帧以 ~50/秒 涌来，
    /// 按键报告和它中间夹着大报告，投递抖动轻松超过 2 ms，于是**批量漏拦**。
    static let tolerance: UInt64 = 20_000_000
    /// 松键时遥控器会多吐一条 `0x0C`（字母 `i`）的杂散报告，容差放宽。
    static let spuriousITolerance: UInt64 = 100_000_000

    /// IOHID 报告回调的时间戳是 **mach 绝对时间（tick）**，
    /// 而 `CGEvent.timestamp` 是 **纳秒**。在 Apple Silicon 上两者相差
    /// `timebase` 因子（125/3 ≈ 41.67），**直接比较会让关联永远匹配不上** ——
    /// 这正是「遥控器原始键值泄漏成 `i` / `m`」的根因。
    /// 这里同时按几种可能的单位关系去比，取最小距离，两种约定都能兼容。
    private static let timebase: (numer: Double, denom: Double) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        guard info.numer != 0, info.denom != 0 else { return (1, 1) }
        return (Double(info.numer), Double(info.denom))
    }()

    private static func closestDistance(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (n, d) = timebase
        let a = Double(lhs)
        let candidates = [lhs,
                          UInt64(a * n / d),
                          UInt64(a * d / n)]
        var best = UInt64.max
        for candidate in candidates {
            let distance = candidate > rhs ? candidate - rhs : rhs - candidate
            if distance < best { best = distance }
        }
        return best
    }

    mutating func note(keyCode: CGKeyCode, isDown: Bool, timestamp: UInt64) {
        pending.append(Pending(keyCode: keyCode, isDown: isDown, timestamp: timestamp))
        if pending.count > 64 { pending.removeFirst(pending.count - 64) }
    }

    mutating func consume(
        keyCode: CGKeyCode, isDown: Bool, isRepeat: Bool, timestamp: UInt64
    ) -> Bool {
        pending.removeAll { Self.closestDistance($0.timestamp, timestamp) > 500_000_000 }
        if let index = pending.firstIndex(where: {
            $0.keyCode == keyCode && $0.isDown == isDown
                && Self.closestDistance($0.timestamp, timestamp)
                    <= (keyCode == 34 ? Self.spuriousITolerance : Self.tolerance)
        }) {
            pending.remove(at: index)
            if isDown {
                suppressedDownKeyCodes.insert(keyCode)
                passthroughDownKeyCodes.remove(keyCode)
            } else {
                suppressedDownKeyCodes.remove(keyCode)
            }
            return true
        }
        guard suppressedDownKeyCodes.contains(keyCode) else { return false }
        if isDown && !isRepeat {
            passthroughDownKeyCodes.insert(keyCode)
            return false
        }
        if passthroughDownKeyCodes.contains(keyCode) {
            if !isDown { passthroughDownKeyCodes.remove(keyCode) }
            return false
        }
        if !isDown { suppressedDownKeyCodes.remove(keyCode) }
        return true
    }
}

private func remoteEventTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
    context: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let context else { return Unmanaged.passUnretained(event) }
    let filter = Unmanaged<RemoteEventFilter>.fromOpaque(context).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        filter.enable()
        return Unmanaged.passUnretained(event)
    }
    return filter.shouldSuppress(type: type, event: event)
        ? nil : Unmanaged.passUnretained(event)
}

final class RemoteEventFilter: @unchecked Sendable {
    static let syntheticMarker: Int64 = 0x49505243
    private static let logger = Logger(subsystem: "local.iprc1000.adapter", category: "EventFilter")
    var onRepeat: @Sendable (CGKeyCode) -> Void = { _ in }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var correlator = RemoteEventCorrelator()
    private let lock = NSLock()

    var isActive: Bool { tap != nil }

    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: remoteEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func note(usage: UInt8, isDown: Bool, hidTimestamp: UInt64) {
        guard let keyCode = Self.virtualKeyCode(for: usage) else { return }
        lock.lock()
        correlator.note(keyCode: keyCode, isDown: isDown, timestamp: hidTimestamp)
        lock.unlock()
    }

    fileprivate func shouldSuppress(type: CGEventType, event: CGEvent) -> Bool {
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker { return false }
        guard type == .keyDown || type == .keyUp else { return false }
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        lock.lock()
        let matched = correlator.consume(
            keyCode: keyCode,
            isDown: type == .keyDown,
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            timestamp: event.timestamp
        )
        lock.unlock()
        if matched, type == .keyDown,
           event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            onRepeat(keyCode)
        }
        if matched {
            Self.logger.notice(
                "CG key=\(keyCode, privacy: .public) down=\(type == .keyDown, privacy: .public) repeat=\(event.getIntegerValueField(.keyboardEventAutorepeat) != 0, privacy: .public) timestamp=\(event.timestamp, privacy: .public) suppress=\(matched, privacy: .public)"
            )
        }
        return matched
    }

    fileprivate func enable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    static func virtualKeyCode(for usage: UInt8) -> CGKeyCode? {
        switch usage {
        case 0x04: 0   // A
        case 0x05: 11  // B
        case 0x06: 8   // C
        case 0x07: 2   // D
        case 0x08: 14  // E
        case 0x09: 3   // F
        case 0x0A: 5   // G
        case 0x0B: 4   // H
        case 0x0C: 34  // I (spurious release report)
        case 0x0D: 38  // J
        case 0x10: 46  // M
        case 0x11: 45  // N
        case 0x16: 1   // S
        case 0x17: 17  // T
        case 0x19: 9   // V
        case 0x1F: 19  // 2
        case 0x20: 20  // 3
        case 0x28: 36  // Return
        case 0x31: 42  // Backslash
        case 0x36: 43  // Comma
        case 0x4F: 124 // Right
        case 0x50: 123 // Left
        case 0x51: 125 // Down
        case 0x52: 126 // Up
        default: nil
        }
    }

}
