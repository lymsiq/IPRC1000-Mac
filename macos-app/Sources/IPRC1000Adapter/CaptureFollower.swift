import CoreAudio
import Foundation

/// **单进程**抓包跟随器：App 自己 tail PacketLogger 正在写的 btsnoop 文件，
/// 增量解析出音频帧，直接写进 BlackHole —— 不需要 Python、不需要 UDP 转发。
///
/// 为什么还要"读文件"：macOS 上**唯一**能产出蓝牙包数据的进程就是 PacketLogger
/// （装了 Apple 蓝牙日志描述文件才有数据）。我们的程序只能去读它的输出，
/// 这一步无法再省；但除 PacketLogger 外，整条链路都在这一个进程里完成。
///
/// 用法：
///   IPRC1000Adapter --follow-capture /tmp/iprc.pklg [--poll 100]
@MainActor
enum CaptureFollower {
    private static let frameLen = 653          // L2CAP 负载
    private static let audioBytes = 640        // 320 × int16
    private static let headerTail: [UInt8] = [0x00, 0x00, 0x00, 0x40, 0x01]

    static func run(path: String, pollMilliseconds: Int) -> Int32 {
        let output = BlackHoleOutput()
        let started = output.start()
        VoiceDiagnostic.write("BlackHole 输出：\(started.ok ? "就绪 ✅" : "失败 ❌ \(started.message)")")
        VoiceDiagnostic.write("跟随抓包文件：\(path)   （每 \(pollMilliseconds) ms 检查一次）")
        VoiceDiagnostic.write(">>> 按住遥控器【麦克风键】说话；系统「声音 → 输入」记得切到 BlackHole 2ch <<<")

        var buffer: [UInt8] = []
        var pending: [UInt8] = []
        var datalink = 1002
        var needHeader = true
        var offset: UInt64 = 0
        var frames = 0
        var seconds = 0.0
        var aclCount = 0
        var lastReport = Date()
        var warnedEmpty = false

        while true {
            // ── 读增量 ──
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
            if size < offset { offset = 0 }                 // 文件被重建/截断
            if size > offset, let handle = FileHandle(forReadingAtPath: path) {
                try? handle.seek(toFileOffset: offset)
                let chunk = handle.readDataToEndOfFile()
                offset = handle.offsetInFile
                try? handle.close()
                if !chunk.isEmpty { buffer.append(contentsOf: chunk) }
            } else if size == 0, !warnedEmpty {
                warnedEmpty = true
                VoiceDiagnostic.write("⚠️ 文件还是空的 —— 若一直如此，说明蓝牙日志描述文件没生效")
                VoiceDiagnostic.write("   （PacketLogger 只有在描述文件装好后才能拿到包数据）")
            }

            // ── btsnoop 头 ──
            if needHeader {
                if buffer.count >= 16 {
                    if Array(buffer[0..<8]) == Array("btsnoop\u{0}".utf8) {
                        datalink = Int((UInt32(buffer[12]) << 24) | (UInt32(buffer[13]) << 16)
                                       | (UInt32(buffer[14]) << 8) | UInt32(buffer[15]))
                    } else {
                        datalink = 1002                        // 当作裸 HCI 流
                    }
                    buffer.removeFirst(16)
                    needHeader = false
                } else {
                    usleep(useconds_t(pollMilliseconds * 1000))
                    continue
                }
            }

            // ── 逐条 HCI 记录 ──
            while buffer.count >= 24 {
                let incl = Int((UInt32(buffer[4]) << 24) | (UInt32(buffer[5]) << 16)
                               | (UInt32(buffer[6]) << 8) | UInt32(buffer[7]))
                guard incl > 0, buffer.count >= 24 + incl else { break }
                var pkt = Array(buffer[24..<(24 + incl)])
                buffer.removeFirst(24 + incl)

                if datalink == 1002 {
                    guard pkt.first == 0x02 else { continue }  // 只看 ACL
                    pkt.removeFirst()
                }
                guard pkt.count >= 4 else { continue }
                let handleFlags = UInt16(pkt[0]) | (UInt16(pkt[1]) << 8)
                let dlen = Int(UInt16(pkt[2]) | (UInt16(pkt[3]) << 8))
                guard pkt.count >= 4 + dlen else { continue }
                let body = Array(pkt[4..<(4 + dlen)])
                let pb = Int((handleFlags >> 12) & 0x3)
                aclCount += 1

                if pb == 0 || pb == 2 {
                    pending = body
                } else if pb == 1 {
                    pending.append(contentsOf: body)
                } else {
                    continue
                }
                guard pending.count >= 4 else { continue }
                let l2len = Int(UInt16(pending[0]) | (UInt16(pending[1]) << 8))
                guard l2len == frameLen, pending.count >= 4 + frameLen else { continue }

                let payload = Array(pending[4..<(4 + frameLen)])
                pending.removeFirst(4 + frameLen)

                guard let audioStart = audioOffset(payload),
                      audioStart + audioBytes <= payload.count else { continue }
                var samples = [Int16](repeating: 0, count: audioBytes / 2)
                for index in 0..<(audioBytes / 2) {
                    let low = payload[audioStart + index * 2]
                    let high = payload[audioStart + index * 2 + 1]
                    samples[index] = Int16(bitPattern: UInt16(low) | (UInt16(high) << 8))
                }
                output.enqueue16kMono(samples)
                frames += 1
                seconds += Double(samples.count) / 16000.0
            }

            if Date().timeIntervalSince(lastReport) > 5 {
                lastReport = Date()
                VoiceDiagnostic.write(String(format: "音频帧 %d（约 %.2f 秒）  ACL包 %d  文件 %llu B",
                                             frames, seconds, aclCount, size))
            }
            usleep(useconds_t(pollMilliseconds * 1000))
        }
    }

    /// 帧头 `A1 F7 01 <seq> 00 81 00 <cnt> 00 00 00 40 01` → 定位 640 字节音频起点
    private static func audioOffset(_ payload: [UInt8]) -> Int? {
        guard payload.count >= 13 + audioBytes else { return nil }
        for index in 0...(min(40, payload.count - headerTail.count)) {
            if Array(payload[index..<(index + headerTail.count)]) == headerTail,
               index >= 3, payload[index - 3] == 0x81 {
                let start = index + headerTail.count
                if start + audioBytes <= payload.count { return start }
            }
        }
        return nil
    }
}
