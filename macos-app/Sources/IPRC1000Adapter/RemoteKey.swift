import AppKit
import Foundation

enum RemoteKey: UInt8, CaseIterable, Codable, Identifiable {
    case power = 0x17
    case back = 0x09
    case menu = 0x11
    case home = 0x07
    case info = 0x0B
    case ok = 0x28
    case up = 0x52
    case left = 0x50
    case right = 0x4F
    case down = 0x51
    case heart = 0x08
    case microphone = 0x10
    case person = 0x0D
    case playPause = 0x31
    case fastForward = 0x19
    case rewind = 0x36
    case channelUp = 0x04
    case channelDown = 0x05
    case volumeDown = 0x20
    case volumeUp = 0x1F
    case mute = 0x0A
    case last = 0x06
    case unknown16 = 0x16

    var id: UInt8 { rawValue }

    var title: String {
        switch self {
        case .power: "电源"
        case .back: "返回"
        case .menu: "菜单"
        case .home: "退出 / Home"
        case .info: "信息"
        case .ok: "确认"
        case .up: "上"
        case .left: "左"
        case .right: "右"
        case .down: "下"
        case .heart: "爱心"
        case .microphone: "麦克风"
        case .person: "用户"
        case .playPause: "播放 / 暂停"
        case .fastForward: "快进"
        case .rewind: "快退"
        case .channelUp: "频道 +"
        case .channelDown: "频道 -"
        case .volumeDown: "音量 -"
        case .volumeUp: "音量 +"
        case .mute: "静音"
        case .last: "上一个"
        case .unknown16: "方块键 / 配置切换"
        }
    }

}

private enum LegacyKeyAction: String, Codable {
    case none
    case escape
    case enter
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight
    case browserBack
    case menuBar
    case space
    case pageUp
    case pageDown
    case appSwitcher
    case lockScreen
    case playPause
    case nextTrack
    case previousTrack
    case volumeUp
    case volumeDown
    case mute

}

enum KeyModifier: String, CaseIterable, Codable, Identifiable {
    case control
    case option
    case shift
    case command
    case function

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        case .command: "⌘"
        case .function: "fn"
        }
    }

    var eventFlag: CGEventFlags {
        switch self {
        case .control: .maskControl
        case .option: .maskAlternate
        case .shift: .maskShift
        case .command: .maskCommand
        case .function: .maskSecondaryFn
        }
    }

    var keyCode: CGKeyCode {
        switch self {
        case .control: 59
        case .option: 58
        case .shift: 56
        case .command: 55
        case .function: 63
        }
    }

    func eventType(isDown: Bool) -> CGEventType {
        .flagsChanged
    }
}

enum MediaKey: String, Codable {
    case playPause
    case nextTrack
    case previousTrack
    case volumeUp
    case volumeDown
    case mute

    var title: String {
        switch self {
        case .playPause: "播放 / 暂停"
        case .nextTrack: "下一首"
        case .previousTrack: "上一首"
        case .volumeUp: "音量 +"
        case .volumeDown: "音量 -"
        case .mute: "静音"
        }
    }
}

struct MacKey: Identifiable, Hashable {
    let keyCode: UInt16
    let label: String
    let width: CGFloat

    var id: UInt16 { keyCode }

    init(_ keyCode: UInt16, _ label: String, width: CGFloat = 1) {
        self.keyCode = keyCode
        self.label = label
        self.width = width
    }
}

