import Foundation
import IOBluetooth
import os

/// 可行性探针：尝试**绕过 macOS 的 HID 解析层**，直接打开遥控器的 L2CAP 通道。
///
/// 动机：macOS 的 IOHIDFamily 严格按报告描述符解析，把 653 字节的音频报告
/// （`A1 F7 …`）直接丢掉了（见 docs/MACOS_VOICE.md）。但遥控器的音频和按键
/// 都跑在 **HID 中断通道（L2CAP PSM 0x13）** 上 —— 如果我们能自己成为该通道的
/// 一端，就能拿到**未经 HID 解析的原始字节流**，也就拿到了音频。
///
/// 用法：
///   IPRC1000Adapter --l2cap-probe [秒数] [--disconnect]
/// 需要「蓝牙」权限（首次会弹窗）。
@MainActor
enum L2CAPProbe {
    static func run(seconds: Double, disconnectFirst: Bool) -> Int32 {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        VoiceDiagnostic.write("配对设备数：\(paired.count)")
        for d in paired {
            VoiceDiagnostic.write("  - \(d.name ?? "<nil>")  \(d.addressString ?? "?")  connected=\(d.isConnected())")
        }
        guard let remote = paired.first(where: { ($0.name ?? "").uppercased().contains("IPRC1000") }) else {
            VoiceDiagnostic.write("❌ 没找到 IPRC1000（需要在系统蓝牙里配对过）")
            return 1
        }
        VoiceDiagnostic.write("目标：\(remote.name ?? "?")  \(remote.addressString ?? "?")  connected=\(remote.isConnected())")

        if !remote.isConnected() {
            VoiceDiagnostic.write("→ 设备未连接，主动发起连接…")
            let rc = remote.openConnection()
            VoiceDiagnostic.write("  openConnection 返回：\(rc)")
            for _ in 0..<50 where !remote.isConnected() {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            VoiceDiagnostic.write("  等待后 connected=\(remote.isConnected())")
        }

        if disconnectFirst {
            VoiceDiagnostic.write("→ 先断开系统连接（好让 bluetoothd 放开 HID 通道）…")
            remote.closeConnection()
            RunLoop.main.run(until: Date().addingTimeInterval(2))
            VoiceDiagnostic.write("  断开后 connected=\(remote.isConnected())")
        }

        let probe = ProbeDelegate()
        var channel: IOBluetoothL2CAPChannel?
        // PSM 0x13 = HID 中断通道；0x11 = HID 控制通道
        let rc = remote.openL2CAPChannelSync(&channel, withPSM: 0x13, delegate: probe)
        VoiceDiagnostic.write("openL2CAPChannelSync(PSM 0x13) 返回：\(rc)  (\(rc == kIOReturnSuccess ? "成功 ✅" : "失败"))")

        if rc != kIOReturnSuccess {
            VoiceDiagnostic.write("→ 再试 HID 控制通道 PSM 0x11 …")
            var control: IOBluetoothL2CAPChannel?
            let rc2 = remote.openL2CAPChannelSync(&control, withPSM: 0x11, delegate: probe)
            VoiceDiagnostic.write("openL2CAPChannelSync(PSM 0x11) 返回：\(rc2)")
        }

        VoiceDiagnostic.write(">>> 监听 \(Int(seconds)) 秒；请按住遥控器【麦克风键】说话，并按几下方向键 <<<")
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }

        let snap = probe.snapshot()
        VoiceDiagnostic.write("")
        VoiceDiagnostic.write("== 结果 ==")
        VoiceDiagnostic.write("收到数据块：\(snap.packets)   总字节：\(snap.bytes)")
        VoiceDiagnostic.write("长度分布：\(snap.lengths.sorted { $0.key < $1.key }.map { "\($0.key)B×\($0.value)" }.joined(separator: "  "))")
        VoiceDiagnostic.write("命中 `A1 F7` 音频帧开头：\(snap.audioSignatures) 次")
        VoiceDiagnostic.write("命中 `A1 01` 键盘报告开头：\(snap.keySignatures) 次")
        if let first = snap.firstHex { VoiceDiagnostic.write("首个数据块头部：\(first)") }

        if snap.audioSignatures > 0 {
            VoiceDiagnostic.write("✅ 拿到音频了！可以据此实现实时语音桥。")
            return 0
        } else if snap.packets > 0 {
            VoiceDiagnostic.write("⚠️ 通道通了、有数据，但没看到音频帧 —— 可能只拿到了 HID 控制/键盘流。")
            return 2
        } else {
            VoiceDiagnostic.write("❌ 通道没数据：bluetoothd 仍占着 HID 通道（系统不肯让出）。")
            VoiceDiagnostic.write("   这条路走不通的话，只能走 PacketLogger（需 Apple 日志描述文件）。")
            return 3
        }
    }
}

private final class ProbeDelegate: NSObject, IOBluetoothL2CAPChannelDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var packets = 0
    private var bytes = 0
    private var lengths: [Int: Int] = [:]
    private var audioSignatures = 0
    private var keySignatures = 0
    private var firstHex: String?

    func l2capChannelData(_ channel: IOBluetoothL2CAPChannel!,
                          data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        guard let dataPointer, dataLength > 0 else { return }
        let buf = UnsafeRawBufferPointer(start: dataPointer, count: dataLength)
        let head = Array(buf.prefix(4))
        lock.lock()
        packets += 1
        bytes += dataLength
        lengths[dataLength, default: 0] += 1
        if head.count >= 2, head[0] == 0xA1, head[1] == 0xF7 { audioSignatures += 1 }
        if head.count >= 2, head[0] == 0xA1, head[1] == 0x01 { keySignatures += 1 }
        if firstHex == nil {
            firstHex = Array(buf.prefix(24)).map { String(format: "%02X", $0) }.joined(separator: " ")
        }
        lock.unlock()
    }

    func l2capChannelOpenComplete(_ channel: IOBluetoothL2CAPChannel!, status error: IOReturn) {
        VoiceDiagnostic.write("L2CAP 通道建立回调 status=\(error)")
    }

    func l2capChannelClosed(_ channel: IOBluetoothL2CAPChannel!) {
        VoiceDiagnostic.write("L2CAP 通道已关闭")
    }

    struct Snapshot {
        let packets: Int
        let bytes: Int
        let lengths: [Int: Int]
        let audioSignatures: Int
        let keySignatures: Int
        let firstHex: String?
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(packets: packets, bytes: bytes, lengths: lengths,
                        audioSignatures: audioSignatures, keySignatures: keySignatures,
                        firstHex: firstHex)
    }
}
