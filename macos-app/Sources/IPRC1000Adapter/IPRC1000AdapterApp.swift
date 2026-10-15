import IOBluetooth
import AppKit
import Darwin
import SwiftUI
import UniformTypeIdentifiers

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private let statusPopover = NSPopover()

    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            Darwin.exit(SelfTest.run() ? 0 : 1)
        }
        if CommandLine.arguments.contains("--diagnose") {
            Darwin.exit(DiagnosticRunner.run())
        }
        if let index = CommandLine.arguments.firstIndex(of: "--voice-diag") {
            let next = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : nil
            let seconds = next.flatMap(Double.init) ?? 30
            var wavPath: String? = "/tmp/iprc1000-voice.wav"
            if let wavIndex = CommandLine.arguments.firstIndex(of: "--wav"),
               CommandLine.arguments.count > wavIndex + 1 {
                wavPath = CommandLine.arguments[wavIndex + 1]
            }
            let verbose = !CommandLine.arguments.contains("--quiet")
            // 报告文件：用 `open -n --args` 让 **App 自己**跑诊断时（TCC 权限身份才正确），
            // stdout 拿不到，只能靠这个文件看结果。
            var reportPath: String? = "/tmp/iprc-voice-report.txt"
            if let reportIndex = CommandLine.arguments.firstIndex(of: "--report"),
               CommandLine.arguments.count > reportIndex + 1 {
                reportPath = CommandLine.arguments[reportIndex + 1] == "none"
                    ? nil : CommandLine.arguments[reportIndex + 1]
            }
            Darwin.exit(VoiceDiagnostic.run(
                seconds: seconds, verbose: verbose, wavPath: wavPath, reportPath: reportPath
            ))
        }
        if CommandLine.arguments.contains("--input-status")
            || CommandLine.arguments.contains("--input-blackhole")
            || CommandLine.arguments.contains("--input-restore") {
            let current = AudioInputSwitcher.defaultInput()
            let currentName = AudioInputSwitcher.deviceName(current)

            if CommandLine.arguments.contains("--input-blackhole") {
                guard let device = AudioInputSwitcher.findInputDevice(
                    named: AudioInputSwitcher.blackHoleNames
                ) else {
                    print("✗ 没找到 BlackHole 输入设备（请先运行 ./install.sh）")
                    Darwin.exit(1)
                }
                let ok = AudioInputSwitcher.setDefaultInput(device)
                print(ok ? "✅ 默认输入已切到 \(AudioInputSwitcher.deviceName(device))"
                         : "✗ 切换失败")
                Darwin.exit(ok ? 0 : 1)
            }

            if CommandLine.arguments.contains("--input-restore") {
                guard let device = AudioInputSwitcher.firstNonBlackHoleInput() else {
                    print("✗ 找不到非 BlackHole 的输入设备")
                    Darwin.exit(1)
                }
                let ok = AudioInputSwitcher.setDefaultInput(device)
                print(ok ? "✅ 默认输入已还原为 \(AudioInputSwitcher.deviceName(device))"
                         : "✗ 还原失败")
                Darwin.exit(ok ? 0 : 1)
            }

            print("当前默认输入：\(currentName)  (id=\(current))")
            print("可用输入设备：")
            for device in AudioInputSwitcher.allDevices() {
                let channels = AudioInputSwitcher.inputChannelCount(device)
                guard channels > 0 else { continue }
                let mark = device == current ? " ← 当前" : ""
                print("  · \(AudioInputSwitcher.deviceName(device))  (\(channels)ch)\(mark)")
            }
            Darwin.exit(0)
        }
        if CommandLine.arguments.contains("--reconnect") {
            // 断开并重连遥控器，让 macOS 重新建立 **HID ACL 通道**。
            //
            // 为什么需要：蓝牙层"已连接"不等于 HID 服务可用。实测遇到过
            // 遥控器在系统蓝牙里显示已连接、但 ioreg 里根本没有它的 IOHIDDevice
            // （IOBluetoothHIDDriver 也是 0 个）→ **所有按键都收不到**，
            // 看起来像"某个键坏了"，其实是整条 HID 通道没建起来。
            guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
                print("✗ 拿不到已配对设备列表")
                Darwin.exit(1)
            }
            let wanted = CommandLine.arguments.firstIndex(of: "--reconnect").flatMap { index in
                CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : nil
            }
            let candidates = paired.filter { device in
                guard let name = device.name else { return false }
                return name.localizedCaseInsensitiveContains(wanted ?? "IPRC1000")
            }
            guard let device = candidates.first else {
                print("✗ 没找到已配对的 \(wanted ?? "IPRC1000")")
                Darwin.exit(1)
            }
            print("目标：\(device.name ?? "?")  \(device.addressString ?? "?")"
                  + "  已连接=\(device.isConnected())")
            // 实测：一次 openConnection 常常 kIOReturnTimeout（遥控器没被唤醒），
            // 要retry几次才成。所以这里循环重试，并在每次之后检查 HID 设备是否真的出现。
            func connectedHIDCount() -> Int {
                let manager = IOHIDManagerCreate(kCFAllocatorDefault,
                                                 IOOptionBits(kIOHIDOptionsTypeNone))
                let matching: [String: Any] = [
                    kIOHIDVendorIDKey as String: TargetRemote.vendorID,
                    kIOHIDProductIDKey as String: TargetRemote.productID
                ]
                IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
                _ = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
                defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
                return (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>)?.count ?? 0
            }

            if connectedHIDCount() > 0 {
                print("✓ HID 设备已存在（\(connectedHIDCount()) 个），无需重连")
                Darwin.exit(0)
            }
            if device.isConnected() {
                print("→ 断开 …")
                print("  closeConnection rc=\(device.closeConnection())")
                Thread.sleep(forTimeInterval: 1.5)
            }
            var restored = false
            for attempt in 1...6 {
                print("→ 连接尝试 \(attempt)/6 …")
                let opened = device.openConnection()
                Thread.sleep(forTimeInterval: 2.5)
                let count = connectedHIDCount()
                print("  openConnection rc=\(opened)  已连接=\(device.isConnected())  HID 设备=\(count)")
                if count > 0 { restored = true; break }
            }
            print(restored ? "✅ 遥控器已重新建立 HID 通道，按键可用"
                           : "⚠️ 仍未建立，请按一下遥控器上的任意键唤醒它，或关机再开")
            print("（若按键仍无反应，把遥控器关机再开机，或到系统蓝牙里「忽略设备」后重新配对）")
            Darwin.exit(0)
        }
        if CommandLine.arguments.contains("--mapping") {
            // 打印当前**生效**的按键映射（自查用，不必开界面）
            // ⚠ 域的处理（踩过一次）：
            //   · 在 .app 里运行时，Bundle.main.bundleIdentifier 就是本 App 的域 → 用 .standard
            //     （这时再传 suiteName 会触发 AppKit 警告 "using your own bundle identifier
            //       as an NSUserDefaults suite name does not make sense"）
            //   · 直接跑 .build 里的裸二进制时，bundleIdentifier 为空 → .standard 会落到别的域、
            //     读到源码默认值（假数据）→ 必须显式指定域
            let domain = "local.iprc1000.adapter"
            let resolved: UserDefaults = Bundle.main.bundleIdentifier == domain
                ? .standard
                : (UserDefaults(suiteName: domain) ?? .standard)
            let store = MappingStore(defaults: resolved)
            print("=== 遥控器按键映射 ===")
            print("当前配置组：\(store.activeProfile?.name ?? "<无>")")
            print("")
            for key in RemoteKey.allCases {
                let binding = store.values[key] ?? .none
                print("  0x\(String(format: "%02X", key.rawValue))\t\(key.title)\t-> \(binding.title)")
            }
            if store.profiles.count > 1 {
                print("")
                print("其它配置组：" + store.profiles.map(\.name).joined(separator: " / "))
            }
            Darwin.exit(0)
        }
        if CommandLine.arguments.contains("--hci-stream") {
            var wav: String?
            if let i = CommandLine.arguments.firstIndex(of: "--wav"),
               CommandLine.arguments.count > i + 1 {
                wav = CommandLine.arguments[i + 1]
            }
            // --hci-stream 之后的第一位是秒数（可选，默认 60）
            var dump: String?
            if let i = CommandLine.arguments.firstIndex(of: "--dump"),
               CommandLine.arguments.count > i + 1 {
                dump = CommandLine.arguments[i + 1]
            }
            var seconds = 60
            if let i = CommandLine.arguments.firstIndex(of: "--hci-stream"),
               CommandLine.arguments.count > i + 1,
               let parsed = Int(CommandLine.arguments[i + 1]) {
                seconds = parsed
            }
            Darwin.exit(HCIStreamCapture.run(wavPath: wav, seconds: seconds, dumpPath: dump))
        }
        if let index = CommandLine.arguments.firstIndex(of: "--follow-capture") {
            guard CommandLine.arguments.count > index + 1 else {
                VoiceDiagnostic.write("用法：--follow-capture <pklg路径> [--poll 毫秒]")
                Darwin.exit(1)
            }
            let path = CommandLine.arguments[index + 1]
            var poll = 100
            if let p = CommandLine.arguments.firstIndex(of: "--poll"),
               CommandLine.arguments.count > p + 1,
               let value = Int(CommandLine.arguments[p + 1]) {
                poll = value
            }
            Darwin.exit(CaptureFollower.run(path: path, pollMilliseconds: poll))
        }
        if let index = CommandLine.arguments.firstIndex(of: "--voice-udp") {
            let next = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : nil
            let port = UInt16(next ?? "31680") ?? 31680
            Darwin.exit(VoiceUDP.run(port: port))
        }
        if let index = CommandLine.arguments.firstIndex(of: "--l2cap-probe") {
            let next = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : nil
            let seconds = next.flatMap(Double.init) ?? 15
            let disconnect = CommandLine.arguments.contains("--disconnect")
            Darwin.exit(L2CAPProbe.run(seconds: seconds, disconnectFirst: disconnect))
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = StatusIcon.make()
            // 只显示图形，不显示 "IPRC" 文字（title 留空 + imageOnly）
            button.imagePosition = .imageOnly
            button.title = ""
            button.toolTip = "IPRC1000 遥控器适配"
            button.target = self
            button.action = #selector(toggleStatusPopover(_:))
        }
        statusPopover.behavior = .transient
        statusPopover.animates = true
        statusPopover.contentSize = NSSize(width: 390, height: 480)
        statusPopover.contentViewController = NSHostingController(rootView: StatusPopoverView(
            model: model,
            openSettings: { [weak self] in self?.showSettings(nil) },
            requestPermissions: { [weak self] in self?.requestPermissions(nil) },
            quit: { [weak self] in self?.quit(nil) }
        ))
        model.start()
        showSettings(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(nil)
        return true
    }

    @objc private func toggleStatusPopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if statusPopover.isShown {
            statusPopover.performClose(sender)
        } else {
            statusPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    @objc private func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let content = SettingsView(model: model)
                .frame(minWidth: 1060, minHeight: 700)
            let controller = NSHostingController(rootView: content)
            let window = NSWindow(contentViewController: controller)
            window.title = "IPRC1000 Adapter"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.setContentSize(NSSize(width: 1160, height: 760))
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        statusPopover.performClose(sender)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func requestPermissions(_ sender: Any?) { model.requestPermissions() }
    @objc private func quit(_ sender: Any?) { NSApp.terminate(nil) }
}