enum MacKeyboard {
    static let rows: [[MacKey]] = [
        [
            MacKey(53, "Esc", width: 1.4), MacKey(122, "F1"), MacKey(120, "F2"),
            MacKey(99, "F3"), MacKey(118, "F4"), MacKey(96, "F5"), MacKey(97, "F6"),
            MacKey(98, "F7"), MacKey(100, "F8"), MacKey(101, "F9"), MacKey(109, "F10"),
            MacKey(103, "F11"), MacKey(111, "F12")
        ],
        [
            MacKey(50, "`"), MacKey(18, "1"), MacKey(19, "2"), MacKey(20, "3"),
            MacKey(21, "4"), MacKey(23, "5"), MacKey(22, "6"), MacKey(26, "7"),
            MacKey(28, "8"), MacKey(25, "9"), MacKey(29, "0"), MacKey(27, "-"),
            MacKey(24, "="), MacKey(51, "⌫", width: 1.7)
        ],
        [
            MacKey(48, "Tab", width: 1.5), MacKey(12, "Q"), MacKey(13, "W"),
            MacKey(14, "E"), MacKey(15, "R"), MacKey(17, "T"), MacKey(16, "Y"),
            MacKey(32, "U"), MacKey(34, "I"), MacKey(31, "O"), MacKey(35, "P"),
            MacKey(33, "["), MacKey(30, "]"), MacKey(42, "\\", width: 1.2)
        ],
        [
            MacKey(57, "Caps", width: 1.8), MacKey(0, "A"), MacKey(1, "S"),
            MacKey(2, "D"), MacKey(3, "F"), MacKey(5, "G"), MacKey(4, "H"),
            MacKey(38, "J"), MacKey(40, "K"), MacKey(37, "L"), MacKey(41, ";"),
            MacKey(39, "'"), MacKey(36, "Return", width: 2.1)
        ],
        [
            MacKey(6, "Z"), MacKey(7, "X"), MacKey(8, "C"), MacKey(9, "V"),
            MacKey(11, "B"), MacKey(45, "N"), MacKey(46, "M"), MacKey(43, ","),
            MacKey(47, "."), MacKey(44, "/")
        ],
        [MacKey(49, "空格", width: 7)]
    ]

    static let extendedRows: [[MacKey]] = [
        [
            MacKey(114, "Help"), MacKey(115, "Home"), MacKey(119, "End"),
            MacKey(116, "Page ↑"), MacKey(121, "Page ↓"), MacKey(117, "⌦")
        ],
        [
            MacKey(123, "←"), MacKey(126, "↑"), MacKey(125, "↓"), MacKey(124, "→")
        ],
        [
            MacKey(105, "F13"), MacKey(107, "F14"), MacKey(113, "F15"),
            MacKey(106, "F16"), MacKey(64, "F17"), MacKey(79, "F18"),
            MacKey(80, "F19"), MacKey(90, "F20")
        ],
        [
            MacKey(71, "Clear"), MacKey(81, "="), MacKey(75, "/"), MacKey(67, "*"),
            MacKey(78, "-"), MacKey(69, "+"), MacKey(82, "0"), MacKey(83, "1")
        ],
        [
            MacKey(84, "2"), MacKey(85, "3"), MacKey(86, "4"), MacKey(87, "5"),
            MacKey(88, "6"), MacKey(89, "7"), MacKey(91, "8"), MacKey(92, "9"),
            MacKey(65, "."), MacKey(76, "Enter")
        ]
    ]

    static let allKeys = (rows + extendedRows).flatMap { $0 }

    static func label(for keyCode: UInt16) -> String {
        allKeys.first(where: { $0.keyCode == keyCode })?.label ?? "KeyCode \(keyCode)"
    }
}

struct KeyBinding: Codable, Equatable {
    enum Kind: String, Codable {
        case none
        case keyboard
        case media
    }

    var kind: Kind
    var keyCode: UInt16?
    var modifiers: Set<KeyModifier>
    var mediaKey: MediaKey?

    private init(kind: Kind, keyCode: UInt16?, modifiers: Set<KeyModifier>, mediaKey: MediaKey?) {
        self.kind = kind
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.mediaKey = mediaKey
    }

    static let none = KeyBinding(kind: .none, keyCode: nil, modifiers: [], mediaKey: nil)

    static func keyboard(_ keyCode: UInt16, modifiers: Set<KeyModifier> = []) -> KeyBinding {
        KeyBinding(kind: .keyboard, keyCode: keyCode, modifiers: modifiers, mediaKey: nil)
    }

