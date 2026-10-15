import CoreAudio
import Darwin
import Foundation

/// 语音回灌入口：从 UDP 收 16 kHz 单声道 PCM，写进 BlackHole 虚拟声卡。
///
/// 为什么这么设计：macOS 拿不到遥控器的音频（见 docs/MACOS_VOICE.md），
/// 只能靠 **PacketLogger 抓 HCI**。抓包是写文件的，所以做成
/// 「Python 跟随抓包文件 → 提取音频 → UDP 发过来 → 这里灌进 BlackHole」，
/// 与 Windows 版（etw_consumer → UDP → pcm_router → VB-CABLE）同构。
///
/// 用法：
///   IPRC1000Adapter --voice-udp 31680
/// 协议：每个 UDP 包就是一段 16 kHz int16 小端单声道 PCM（任意长度）。
@MainActor
enum VoiceUDP {
    static func run(port: UInt16) -> Int32 {
        let output = BlackHoleOutput()
        let started = output.start()
        VoiceDiagnostic.write("BlackHole 输出：\(started.ok ? "就绪 ✅" : "失败 ❌ \(started.message)")")
        if !started.ok {
            VoiceDiagnostic.write("→ 请确认已安装 BlackHole 2ch（install.sh 会自动装）。")
        }

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            VoiceDiagnostic.write("❌ 创建 UDP socket 失败")
            return 1
        }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            VoiceDiagnostic.write("❌ 绑定 127.0.0.1:\(port) 失败（端口被占？）")
            close(fd)
            return 1
        }
        VoiceDiagnostic.write("🎧 正在监听 127.0.0.1:\(port) 的语音数据…")
        VoiceDiagnostic.write("   把系统「声音 → 输入」切到 BlackHole 2ch，即可用来听写。")

        var buffer = [UInt8](repeating: 0, count: 8192)
        var packets = 0
        var bytes = 0
        var lastReport = Date()
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0 else { continue }
            packets += 1
            bytes += n
            // 16-bit LE 单声道 → Int16
            var samples = [Int16]()
            samples.reserveCapacity(n / 2)
            var index = 0
            while index + 1 < n {
                samples.append(Int16(bitPattern: UInt16(buffer[index]) | (UInt16(buffer[index + 1]) << 8)))
                index += 2
            }
            output.enqueue16kMono(samples)

            if Date().timeIntervalSince(lastReport) > 5 {
                lastReport = Date()
                VoiceDiagnostic.write(
                    String(format: "已接收 %d 包 / %.1f 秒音频", packets, Double(bytes) / 2 / 16000)
                )
            }
        }
    }
}
