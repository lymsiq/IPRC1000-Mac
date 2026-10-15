import Foundation

@MainActor
enum SelfTest {
    /// 造一帧与真机一致的 653 字节 HID 音频报告：
    /// `A1 F7 01 <seq> 00 <rolling> <n> <cnt> 00 00 00 40 01 | 640B PCM`
    /// （`rolling` = 0x42, 0x82, 0xC2… 每帧 +0x40；`cnt` 每帧 +9 —— 都会变，
    ///   所以匹配器只能认 `A1 F7 01` + `[4]==0` + 尾部 `00 00 00 40 01`。）
    static func makeSyntheticFrame(sequence: UInt8) -> [UInt8] {
        var frame: [UInt8] = [
            0xA1, 0xF7, 0x01, sequence, 0x00,
            0x42 &+ sequence &* 0x40, 0x00, sequence &* 9,
            0x00, 0x00, 0x00, 0x40, 0x01
        ]
        for index in 0..<320 {
            let value = Int16(truncatingIfNeeded: index &* 97 &+ Int(sequence) &* 13)
            frame.append(UInt8(truncatingIfNeeded: value))
            frame.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        return frame
    }

    static func run() -> Bool {
        var failures: [String] = []
        check(HIDReportParser.usages(from: [1, 0, 0, 0x52, 0, 0, 0, 0, 0]) == [0x52],
              "HID report ID parsing", into: &failures)
        check(HIDReportParser.usages(from: [1, 0, 0, 0x0C, 0, 0, 0, 0, 0]).isEmpty,
              "spurious 0x0C filter", into: &failures)
        check(HIDReportParser.rawUsages(from: [1, 0, 0, 0x0C, 0, 0, 0, 0, 0]) == [0x0C],
              "raw spurious 0x0C capture", into: &failures)
        check(HIDReportParser.usages(from: [0, 0, 0x28, 0, 0, 0, 0, 0]) == [0x28],
              "HID payload parsing", into: &failures)
        check(TargetRemote.matches(
            vendorID: 0x0A5C, productID: 0x8502, productName: "IPRC1000"
        ), "target model matching", into: &failures)
        check(TargetRemote.matches(
            vendorID: 0x0A5C, productID: 0x8502, productName: "Broadcom Bluetooth Wireless Remote Control"
        ), "same-model product-name variation acceptance", into: &failures)
        check(!TargetRemote.matches(
            vendorID: 0x05AC, productID: 0x0342, productName: "Apple Keyboard"
        ), "other keyboard rejection", into: &failures)
        check(!TargetRemote.matches(
            vendorID: 0x0A5C, productID: 0x8503, productName: "IPRC1000"
        ), "other product rejection", into: &failures)
        check(RemoteKey.allCases.allSatisfy {
            RemoteEventFilter.virtualKeyCode(for: $0.rawValue) != nil
        }, "all remote usages have source key codes", into: &failures)
        check(RemoteEventFilter.virtualKeyCode(for: 0x0C) == 34,
              "spurious i source key code", into: &failures)
        let artworkCanvas = CGRect(origin: .zero, size: RemoteKeyArtwork.canvasSize)
        check(RemoteKey.allCases.allSatisfy {
            artworkCanvas.contains(RemoteKeyArtwork.rect(for: $0))
        }, "all remote keys have in-bounds artwork regions", into: &failures)
        var correlator = RemoteEventCorrelator()
        correlator.note(keyCode: 34, isDown: true, timestamp: 1_000_000_000)
        check(!correlator.consume(
            keyCode: 0, isDown: true, isRepeat: false, timestamp: 1_000_000_100
        ),
              "other keyboard key is not filtered", into: &failures)
        check(correlator.consume(
            keyCode: 34, isDown: true, isRepeat: false, timestamp: 1_050_000_000
        ),
              "device-correlated delayed spurious i is filtered", into: &failures)
        check(correlator.consume(
            keyCode: 34, isDown: true, isRepeat: true, timestamp: 1_100_000_000
        ), "spurious i autorepeat is filtered", into: &failures)
        check(!correlator.consume(
            keyCode: 34, isDown: true, isRepeat: false, timestamp: 1_100_000_100
        ), "physical keyboard i is not filtered", into: &failures)
        check(!correlator.consume(
            keyCode: 34, isDown: true, isRepeat: true, timestamp: 1_110_000_000
        ), "physical keyboard i autorepeat is not filtered", into: &failures)
        check(!correlator.consume(
            keyCode: 34, isDown: false, isRepeat: false, timestamp: 1_120_000_000
        ), "physical keyboard i release is not filtered", into: &failures)
        check(correlator.consume(
            keyCode: 34, isDown: true, isRepeat: true, timestamp: 1_130_000_000
        ), "remote i autorepeat resumes after physical i release", into: &failures)
        correlator.note(keyCode: 34, isDown: false, timestamp: 1_200_000_000)
        check(correlator.consume(
            keyCode: 34, isDown: false, isRepeat: false, timestamp: 1_200_000_100
        ), "spurious i release is filtered", into: &failures)
        check(!correlator.consume(
            keyCode: 34, isDown: true, isRepeat: true, timestamp: 1_300_000_000
        ), "spurious i autorepeat stops after release", into: &failures)

        let shortcut = KeyBinding.keyboard(
            1, modifiers: [.control, .option, .shift, .command, .function]
        )
        check(shortcut.title == "⌃⌥⇧⌘fnS", "five-modifier shortcut title", into: &failures)
        if let encoded = try? JSONEncoder().encode(shortcut),
           let decoded = try? JSONDecoder().decode(KeyBinding.self, from: encoded) {
            check(decoded == shortcut, "shortcut persistence round trip", into: &failures)
        } else {
            failures.append("shortcut persistence round trip")
        }
        let fnOnly = KeyBinding.modifierOnly([.function])
        check(fnOnly.title == "fn", "standalone Fn title", into: &failures)
        check(fnOnly.kind == .keyboard && fnOnly.keyCode == nil,
              "standalone Fn representation", into: &failures)
        check(KeyModifier.function.keyCode == 63, "standalone Fn key code", into: &failures)
        check(KeyModifier.function.eventType(isDown: true) == .flagsChanged
              && KeyModifier.function.eventType(isDown: false) == .flagsChanged,
              "standalone Fn uses flags changed events", into: &failures)
        check(KeyModifier.command.eventType(isDown: true) == .flagsChanged,
              "standard modifiers use flags changed events", into: &failures)
        check(shortcut.repeatsWhileHeld, "keyboard shortcut repeats while held", into: &failures)
        check(!fnOnly.repeatsWhileHeld, "standalone Fn remains held without repeat reports", into: &failures)
        check(fnOnly.requiresReleaseEvent, "standalone Fn keeps a release lifecycle", into: &failures)
        check(fnOnly.isFunctionOnly, "standalone Fn uses sticky lifecycle", into: &failures)
        check(!shortcut.requiresReleaseEvent, "keyboard shortcut does not use modifier release", into: &failures)
        check(KeyBinding.media(.volumeUp).repeatsWhileHeld,
              "volume media key repeats while held", into: &failures)
        check(!KeyBinding.media(.playPause).repeatsWhileHeld,
              "play pause does not repeat while held", into: &failures)
        check(HIDController.repeatingKey(for: 126, pressed: [0x52]) == .up,
              "held remote key resolves from suppressed repeat", into: &failures)
        check(HIDController.repeatingKey(for: 34, pressed: [0x0C]) == nil,
              "spurious i repeat is never translated", into: &failures)
        if let encoded = try? JSONEncoder().encode(fnOnly),
           let decoded = try? JSONDecoder().decode(KeyBinding.self, from: encoded) {
            check(decoded == fnOnly, "standalone Fn persistence round trip", into: &failures)
        } else {
            failures.append("standalone Fn persistence round trip")
        }
        check(MappingStore.defaults[.microphone] == .modifierOnly([.function]),
              "microphone mapping defaults to Fn (Doubao voice key)", into: &failures)

        let suiteName = "local.iprc1000.adapter.selftest.\(UUID().uuidString)"
        if let defaults = UserDefaults(suiteName: suiteName) {
            defaults.set(Data(#"{"82":"arrowUp","6":"appSwitcher"}"#.utf8),
                         forKey: "keyMappings")
            let migrated = MappingStore(defaults: defaults)
            check(migrated.values[.up] == .keyboard(126),
                  "legacy arrow mapping migration", into: &failures)
            check(migrated.values[.last] == .keyboard(48, modifiers: [.command]),
                  "legacy shortcut mapping migration", into: &failures)
            check(migrated.activeProfile?.name == "默认配置组 1",
                  "legacy profile name migration", into: &failures)
            check(migrated.profiles.count == 2 && migrated.profiles[1].name == "Codex 编程",
                  "Codex programming profile seeding", into: &failures)
            check(MappingStore.codexDefaults[.menu] == .keyboard(35, modifiers: [.command, .shift])
                  && MappingStore.codexDefaults[.home] == .keyboard(45, modifiers: [.command])
                  && MappingStore.codexDefaults[.heart] == .keyboard(1, modifiers: [.command]),
                  "Codex programming shortcuts", into: &failures)
            check(migrated.selectNextProfile() == "Codex 编程"
                  && migrated.activeProfile?.name == "Codex 编程",
                  "reserved key advances to Codex profile", into: &failures)
            check(migrated.selectNextProfile() == "默认配置组 1"
                  && migrated.activeProfile?.name == "默认配置组 1",
                  "reserved key wraps to first profile", into: &failures)
            migrated.addProfile()
            check(migrated.activeProfile?.name == "默认配置组 2",
                  "automatic profile naming", into: &failures)
            let secondProfileID = migrated.activeProfileID
            migrated.renameProfile(secondProfileID, to: "演示")
            check(migrated.activeProfile?.name == "演示",
                  "profile renaming", into: &failures)
            migrated.values[.heart] = shortcut
            let firstProfileID = migrated.profiles[0].id
            migrated.selectProfile(firstProfileID)
            check(migrated.values[.heart] == KeyBinding.none,
                  "profile switching restores bindings", into: &failures)
            migrated.selectProfile(secondProfileID)
            check(migrated.values[.heart] == shortcut,
                  "profile switching preserves bindings", into: &failures)
            let reloaded = MappingStore(defaults: defaults)
            check(reloaded.profiles.count == 3 && reloaded.values[.heart] == shortcut,
                  "profile collection persistence", into: &failures)
            if let exported = try? migrated.exportActiveProfileData() {
                let importSuite = "local.iprc1000.adapter.importtest.\(UUID().uuidString)"
                if let importDefaults = UserDefaults(suiteName: importSuite) {
                    let destination = MappingStore(defaults: importDefaults)
                    try? destination.importIntoActiveProfile(exported)
                    check(destination.profiles.count == 2 && destination.values[.heart] == shortcut,
                          "active profile export and replacement import", into: &failures)
                    check(destination.activeProfile?.name == "默认配置组 1",
                          "import preserves selected profile name", into: &failures)
                    importDefaults.removePersistentDomain(forName: importSuite)
                } else {
                    failures.append("configuration import test defaults")
                }
            } else {
                failures.append("configuration export")
            }
            defaults.removePersistentDomain(forName: suiteName)
        } else {
            failures.append("legacy mapping test defaults")
        }
        let microphoneMap = [String(RemoteKey.microphone.rawValue): shortcut]
        if let data = try? JSONEncoder().encode(microphoneMap),
           let decoded = try? JSONDecoder().decode([String: KeyBinding].self, from: data) {
            check(decoded[String(RemoteKey.microphone.rawValue)] == shortcut,
                  "microphone custom shortcut persistence", into: &failures)
        } else {
            failures.append("microphone custom shortcut persistence")
        }

        let bytes = hex("""
            01 08 AD 00 00 37 65 54 34 33 7D DD AD 5F 77 6B 57 DD DA D5
            F7 76 B5 7D DD AD 5F 77 6B 57 5D DA D5 A9 74 B9 29 A5 92 09
            59 6B A1 71 DD 90 B4 55 51 32 21 0A 94 77 33 12 9A DC D4 00
            """)
        var state = VoicePacketAssembler.State()
        _ = VoicePacketAssembler.append(Array(bytes[0..<20]), to: &state)
        _ = VoicePacketAssembler.append(Array(bytes[20..<40]), to: &state)
        let frame = VoicePacketAssembler.append(Array(bytes[40..<60]), to: &state)
        check(frame?.count == 57 && frame?.prefix(4) == [0xAD, 0x00, 0x00, 0x37],
              "three-packet mSBC assembly", into: &failures)
        if let frame, let decoder = MSBCDecoder() {
            check(decoder.decode(frame)?.count == 120,
                  "official mSBC sample decodes to 120 samples", into: &failures)
        } else {
            failures.append("mSBC decoder initialization")
        }

        var adpcm = [UInt8](repeating: 0, count: 134)
        adpcm[5] = 0
        let adpcmPCM = GoogleVoiceADPCM.decode(adpcm)
        check(adpcmPCM?.count == 256 && adpcmPCM?.allSatisfy { $0 == 0 } == true,
              "Google Voice ADPCM packet decoding", into: &failures)

        // ── 我们**实际在用**的语音路径：从 HCI 流里抠 653 字节帧 ──────────────
        // 注意上面测的 mSBC / ADPCM 是原项目的实验解码器，跟这条链路无关；
        // 真正在跑的这条路径原先完全没有测试 —— 结果藏了一个数组越界崩溃。
        let frameA = makeSyntheticFrame(sequence: 0)
        let frameB = makeSyntheticFrame(sequence: 5)
        check(frameA.count == HCIVoiceReceiver.frameLength && frameB.count == 653,
              "synthetic HID audio frame is 653 bytes", into: &failures)

        // 跨包 + 前后都有垃圾：应能准确定位并抠出 2 帧
        var pool = [UInt8](repeating: 0xEE, count: 21) + frameA
            + [UInt8](repeating: 0xAA, count: 7) + frameB
            + [UInt8](repeating: 0x55, count: 5)
        let extracted = HCIVoiceReceiver.extractFrames(from: &pool)
        check(extracted.count == 2 && extracted[0] == frameA && extracted[1] == frameB,
              "HCI frame extraction locates both frames through noise", into: &failures)
        check(pool.count == 5,
              "HCI frame extraction stops at the last complete frame", into: &failures)

        // ★ 回归测试：签名在缓冲区尾部、但整帧不完整 —— 曾经会越界崩溃
        var truncated = [UInt8](repeating: 0xEE, count: 21) + frameA
        truncated.removeLast(100)          // 只剩 553 字节，不足 653
        let truncatedSize = truncated.count
        check(HCIVoiceReceiver.findFrameStart(truncated, from: 0) == nil,
              "incomplete trailing frame is not reported as a start (no out-of-bounds)", into: &failures)
        check(HCIVoiceReceiver.extractFrames(from: &truncated).isEmpty
                && truncated.count == truncatedSize,
              "incomplete frame stays buffered until more data arrives", into: &failures)

        // 缓冲里只有垃圾时不应产生帧，也不应无限增长
        var junk = [UInt8](repeating: 0x11, count: 4000)
        check(HCIVoiceReceiver.extractFrames(from: &junk).isEmpty && junk.count == 4000,
              "pure noise produces no frames", into: &failures)

        if failures.isEmpty {
            print("SELF-TEST PASS: model isolation, event filter, HID/voice decoders, HCI frame extraction, custom shortcuts and legacy mapping migration")
            return true
        }
        for failure in failures { FileHandle.standardError.write(Data("SELF-TEST FAIL: \(failure)\n".utf8)) }
        return false
    }

    private static func check(_ condition: Bool, _ label: String, into failures: inout [String]) {
        if !condition { failures.append(label) }
    }

    private static func hex(_ value: String) -> [UInt8] {
        value.split(whereSeparator: { $0.isWhitespace }).compactMap { UInt8($0, radix: 16) }
    }
}