    static func modifierOnly(_ modifiers: Set<KeyModifier>) -> KeyBinding {
        KeyBinding(kind: .keyboard, keyCode: nil, modifiers: modifiers, mediaKey: nil)
    }

    static func media(_ mediaKey: MediaKey) -> KeyBinding {
        KeyBinding(kind: .media, keyCode: nil, modifiers: [], mediaKey: mediaKey)
    }

    var title: String {
        switch kind {
        case .none: return "不执行"
        case .media: return mediaKey?.title ?? "媒体键"
        case .keyboard:
            let prefix = KeyModifier.allCases
                .filter { modifiers.contains($0) }
                .map(\.symbol)
                .joined()
            guard let keyCode else { return prefix.isEmpty ? "未选择按键" : prefix }
            return prefix + MacKeyboard.label(for: keyCode)
        }
    }

    var repeatsWhileHeld: Bool {
        switch kind {
        case .keyboard: keyCode != nil
        case .media: mediaKey == .volumeUp || mediaKey == .volumeDown
        case .none: false
        }
    }

    var requiresReleaseEvent: Bool {
        kind == .keyboard && keyCode == nil && !modifiers.isEmpty
    }

    var isFunctionOnly: Bool {
        kind == .keyboard && keyCode == nil && modifiers == [.function]
    }

    fileprivate init(legacy: LegacyKeyAction) {
        switch legacy {
        case .none: self = .none
        case .escape: self = .keyboard(53)
        case .enter: self = .keyboard(36)
        case .arrowUp: self = .keyboard(126)
        case .arrowDown: self = .keyboard(125)
        case .arrowLeft: self = .keyboard(123)
        case .arrowRight: self = .keyboard(124)
        case .browserBack: self = .keyboard(33, modifiers: [.command])
        case .menuBar: self = .keyboard(120, modifiers: [.control])
        case .space: self = .keyboard(49)
        case .pageUp: self = .keyboard(116)
        case .pageDown: self = .keyboard(121)
        case .appSwitcher: self = .keyboard(48, modifiers: [.command])
        case .lockScreen: self = .keyboard(12, modifiers: [.control, .command])
        case .playPause: self = .media(.playPause)
        case .nextTrack: self = .media(.nextTrack)
        case .previousTrack: self = .media(.previousTrack)
        case .volumeUp: self = .media(.volumeUp)
        case .volumeDown: self = .media(.volumeDown)
        case .mute: self = .media(.mute)
        }
    }
}

enum HIDReportParser {
    /// 键盘报告的 report ID（本遥控器实测为 1）。只有它代表按键状态。
    static let keyboardReportID = 1

    static func rawUsages(from report: [UInt8], reportID: Int = 1) -> Set<UInt8> {
        guard reportID == keyboardReportID else { return [] }
        let payload = report.count == 9 && report.first == 1
            ? Array(report.dropFirst()) : report
        guard payload.count >= 8 else { return [] }
        // Bytes 0/1 are modifier and reserved; bytes 2...7 are key usages.
        return Set(payload[2..<8].filter { $0 != 0 })
    }

    static func usages(from report: [UInt8], reportID: Int = 1) -> Set<UInt8> {
        rawUsages(from: report, reportID: reportID).subtracting([0x0C])
    }
}

@MainActor
final class MappingStore: ObservableObject {
    struct Profile: Identifiable, Equatable {
        let id: UUID
        var name: String
        var values: [RemoteKey: KeyBinding]
    }

    private struct StoredProfile: Codable {
        let id: UUID
        var name: String
        var bindings: [String: KeyBinding]
    }

    private struct ConfigurationFile: Codable {
        let version: Int
        var profiles: [StoredProfile]
    }