private enum StatusIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let remote = NSBezierPath(
                roundedRect: NSRect(x: 5, y: 1, width: 8, height: 11),
                xRadius: 2.5,
                yRadius: 2.5
            )
            remote.lineWidth = 1.4
            remote.stroke()

            NSBezierPath(
                roundedRect: NSRect(x: 7.6, y: 5.4, width: 2.8, height: 4.2),
                xRadius: 1.4,
                yRadius: 1.4
            ).fill()
            let micArc = NSBezierPath()
            micArc.move(to: NSPoint(x: 6.8, y: 7.2))
            micArc.curve(
                to: NSPoint(x: 11.2, y: 7.2),
                controlPoint1: NSPoint(x: 6.8, y: 4.7),
                controlPoint2: NSPoint(x: 11.2, y: 4.7)
            )
            micArc.lineWidth = 1.1
            micArc.lineCapStyle = .round
            micArc.stroke()

            for (inset, y) in [(0.0, 13.1), (-1.6, 15.1)] {
                let wave = NSBezierPath()
                wave.move(to: NSPoint(x: 6 + inset, y: y))
                wave.curve(
                    to: NSPoint(x: 12 - inset, y: y),
                    controlPoint1: NSPoint(x: 7.5, y: y + 1.4),
                    controlPoint2: NSPoint(x: 10.5, y: y + 1.4)
                )
                wave.lineWidth = 1.2
                wave.lineCapStyle = .round
                wave.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

@MainActor
private enum RemoteArtwork {
    static let image: NSImage = {
        if let url = Bundle.main.url(forResource: "IPRC1000-Remote", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSImage(systemSymbolName: "av.remote.fill", accessibilityDescription: "IPRC1000")
            ?? NSImage(size: NSSize(width: 120, height: 360))
    }()

    static let keyImages: [RemoteKey: NSImage] = Dictionary(
        uniqueKeysWithValues: RemoteKey.allCases.compactMap { key in
            guard let source = image.cgImage(
                forProposedRect: nil,
                context: nil,
                hints: nil
            ), let crop = source.cropping(to: RemoteKeyArtwork.rect(for: key)) else {
                return nil
            }
            return (key, NSImage(cgImage: crop, size: RemoteKeyArtwork.rect(for: key).size))
        }
    )
}

enum RemoteKeyArtwork {
    static let canvasSize = CGSize(width: 350, height: 833)

    static func rect(for key: RemoteKey) -> CGRect {
        switch key {
        case .power: CGRect(x: 205, y: 49, width: 66, height: 66)
        case .back: CGRect(x: 89, y: 188, width: 60, height: 60)
        case .up: CGRect(x: 148, y: 188, width: 60, height: 60)
        case .menu: CGRect(x: 207, y: 188, width: 60, height: 60)
        case .left: CGRect(x: 89, y: 247, width: 60, height: 60)
        case .ok: CGRect(x: 148, y: 247, width: 60, height: 60)
        case .right: CGRect(x: 207, y: 247, width: 60, height: 60)
        case .home: CGRect(x: 89, y: 306, width: 60, height: 60)
        case .down: CGRect(x: 148, y: 306, width: 60, height: 60)
        case .info: CGRect(x: 207, y: 306, width: 60, height: 60)
        case .heart: CGRect(x: 89, y: 391, width: 60, height: 60)
        case .microphone: CGRect(x: 148, y: 391, width: 60, height: 60)
        case .person: CGRect(x: 207, y: 391, width: 60, height: 60)
        case .rewind: CGRect(x: 89, y: 450, width: 60, height: 60)
        case .playPause: CGRect(x: 148, y: 450, width: 60, height: 60)
        case .fastForward: CGRect(x: 207, y: 450, width: 60, height: 60)
        case .volumeUp: CGRect(x: 89, y: 509, width: 60, height: 60)
        case .mute: CGRect(x: 148, y: 509, width: 60, height: 60)
        case .channelUp: CGRect(x: 207, y: 509, width: 60, height: 60)
        case .volumeDown: CGRect(x: 89, y: 568, width: 60, height: 60)
        case .last: CGRect(x: 148, y: 568, width: 60, height: 60)
        case .channelDown: CGRect(x: 207, y: 568, width: 60, height: 60)
        case .unknown16: CGRect(x: 147, y: 725, width: 64, height: 64)
        }
    }
}

private struct RemoteProductImage: View {
    var body: some View {
        Image(nsImage: RemoteArtwork.image)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .accessibilityLabel("IPRC1000 遥控器实物图")
    }
}

private struct RemoteKeyThumbnail: View {
    let key: RemoteKey

    var body: some View {
        Group {
            if let image = RemoteArtwork.keyImages[key] {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "button.programmable")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 40, height: 40)
        .padding(3)
        .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityHidden(true)
    }
}

private struct HighlightableRemoteImage: View {
    let highlightedKey: RemoteKey?

    var body: some View {
        GeometryReader { geometry in
            let scale = min(
                geometry.size.width / RemoteKeyArtwork.canvasSize.width,
                geometry.size.height / RemoteKeyArtwork.canvasSize.height
            )
            let imageSize = CGSize(
                width: RemoteKeyArtwork.canvasSize.width * scale,
                height: RemoteKeyArtwork.canvasSize.height * scale
            )
            let origin = CGPoint(
                x: (geometry.size.width - imageSize.width) / 2,
                y: (geometry.size.height - imageSize.height) / 2
            )

            ZStack(alignment: .topLeading) {
                RemoteProductImage().frame(width: geometry.size.width, height: geometry.size.height)
                if let highlightedKey {
                    let rect = RemoteKeyArtwork.rect(for: highlightedKey)
                    RoundedRectangle(cornerRadius: max(5, rect.width * scale * 0.35))
                        .fill(Color.cyan.opacity(0.34))
                        .overlay {
                            RoundedRectangle(cornerRadius: max(5, rect.width * scale * 0.35))
                                .stroke(Color.cyan, lineWidth: 2.5)
                        }
                        .shadow(color: .cyan.opacity(0.85), radius: 9)
                        .frame(width: rect.width * scale, height: rect.height * scale)
                        .position(
                            x: origin.x + rect.midX * scale,
                            y: origin.y + rect.midY * scale
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .animation(.easeOut(duration: 0.14), value: highlightedKey)
        }
        .accessibilityLabel("IPRC1000 遥控器实物图")
        .accessibilityValue(highlightedKey.map { "当前按键：\($0.title)" } ?? "等待按键测试")
    }
}

private struct StatusPopoverView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var mappings: MappingStore
    let openSettings: () -> Void
    let requestPermissions: () -> Void
    let quit: () -> Void

    init(
        model: AppModel,
        openSettings: @escaping () -> Void,
        requestPermissions: @escaping () -> Void,
        quit: @escaping () -> Void
    ) {
        self.model = model
        mappings = model.mappings
        self.openSettings = openSettings
        self.requestPermissions = requestPermissions
        self.quit = quit
    }

    private var configuredCount: Int {
        mappings.values.values.filter { $0.kind != .none }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 30, height: 30)
                Text("IPRC1000 Adapter").font(.title3.bold())
                Spacer()
                Circle().fill(model.hidReady ? .green : .orange).frame(width: 9, height: 9)
                Text(model.hidReady ? "已连接" : "待连接")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(model.hidReady ? .green : .orange)
            }

            HStack(spacing: 18) {
                RemoteProductImage().frame(width: 72, height: 165)
                VStack(alignment: .leading, spacing: 10) {
                    Text("IPRC1000").font(.title2.bold())
                    Label(model.hidStatus, systemImage: model.hidReady ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    Divider()
                    statusLine("按键通道", ready: model.hidReady)
                    statusLine("语音通道", ready: model.voiceReady)
                    Text("\(configuredCount) 个按键已配置")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))

            HStack(spacing: 10) {
                monitorTile("按键", icon: "keyboard", ready: model.hidReady, tint: .blue)
                monitorTile("语音", icon: "waveform", ready: model.voiceReady, tint: .purple)
                monitorTile("映射", icon: "switch.2", ready: configuredCount > 0, tint: .cyan)
            }

            HStack(spacing: 10) {
                Image(systemName: "waveform.path.ecg").foregroundStyle(.blue)
                Text("当前操作").font(.caption).foregroundStyle(.secondary)
                Text(model.lastKey == "—" ? "等待遥控器输入" : model.lastKey)
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            .padding(12)
            .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

            HStack {
                Button("打开设置", action: openSettings).buttonStyle(.borderedProminent)
                Button("检查权限", action: requestPermissions)
                Spacer()
                Button("退出", action: quit).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(width: 390)
        .background(
            LinearGradient(
                colors: [Color.blue.opacity(0.12), Color.cyan.opacity(0.05), Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private func statusLine(_ title: String, ready: Bool) -> some View {
        HStack(spacing: 7) {
            Circle().fill(ready ? .green : .orange).frame(width: 7, height: 7)
            Text(title).font(.caption.weight(.medium))
            Spacer()
            Text(ready ? "在线" : "未就绪").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func monitorTile(_ title: String, icon: String, ready: Bool, tint: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.title3).foregroundStyle(tint)
            Text(title).font(.caption.weight(.semibold))
            Text(ready ? "ON" : "OFF")
                .font(.caption2.bold()).foregroundStyle(ready ? .green : .secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case overview = "总览"
    case mapping = "按键映射"
    case diagnostics = "连接诊断"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .mapping: "switch.2"
        case .diagnostics: "waveform.path.ecg"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var mappings: MappingStore
    @State private var editingKey: RemoteKey?
    @State private var section: SettingsSection = .overview
    @State private var mappingSearch = ""
    @State private var profileName = ""
    @State private var renamingProfileID: UUID?
    @State private var message: String?

    init(model: AppModel) {
        self.model = model
        mappings = model.mappings
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color.blue.opacity(0.11),
                    Color.orange.opacity(0.06)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            HStack(spacing: 0) {
                sidebar
                Divider().opacity(0.55)
                detailView
            }
        }
        .sheet(item: $editingKey) { key in
            KeyboardPickerView(
                remoteKey: key,
                current: mappings.values[key] ?? .none
            ) { binding in
                mappings.values[key] = binding
            }
        }
        .alert("重命名配置组", isPresented: Binding(
            get: { renamingProfileID != nil },
            set: { if !$0 { renamingProfileID = nil } }
        )) {
            TextField("配置组名称", text: $profileName)
            Button("取消", role: .cancel) { renamingProfileID = nil }
            Button("确定") { renameProfile() }
                .disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("按键配置", isPresented: Binding(
            get: { message != nil }, set: { if !$0 { message = nil } }
        )) { Button("好") { message = nil } } message: { Text(message ?? "") }
    }

    private var configuredCount: Int {
        mappings.values.values.filter { $0.kind != .none }.count
    }

    private var sidebar: some View {
        VStack(spacing: 18) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 28, height: 28)
                Text("IPRC1000 Adapter").font(.headline)
                Spacer()
            }

            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 10) {
                    ForEach(SettingsSection.allCases) { item in
                        Button {
                            section = item
                        } label: {
                            Image(systemName: item.icon)
                                .font(.system(size: 17, weight: .semibold))
                                .frame(width: 46, height: 46)
                                .foregroundStyle(section == item ? .blue : .secondary)
                                .background(
                                    section == item ? Color.blue.opacity(0.13) : .clear,
                                    in: RoundedRectangle(cornerRadius: 13)
                                )
                                .overlay {
                                    if section == item {
                                        RoundedRectangle(cornerRadius: 13)
                                            .stroke(Color.blue.opacity(0.45))
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .help(item.rawValue)
                    }
                }

                VStack(spacing: 12) {
                    Spacer(minLength: 8)
                    HighlightableRemoteImage(highlightedKey: model.lastRemoteKey)
                        .frame(width: 185, height: 470)
                        .shadow(color: .black.opacity(0.18), radius: 16, y: 10)
                    Text("IPRC1000").font(.title2.bold())
                    Text(model.lastRemoteKey.map { "已检测：\($0.title)" } ?? "按下遥控器按键进行测试")
                        .font(.caption)
                        .foregroundStyle(model.lastRemoteKey == nil ? Color.secondary : Color.cyan)
                }
                .frame(maxWidth: .infinity)
            }

            Spacer()
            HStack(spacing: 8) {
                Circle().fill(model.hidReady ? .green : .orange).frame(width: 8, height: 8)
                Text(model.hidReady ? "按键通道在线" : "等待遥控器连接")
                    .font(.caption.weight(.medium))
                Spacer()
            }
            .padding(11)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(.top, 34)
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
        .frame(width: 340)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var detailView: some View {
        switch section {
        case .overview: overviewView
        case .mapping: mappingView
        case .diagnostics: diagnosticsView
        }
    }

    private var overviewView: some View {
        VStack(alignment: .leading, spacing: 20) {
            pageHeader("功能总览", subtitle: "遥控器与适配功能的实时状态", icon: "slider.horizontal.3")

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                dashboardCard(
                    "设备连接", icon: "av.remote.fill", tint: .green,
                    status: model.hidReady ? "IPRC1000 在线" : "等待连接",
                    detail: model.hidStatus, ready: model.hidReady
                )
                dashboardCard(
                    "按键映射", icon: "switch.2", tint: .blue,
                    status: "\(configuredCount) 个按键已配置",
                    detail: "支持单键、组合键与媒体键", ready: configuredCount > 0
                )
                dashboardCard(
                    "遥控器语音", icon: "waveform", tint: .orange,
                    status: model.voiceReady ? "正在接收音频" : "语音通道未就绪",
                    detail: model.voiceStatus, ready: model.voiceReady
                )
                dashboardCard(
                    "输入与权限", icon: "checkmark.shield.fill", tint: .purple,
                    status: model.hidReady ? "输入监控已就绪" : "需要检查权限",
                    detail: "仅拦截 IPRC1000，不影响其他键盘", ready: model.hidReady
                )
            }

            HStack(spacing: 12) {
                Image(systemName: "waveform.path.ecg").foregroundStyle(.blue)
                Text("当前操作").foregroundStyle(.secondary)
                Text(model.lastKey == "—" ? "等待遥控器输入" : model.lastKey).fontWeight(.semibold)
                Spacer()
                if model.lastKey != "—" {
                    Text("已转译").font(.caption.bold()).foregroundStyle(.green)
                }
            }
            .padding(16)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))

            Spacer()
        }
        .padding(.top, 42)
        .padding(.horizontal, 28)
        .padding(.bottom, 22)
    }

    private var mappingView: some View {
        VStack(alignment: .leading, spacing: 14) {
            pageHeader("按键映射", subtitle: "每个配置组独立保存按键动作", icon: "switch.2")

            mappingToolbar

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(filteredRemoteKeys) { key in
                        Button {
                            if key != .unknown16 { editingKey = key }
                        } label: {
                            HStack(spacing: 14) {
                                RemoteKeyThumbnail(key: key)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(key.title).fontWeight(.semibold)
                                    Text(String(format: "HID 0x%02X", key.rawValue))
                                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(key == .unknown16 ? "切换到下一配置组" : (mappings.values[key] ?? .none).title)
                                    .font(.system(.body, design: .rounded).weight(.medium))
                                    .lineLimit(1).foregroundStyle(.primary)
                                Image(systemName: key == .unknown16 ? "arrow.triangle.2.circlepath" : "chevron.right")
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 13))
                            .overlay {
                                RoundedRectangle(cornerRadius: 13)
                                    .stroke(
                                        model.lastRemoteKey == key ? Color.cyan : Color.clear,
                                        lineWidth: 2
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                        .allowsHitTesting(key != .unknown16)
                    }
                }
                .padding(.vertical, 2)
            }
            if filteredRemoteKeys.isEmpty {
                ContentUnavailableView("没有匹配的按键", systemImage: "magnifyingglass", description: Text("请尝试其他关键词"))
            }

            profileTabs
        }
        .padding(.top, 42)
        .padding(.horizontal, 28)
        .padding(.bottom, 22)
    }

    private var mappingToolbar: some View {
        HStack(spacing: 10) {
            Label(mappings.activeProfile?.name ?? "配置组", systemImage: "square.stack.3d.up.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.blue)

            Spacer()

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索按键、HID 或动作", text: $mappingSearch)
                    .textFieldStyle(.plain)
                if !mappingSearch.isEmpty {
                    Button { mappingSearch = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(width: 255, height: 34)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.22)) }

            Button { importConfiguration() } label: {
                Label("导入", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
            Button { exportConfiguration() } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            Button("恢复默认") { mappings.reset() }
                .buttonStyle(.bordered)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var profileTabs: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(mappings.profiles) { profile in
                        Button {
                            mappings.selectProfile(profile.id)
                        } label: {
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(profile.id == mappings.activeProfileID ? Color.blue : Color.secondary.opacity(0.35))
                                    .frame(width: 7, height: 7)
                                Text(profile.name).lineLimit(1)
                            }
                            .font(.callout.weight(profile.id == mappings.activeProfileID ? .semibold : .regular))
                            .foregroundStyle(profile.id == mappings.activeProfileID ? Color.blue : Color.primary)
                            .padding(.horizontal, 13)
                            .frame(height: 34)
                            .background(
                                profile.id == mappings.activeProfileID ? Color.blue.opacity(0.13) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 9)
                            )
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            beginRenaming(profile)
                        })
                        .help("单击切换，双击重命名")
                    }
                }
            }

            Divider().frame(height: 24)

            Button { mappings.addProfile() } label: {
                Image(systemName: "plus").frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help("复制当前映射并新建配置组")

            Button(role: .destructive) { mappings.deleteActiveProfile() } label: {
                Image(systemName: "minus").frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .disabled(mappings.profiles.count == 1)
            .help("删除当前配置组")
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.2)) }
    }

    private var filteredRemoteKeys: [RemoteKey] {
        let query = mappingSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return RemoteKey.allCases }
        return RemoteKey.allCases.filter { key in
            let hid = String(format: "HID 0x%02X", key.rawValue)
            return key.title.localizedCaseInsensitiveContains(query)
                || hid.localizedCaseInsensitiveContains(query)
                || (key == .unknown16 && "切换到下一配置组".localizedCaseInsensitiveContains(query))
                || (mappings.values[key] ?? .none).title.localizedCaseInsensitiveContains(query)
        }
    }

    private func beginRenaming(_ profile: MappingStore.Profile) {
        mappings.selectProfile(profile.id)
        profileName = profile.name
        renamingProfileID = profile.id
    }

    private func renameProfile() {
        if let renamingProfileID { mappings.renameProfile(renamingProfileID, to: profileName) }
        renamingProfileID = nil
    }

    private func exportConfiguration() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "IPRC1000-\(mappings.activeProfile?.name ?? "配置组").json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try mappings.exportActiveProfileData().write(to: url, options: .atomic)
            message = "已导出“\(mappings.activeProfile?.name ?? "当前配置组")”。"
        } catch { message = "导出失败：\(error.localizedDescription)" }
    }

    private func importConfiguration() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try mappings.importIntoActiveProfile(Data(contentsOf: url))
            message = "已导入到“\(mappings.activeProfile?.name ?? "当前配置组")”。"
        } catch { message = "导入失败：\(error.localizedDescription)" }
    }

    private var diagnosticsView: some View {
        VStack(alignment: .leading, spacing: 18) {
            pageHeader("连接诊断", subtitle: "查看按键、蓝牙语音与虚拟麦克风状态", icon: "waveform.path.ecg")

            HStack(spacing: 14) {
                diagnosticCard("按键通道", message: model.hidStatus, ready: model.hidReady, icon: "keyboard")
                diagnosticCard("语音通道", message: model.voiceStatus, ready: model.voiceReady, icon: "mic.fill")
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("实时麦克风电平", systemImage: "waveform")
                        .font(.headline).foregroundStyle(.purple)
                    Spacer()
                    Text(model.voiceReady ? "LIVE" : "IDLE")
                        .font(.caption.bold()).foregroundStyle(model.voiceReady ? .green : .secondary)
                }
                ProgressView(value: Double(model.voiceLevel), total: 1).tint(.purple)
            }
            .padding(16)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 10) {
                Label("使用方式", systemImage: "info.circle.fill").font(.headline)
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. 保持本 App 在菜单栏运行。")
                    Text("2. 在 Zoom、微信、录音软件等目标 App 中，把麦克风选为 “BlackHole 2ch”。")
                    Text("3. 按住遥控器麦克风键说话，松开结束。")
                    Text("不要同时把系统扬声器输出设为 BlackHole，否则你会听不到声音；如需监听，请另建多输出设备。")
                        .foregroundStyle(.orange)
                }
                    .font(.callout)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
            Spacer()
        }
        .padding(.top, 42)
        .padding(.horizontal, 28)
        .padding(.bottom, 22)
    }

    private func pageHeader<Trailing: View>(
        _ title: String,
        subtitle: String,
        icon: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 28, weight: .bold, design: .rounded))
                Text(subtitle).foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
            Image(systemName: icon)
                .font(.title2).foregroundStyle(.blue)
                .frame(width: 42, height: 42)
                .background(Color.blue.opacity(0.1), in: Circle())
        }
    }

    private func pageHeader(_ title: String, subtitle: String, icon: String) -> some View {
        pageHeader(title, subtitle: subtitle, icon: icon) { EmptyView() }
    }

    private func dashboardCard(
        _ title: String,
        icon: String,
        tint: Color,
        status: String,
        detail: String,
        ready: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: icon).font(.title3).foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.12), in: Circle())
                Text(title).font(.headline)
                Spacer()
                Circle().fill(ready ? .green : .orange).frame(width: 8, height: 8)
            }
            Text(status).font(.title3.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.18))
        }
    }

    private func diagnosticCard(
        _ title: String,
        message: String,
        ready: Bool,
        icon: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon).font(.title2).foregroundStyle(ready ? .green : .orange)
                Text(title).font(.headline)
                Spacer()
                Text(ready ? "ONLINE" : "CHECK")
                    .font(.caption.bold()).foregroundStyle(ready ? .green : .orange)
            }
            Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct KeyboardPickerView: View {
    let remoteKey: RemoteKey
    let onSave: (KeyBinding) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: KeyBinding
    @State private var modifiers: Set<KeyModifier>

    init(remoteKey: RemoteKey, current: KeyBinding, onSave: @escaping (KeyBinding) -> Void) {
        self.remoteKey = remoteKey
        self.onSave = onSave
        _draft = State(initialValue: current)
        _modifiers = State(initialValue: current.modifiers)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("设置“\(remoteKey.title)”").font(.title2.bold())
                    Text("修饰键可单独保存，也可继续选择一个主键组成组合键。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(draft.title)
                    .font(.system(.title3, design: .rounded).bold())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Text("标准全尺寸 Mac 键盘").font(.headline)
                Spacer()
                Button("清除修饰键") {
                    modifiers.removeAll()
                    updateDraftModifiers()
                }
                .disabled(modifiers.isEmpty)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    standardKeyboard

                    VStack(alignment: .leading, spacing: 8) {
                        Text("媒体键").font(.headline)
                        HStack(spacing: 8) {
                            mediaButton(.playPause, symbol: "playpause.fill")
                            mediaButton(.previousTrack, symbol: "backward.end.fill")
                            mediaButton(.nextTrack, symbol: "forward.end.fill")
                            mediaButton(.volumeDown, symbol: "speaker.wave.1.fill")
                            mediaButton(.volumeUp, symbol: "speaker.wave.3.fill")
                            mediaButton(.mute, symbol: "speaker.slash.fill")
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Divider()
            HStack {
                Button("不执行") {
                    onSave(.none)
                    dismiss()
                }
                Spacer()
                Button("取消") { dismiss() }
                Button("保存映射") {
                    onSave(draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.kind == .none)
            }
        }
        .frame(minWidth: 960, minHeight: 610)
        .padding(20)
    }

    private var standardKeyboard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                keyButton(MacKey(53, "Esc", width: 1.25))
                keyGroup([MacKey(122, "F1"), MacKey(120, "F2"), MacKey(99, "F3"), MacKey(118, "F4")])
                keyGroup([MacKey(96, "F5"), MacKey(97, "F6"), MacKey(98, "F7"), MacKey(100, "F8")])
                keyGroup([MacKey(101, "F9"), MacKey(109, "F10"), MacKey(103, "F11"), MacKey(111, "F12")])
                keyGroup([MacKey(105, "F13"), MacKey(107, "F14"), MacKey(113, "F15"), MacKey(106, "F16")])
                keyGroup([MacKey(64, "F17"), MacKey(79, "F18"), MacKey(80, "F19"), MacKey(90, "F20")])
            }

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    keyRow([MacKey(50, "`"), MacKey(18, "1"), MacKey(19, "2"), MacKey(20, "3"), MacKey(21, "4"), MacKey(23, "5"), MacKey(22, "6"), MacKey(26, "7"), MacKey(28, "8"), MacKey(25, "9"), MacKey(29, "0"), MacKey(27, "-"), MacKey(24, "="), MacKey(51, "⌫", width: 1.7)])
                    keyRow([MacKey(48, "Tab", width: 1.45), MacKey(12, "Q"), MacKey(13, "W"), MacKey(14, "E"), MacKey(15, "R"), MacKey(17, "T"), MacKey(16, "Y"), MacKey(32, "U"), MacKey(34, "I"), MacKey(31, "O"), MacKey(35, "P"), MacKey(33, "["), MacKey(30, "]"), MacKey(42, "\\", width: 1.25)])
                    keyRow([MacKey(57, "Caps", width: 1.75), MacKey(0, "A"), MacKey(1, "S"), MacKey(2, "D"), MacKey(3, "F"), MacKey(5, "G"), MacKey(4, "H"), MacKey(38, "J"), MacKey(40, "K"), MacKey(37, "L"), MacKey(41, ";"), MacKey(39, "'"), MacKey(36, "Return", width: 2.0)])
                    HStack(spacing: 5) {
                        modifierButton(.shift, label: "⇧ Shift", width: 2.05)
                        keyRow([MacKey(6, "Z"), MacKey(7, "X"), MacKey(8, "C"), MacKey(9, "V"), MacKey(11, "B"), MacKey(45, "N"), MacKey(46, "M"), MacKey(43, ","), MacKey(47, "."), MacKey(44, "/")])
                        modifierButton(.shift, label: "⇧", width: 2.05)
                    }
                    HStack(spacing: 5) {
                        modifierButton(.function, label: "fn")
                        modifierButton(.control, label: "⌃ Ctrl")
                        modifierButton(.option, label: "⌥ Option", width: 1.35)
                        modifierButton(.command, label: "⌘ Command", width: 1.55)
                        keyButton(MacKey(49, "空格", width: 5.1))
                        modifierButton(.command, label: "⌘", width: 1.2)
                        modifierButton(.option, label: "⌥", width: 1.2)
                    }
                }

                VStack(spacing: 5) {
                    keyRow([MacKey(114, "Help"), MacKey(115, "Home"), MacKey(116, "Page ↑")])
                    keyRow([MacKey(117, "⌦"), MacKey(119, "End"), MacKey(121, "Page ↓")])
                    Color.clear.frame(height: 32)
                    keyRow([MacKey(126, "↑")])
                    keyRow([MacKey(123, "←"), MacKey(125, "↓"), MacKey(124, "→")])
                }

                VStack(spacing: 5) {
                    keyRow([MacKey(71, "Clear"), MacKey(81, "="), MacKey(75, "/"), MacKey(67, "*")])
                    keyRow([MacKey(89, "7"), MacKey(91, "8"), MacKey(92, "9"), MacKey(78, "-")])
                    keyRow([MacKey(86, "4"), MacKey(87, "5"), MacKey(88, "6"), MacKey(69, "+")])
                    keyRow([MacKey(83, "1"), MacKey(84, "2"), MacKey(85, "3"), MacKey(76, "Enter")])
                    keyRow([MacKey(82, "0", width: 2.1), MacKey(65, "."), MacKey(76, "Enter")])
                }
            }
        }
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func keyGroup(_ keys: [MacKey]) -> some View {
        HStack(spacing: 5) { ForEach(keys) { keyButton($0) } }
            .padding(.leading, 7)
    }

    private func keyRow(_ keys: [MacKey]) -> some View {
        HStack(spacing: 5) { ForEach(keys) { keyButton($0) } }
    }

    private func keyButton(_ key: MacKey) -> some View {
        Button {
            draft = .keyboard(key.keyCode, modifiers: modifiers)
        } label: {
            keyCap(key.label, width: key.width, selected: isSelected(key))
        }
        .buttonStyle(.plain)
    }

    private func modifierButton(_ modifier: KeyModifier, label: String, width: CGFloat = 1) -> some View {
        Button { toggle(modifier) } label: {
            keyCap(label, width: width, selected: modifiers.contains(modifier))
        }
        .buttonStyle(.plain)
    }

    private func keyCap(_ label: String, width: CGFloat, selected: Bool) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: 32 * width, height: 31)
            .background(
                selected ? Color.accentColor.opacity(0.22) : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 5)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.35))
            }
    }

    private func mediaButton(_ key: MediaKey, symbol: String) -> some View {
        Button {
            modifiers.removeAll()
            draft = .media(key)
        } label: {
            Label(key.title, systemImage: symbol)
        }
        .buttonStyle(.bordered)
        .tint(draft.mediaKey == key ? .accentColor : .secondary)
    }

    private func isSelected(_ key: MacKey) -> Bool {
        draft.kind == .keyboard && draft.keyCode == key.keyCode
    }

    private func toggle(_ modifier: KeyModifier) {
        if modifiers.contains(modifier) {
            modifiers.remove(modifier)
        } else {
            modifiers.insert(modifier)
        }
        updateDraftModifiers()
    }

    private func updateDraftModifiers() {
        if draft.kind == .keyboard, let keyCode = draft.keyCode {
            draft = .keyboard(keyCode, modifiers: modifiers)
        } else if draft.kind != .media {
            draft = modifiers.isEmpty ? .none : .modifierOnly(modifiers)
        } else if !modifiers.isEmpty {
            draft = .modifierOnly(modifiers)
        }
    }
}
