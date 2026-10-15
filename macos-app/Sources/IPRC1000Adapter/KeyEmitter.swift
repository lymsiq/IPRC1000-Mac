import AppKit
import CoreGraphics
import IOKit.hidsystem
import os

enum KeyEmitter {
    static let functionVirtualKey: CGKeyCode = 63
    private static let logger = Logger(subsystem: "local.iprc1000.adapter", category: "KeyEmitter")
    static func emit(_ binding: KeyBinding) {
        KeyTrace.log("      ↳ 准备发出：\(binding.title)  kind=\(binding.kind.rawValue)")
        if binding.isFunctionOnly {
            functionEvent(isDown: true)
            return
        }
        switch binding.kind {
        case .none:
            return
        case .keyboard:
            if let keyCode = binding.keyCode {
                let flags = binding.modifiers.reduce(CGEventFlags()) {
                    $0.union($1.eventFlag)
                }
                keyboard(CGKeyCode(keyCode), flags: flags)
            } else {
                modifierKeysDown(binding.modifiers)
            }
        case .media:
            switch binding.mediaKey {
            case .playPause: media(NX_KEYTYPE_PLAY)
            case .nextTrack: media(NX_KEYTYPE_NEXT)
            case .previousTrack: media(NX_KEYTYPE_PREVIOUS)
            case .volumeUp: media(NX_KEYTYPE_SOUND_UP)
            case .volumeDown: media(NX_KEYTYPE_SOUND_DOWN)
            case .mute: media(NX_KEYTYPE_MUTE)
            case nil: return
            }
        }
    }

    static func emitRepeat(_ binding: KeyBinding) {
        guard binding.repeatsWhileHeld else { return }
        emit(binding)
    }

    static func release(_ binding: KeyBinding) {
        guard binding.requiresReleaseEvent else { return }
        if binding.isFunctionOnly {
            functionEvent(isDown: false)
            return
        }
        modifierKeysUp(binding.modifiers)
    }

    private static func functionEvent(isDown: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: functionVirtualKey,
            keyDown: false
        ) else { return }
        event.type = .flagsChanged
        event.flags = isDown ? .maskSecondaryFn : []
        logger.notice("synthetic Fn flagsChanged down=\(isDown, privacy: .public) keyCode=63")
        post(event)
    }

    /// 发出一个（可能带修饰键的）组合键。
    ///
    /// ⚠ **必须真的按下/松开修饰键**（`.flagsChanged` 事件），不能只在按键事件上填 `flags`。
    /// 只填 flags 时，一部分应用 —— 尤其 Electron / 自绘快捷键表的应用 ——
    /// 根本收不到这个组合键，表现就是"按了没反应"。这里按真实键盘的
    /// 修饰键按下 → 按键按下/抬起 → 修饰键松开的顺序投递。
    private static func keyboard(_ code: CGKeyCode, flags: CGEventFlags = []) {
        KeyTrace.log("        → 投递 keyCode=\(code) flags=0x\(String(flags.rawValue, radix: 16))")
        let source = CGEventSource(stateID: .hidSystemState)
        let modifiers = KeyModifier.allCases.filter { flags.contains($0.eventFlag) }

        var running = CGEventFlags()
        for modifier in modifiers {          // 按下修饰键
            running.insert(modifier.eventFlag)
            KeyTrace.log("          · 按下 \(modifier.rawValue)")
            postModifier(modifier, down: true, flags: running, source: source)
        }
        for down in [true, false] {          // 按键本身
            guard let event = CGEvent(
                keyboardEventSource: source, virtualKey: code, keyDown: down
            ) else { continue }
            event.flags = flags
            post(event)
        }
        for modifier in modifiers.reversed() {   // 逆序松开修饰键
            running.remove(modifier.eventFlag)
            KeyTrace.log("          · 松开 \(modifier.rawValue)")
            postModifier(modifier, down: false, flags: running, source: source)
        }
    }

    private static func postModifier(
        _ modifier: KeyModifier, down: Bool, flags: CGEventFlags, source: CGEventSource?
    ) {
        guard let event = CGEvent(
            keyboardEventSource: source, virtualKey: modifier.keyCode, keyDown: false
        ) else { return }
        event.type = .flagsChanged
        event.flags = flags
        post(event)
    }

    private static func modifierKeysDown(_ modifiers: Set<KeyModifier>) {
        let ordered = KeyModifier.allCases.filter { modifiers.contains($0) }
        let source = CGEventSource(stateID: .hidSystemState)
        var flags = CGEventFlags()

        for modifier in ordered {
            flags.insert(modifier.eventFlag)
            guard let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: modifier.keyCode,
                keyDown: true
            ) else { continue }
            event.type = modifier.eventType(isDown: true)
            event.flags = flags
            post(event)
        }
    }

    private static func modifierKeysUp(_ modifiers: Set<KeyModifier>) {
        let ordered = KeyModifier.allCases.filter { modifiers.contains($0) }
        let source = CGEventSource(stateID: .hidSystemState)
        var flags = modifiers.reduce(CGEventFlags()) { $0.union($1.eventFlag) }
        for modifier in ordered.reversed() {
            flags.remove(modifier.eventFlag)
            guard let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: modifier.keyCode,
                keyDown: false
            ) else { continue }
            event.type = modifier.eventType(isDown: false)
            event.flags = flags
            post(event)
        }
    }

    private static func post(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: RemoteEventFilter.syntheticMarker)
        event.post(tap: .cghidEventTap)
    }

    private static func media(_ key: Int32) {
        for down in [true, false] {
            let flags = down ? 0xA : 0xB
            let data1 = Int((key << 16) | Int32(flags << 8))
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: down ? [] : .deviceIndependentFlagsMask,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS),
                data1: data1,
                data2: -1
            )?.cgEvent
            event?.setIntegerValueField(.eventSourceUserData, value: RemoteEventFilter.syntheticMarker)
            event?.post(tap: .cghidEventTap)
        }
    }
}