    @Published var values: [RemoteKey: KeyBinding] {
        didSet {
            guard !isLoading, let index = profiles.firstIndex(where: { $0.id == activeProfileID }) else { return }
            profiles[index].values = values
            save()
        }
    }
    @Published private(set) var profiles: [Profile]
    @Published private(set) var activeProfileID: UUID {
        didSet {
            guard !isLoading, let profile = activeProfile else { return }
            isLoading = true
            values = profile.values
            isLoading = false
            save()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.userDefaults = defaults
        if let data = defaults.data(forKey: "mappingProfilesV1"),
           let stored = try? JSONDecoder().decode([StoredProfile].self, from: data),
           !stored.isEmpty {
            var loadedProfiles = stored.map(Self.profile(from:))
            if let index = loadedProfiles.firstIndex(where: { $0.name == "默认配置" }) {
                loadedProfiles[index].name = "默认配置组 1"
            }
            if !defaults.bool(forKey: "codexProfileSeededV1"),
               !loadedProfiles.contains(where: { $0.name == "Codex 编程" }) {
                loadedProfiles.append(Self.codexProfile())
            }
            let savedID = defaults.string(forKey: "activeMappingProfileID").flatMap(UUID.init(uuidString:))
            let loadedActiveID = loadedProfiles.contains(where: { $0.id == savedID })
                ? savedID! : loadedProfiles[0].id
            profiles = loadedProfiles
            activeProfileID = loadedActiveID
            values = loadedProfiles.first(where: { $0.id == loadedActiveID })!.values
        } else if let data = defaults.data(forKey: "keyBindings"),
           let raw = try? JSONDecoder().decode([String: KeyBinding].self, from: data) {
            var migrated = Self.defaults
            for (key, binding) in raw {
                if let usage = UInt8(key), let remoteKey = RemoteKey(rawValue: usage) {
                    migrated[remoteKey] = binding
                }
            }
            let profile = Profile(id: UUID(), name: "默认配置组 1", values: migrated)
            profiles = [profile, Self.codexProfile()]
            activeProfileID = profile.id
            values = migrated
        } else if let data = defaults.data(forKey: "keyMappings"),
                  let raw = try? JSONDecoder().decode([String: LegacyKeyAction].self, from: data) {
            var migrated = Self.defaults
            for (key, action) in raw {
                if let usage = UInt8(key), let remoteKey = RemoteKey(rawValue: usage) {
                    migrated[remoteKey] = KeyBinding(legacy: action)
                }
            }
            let profile = Profile(id: UUID(), name: "默认配置组 1", values: migrated)
            profiles = [profile, Self.codexProfile()]
            activeProfileID = profile.id
            values = migrated
        } else {
            let profile = Profile(id: UUID(), name: "默认配置组 1", values: Self.defaults)
            profiles = [profile, Self.codexProfile()]
            activeProfileID = profile.id
            values = Self.defaults
        }
        defaults.set(true, forKey: "codexProfileSeededV1")
        save()
    }

    private let userDefaults: UserDefaults
    private var isLoading = false

    var activeProfile: Profile? { profiles.first(where: { $0.id == activeProfileID }) }

    func selectProfile(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        activeProfileID = id
    }

    @discardableResult
    func selectNextProfile() -> String? {
        guard profiles.count > 1,
              let index = profiles.firstIndex(where: { $0.id == activeProfileID }) else { return nil }
        let profile = profiles[(index + 1) % profiles.count]
        activeProfileID = profile.id
        return profile.name
    }

    func addProfile() {
        let profile = Profile(id: UUID(), name: nextDefaultProfileName(), values: values)
        profiles.append(profile)
        activeProfileID = profile.id
    }

    func renameProfile(_ id: UUID, to requestedName: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        let name = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        profiles[index].name = name
        save()
    }

    func deleteActiveProfile() {
        guard profiles.count > 1,
              let index = profiles.firstIndex(where: { $0.id == activeProfileID }) else { return }
        profiles.remove(at: index)
        activeProfileID = profiles[min(index, profiles.count - 1)].id
    }

    func exportActiveProfileData() throws -> Data {
        guard let activeProfile else { throw ConfigurationError.invalidFile }
        let file = ConfigurationFile(version: 1, profiles: [Self.stored(from: activeProfile)])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }

    func importIntoActiveProfile(_ data: Data) throws {
        let file = try JSONDecoder().decode(ConfigurationFile.self, from: data)
        guard file.version == 1, let stored = file.profiles.first else {
            throw ConfigurationError.invalidFile
        }
        values = Self.profile(from: stored).values
    }

    func reset() {
        values = activeProfile?.name == "Codex 编程" ? Self.codexDefaults : Self.defaults
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profiles.map(Self.stored(from:))) {
            userDefaults.set(data, forKey: "mappingProfilesV1")
            userDefaults.set(activeProfileID.uuidString, forKey: "activeMappingProfileID")
        }
    }

    private func nextDefaultProfileName() -> String {
        let existing = Set(profiles.map(\.name))
        var number = 1
        while existing.contains("默认配置组 \(number)") { number += 1 }
        return "默认配置组 \(number)"
    }

    private static func stored(from profile: Profile) -> StoredProfile {
        StoredProfile(
            id: profile.id,
            name: profile.name,
            bindings: Dictionary(uniqueKeysWithValues: profile.values.map { (String($0.key.rawValue), $0.value) })
        )
    }

    private static func profile(from stored: StoredProfile) -> Profile {
        var values = defaults
        for (key, binding) in stored.bindings {
            if let usage = UInt8(key), let remoteKey = RemoteKey(rawValue: usage) {
                values[remoteKey] = binding
            }
        }
        return Profile(id: stored.id, name: stored.name, values: values)
    }

    private static func codexProfile() -> Profile {
        Profile(id: UUID(), name: "Codex 编程", values: codexDefaults)
    }

    enum ConfigurationError: LocalizedError {
        case invalidFile
        var errorDescription: String? { "配置文件版本不受支持或不包含任何配置组。" }
    }

    static let defaults: [RemoteKey: KeyBinding] = [
        .power: .keyboard(12, modifiers: [.control, .command]),
        .back: .keyboard(33, modifiers: [.command]),
        .menu: .keyboard(120, modifiers: [.control]),
        .home: .keyboard(53), .info: .keyboard(49), .ok: .keyboard(36),
        .up: .keyboard(126), .down: .keyboard(125),
        .left: .keyboard(123), .right: .keyboard(124),
        .heart: .none, .person: .none,
        // 麦克风键默认发「Fn」：直接对上豆包输入法的默认语音键（长按说话）
        .microphone: .modifierOnly([.function]),
        .playPause: .media(.playPause), .fastForward: .media(.nextTrack),
        .rewind: .media(.previousTrack),
        .channelUp: .keyboard(116), .channelDown: .keyboard(121),
        .volumeUp: .media(.volumeUp), .volumeDown: .media(.volumeDown),
        .mute: .media(.mute),
        .last: .keyboard(48, modifiers: [.command]), .unknown16: .none
    ]

    static let codexDefaults: [RemoteKey: KeyBinding] = [
        .power: .keyboard(12, modifiers: [.control, .command]),
        .back: .keyboard(53),
        .menu: .keyboard(35, modifiers: [.command, .shift]),
        .home: .keyboard(45, modifiers: [.command]),
        .info: .keyboard(3, modifiers: [.command]),
        .ok: .keyboard(36),
        .up: .keyboard(126), .down: .keyboard(125),
        .left: .keyboard(123), .right: .keyboard(124),
        .heart: .keyboard(1, modifiers: [.command]),
        .person: .keyboard(43, modifiers: [.command]),
        // 麦克风键默认发「Fn」（豆包输入法的默认语音键）
        .microphone: .modifierOnly([.function]),
        .playPause: .keyboard(49),
        .fastForward: .keyboard(48),
        .rewind: .keyboard(48, modifiers: [.shift]),
        .channelUp: .keyboard(116), .channelDown: .keyboard(121),
        .volumeUp: .media(.volumeUp), .volumeDown: .media(.volumeDown),
        .mute: .media(.mute),
        .last: .keyboard(17, modifiers: [.command, .shift]),
        .unknown16: .none
    ]
}
