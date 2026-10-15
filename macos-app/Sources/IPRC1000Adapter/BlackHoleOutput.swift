import CoreAudio
import Foundation

private func blackHoleIOProc(
    _ device: AudioObjectID,
    _ now: UnsafePointer<AudioTimeStamp>,
    _ inputData: UnsafePointer<AudioBufferList>,
    _ inputTime: UnsafePointer<AudioTimeStamp>,
    _ outputData: UnsafeMutablePointer<AudioBufferList>,
    _ outputTime: UnsafePointer<AudioTimeStamp>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    Unmanaged<BlackHoleOutput>.fromOpaque(clientData).takeUnretainedValue().render(outputData)
    return noErr
}

final class FloatRingBuffer: @unchecked Sendable {
    private var storage: [Float]
    private var readIndex = 0
    private var writeIndex = 0
    private var available = 0
    private let lock = NSLock()

    init(capacity: Int) { storage = [Float](repeating: 0, count: capacity) }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return available
    }

    func write(_ values: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        for value in values {
            if available == storage.count {
                readIndex = (readIndex + 1) % storage.count
                available -= 1
            }
            storage[writeIndex] = value
            writeIndex = (writeIndex + 1) % storage.count
            available += 1
        }
    }

    func read() -> Float {
        lock.lock()
        defer { lock.unlock() }
        guard available > 0 else { return 0 }
        let value = storage[readIndex]
        readIndex = (readIndex + 1) % storage.count
        available -= 1
        return value
    }

    /// 一次取出 `count` 个样本（不足的部分填 0），返回实际取到的个数。
    ///
    /// 为什么不用逐样本 `read()`：`render` 跑在 **CoreAudio 实时线程**上，
    /// 每次 IO 回调要几千次 lock/unlock，既浪费又增加优先级反转风险。
    /// 这里整批只加一次锁。
    @discardableResult
    func read(into destination: inout [Float], count: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let taken = min(count, available)
        for index in 0..<taken {
            destination[index] = storage[readIndex]
            readIndex = (readIndex + 1) % storage.count
        }
        for index in taken..<count { destination[index] = 0 }
        available -= taken
        return taken
    }

    /// 丢掉最旧的 n 个样本 —— 用来把积压压回目标水位，**限制延迟**。
    /// （远端帧是突发到达的，不设上限的话积压会慢慢变成成百毫秒的延迟。）
    func dropOldest(_ count: Int) {
        lock.lock()
        defer { lock.unlock() }
        let drop = min(count, available)
        guard drop > 0 else { return }
        readIndex = (readIndex + drop) % storage.count
        available -= drop
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        readIndex = 0
        writeIndex = 0
        available = 0
    }
}

/// 把 16 kHz 单声道 PCM 送进 **BlackHole 2ch**（虚拟声卡）。
///
/// ## 为什么要抖动缓冲（jitter buffer）
/// 遥控器的语音帧经蓝牙 + HCI 抓包后是**突发到达**的（实测帧间隔 3~50 ms，中位数 24 ms），
/// 而虚拟声卡按**稳定时钟**拉取。两边对不齐就会出现两种病：
///   - 缓冲太空 → 断音（听感上像"卡顿、拖"）
///   - 缓冲太满 → **延迟越积越大**
/// 所以这里做两件事：① 起播前攒够 `targetFrames`（40 ms）；② 积压超过
/// `maxBacklogFrames`（64 ms）就把最旧的丢掉 —— 把「变慢」换成「偶尔丢一点」。
final class BlackHoleOutput: @unchecked Sendable {
    /// 目标水位：默认 40 ms。够吃掉蓝牙抖动，又不至于变成可感延迟。
    /// （实测帧到达间隔 3~50 ms；管线本身延迟已压到 2 ms，所以不需要大缓冲。）
    ///
    /// 想再低就可以调（不用重编译）：
    ///   `defaults write local.iprc1000.adapter voiceJitterTargetMs -int 20`
    /// 然后重启 App。太小会开始断音，看 `outUnderruns` 判断。
    private var targetFrames = 1920
    /// 积压上限：目标水位的 1.6 倍。超过就丢最旧的，保证延迟不随时间增长。
    private var maxBacklogFrames = 3072
    private let defaultTargetMs = 40
    /// 期望的虚拟设备 IO 缓冲（帧）。越小延迟越低，但要驱动支持。
    private let wishBufferFrames: UInt32 = 256

    private let ring = FloatRingBuffer(capacity: 48000 * 2)
    private var device: AudioDeviceID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private(set) var sampleRate = 48000.0

    private var priming = true
    private var lastWriteAt = Date.distantPast
    /// `render` 的复用暂存缓冲（只在音频 IO 线程上访问）
    private var scratch = [Float](repeating: 0, count: 4096)

    // 诊断指标
    private(set) var deviceBufferFrames = 0
    private(set) var canSetBufferFrames = false
    private(set) var underruns = 0
    private(set) var droppedFrames = 0
    private(set) var playedFrames = 0
    private(set) var peakBufferedFrames = 0

    private(set) var started = false

    deinit { stop() }

    /// 缓冲里还压着多少毫秒（这是**我们额外加的延迟**）
    var bufferedMs: Double { Double(ring.count) / sampleRate * 1000 }
    /// 设备 IO 缓冲带来的延迟
    var deviceBufferMs: Double { Double(deviceBufferFrames) / sampleRate * 1000 }
    /// 本环节合计附加延迟
    var addedLatencyMs: Double { bufferedMs + deviceBufferMs }

    func start() -> (ok: Bool, message: String) {
        guard let found = Self.findDevice(named: "BlackHole 2ch") else {
            return (false, "未找到 BlackHole 2ch")
        }
        device = found
        sampleRate = Self.nominalSampleRate(of: found) ?? 48000

        // 允许免重编译调抖动缓冲（毫秒）
        let configuredMs = UserDefaults.standard.integer(forKey: "voiceJitterTargetMs")
        let targetMs = configuredMs > 0 ? configuredMs : defaultTargetMs
        targetFrames = max(1, targetMs * 48)          // 48 帧/ms @ 48 kHz
        maxBacklogFrames = targetFrames * 8 / 5

        // 尽量把设备 IO 缓冲调小（默认常是 512 帧 ≈ 10.7 ms）
        canSetBufferFrames = Self.setBufferFrameSize(wishBufferFrames, of: found)
        deviceBufferFrames = Self.bufferFrameSize(of: found)

        var proc: AudioDeviceIOProcID?
        let created = AudioDeviceCreateIOProcID(
            found, blackHoleIOProc, Unmanaged.passUnretained(self).toOpaque(), &proc
        )
        guard created == noErr, let proc else {
            return (false, "无法打开 BlackHole 2ch 输出（\(created)）")
        }
        ioProcID = proc
        let startedOK = AudioDeviceStart(found, proc)
        guard startedOK == noErr else {
            AudioDeviceDestroyIOProcID(found, proc)
            ioProcID = nil
            return (false, "无法启动 BlackHole 2ch（\(startedOK)）")
        }
        started = true
        return (true, "BlackHole 2ch 已就绪"
                + "（设备缓冲 \(deviceBufferFrames) 帧 = \(String(format: "%.1f", deviceBufferMs)) ms）")
    }

    func stop() {
        guard device != 0, let ioProcID else { return }
        AudioDeviceStop(device, ioProcID)
        AudioDeviceDestroyIOProcID(device, ioProcID)
        self.ioProcID = nil
        started = false
    }

    func enqueue16kMono(_ samples: [Int16]) {
        guard samples.count > 1 else { return }
        // 距上次写入超过 0.4 s 视为新的一段：清空重来，
        // 否则会把上一段遗留的积压带进新会话（表现为"越说越慢"）。
        let now = Date()
        if now.timeIntervalSince(lastWriteAt) > 0.4 {
            ring.reset()
            priming = true
        }
        lastWriteAt = now

        let ratio = sampleRate / 16000.0
        let outputCount = Int(Double(samples.count) * ratio)
        var resampled = [Float]()
        resampled.reserveCapacity(outputCount)
        for index in 0..<outputCount {
            let position = Double(index) / ratio
            let low = min(Int(position), samples.count - 1)
            let high = min(low + 1, samples.count - 1)
            let fraction = Float(position - Double(low))
            let a = Float(samples[low]) / Float(Int16.max)
            let b = Float(samples[high]) / Float(Int16.max)
            resampled.append(a + (b - a) * fraction)
        }
        ring.write(resampled)
        if ring.count > peakBufferedFrames { peakBufferedFrames = ring.count }
    }

    fileprivate func render(_ outputData: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(outputData)
        guard !buffers.isEmpty else { return }
        let frames = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
            / max(Int(buffers[0].mNumberChannels), 1)
        guard frames > 0 else { return }

        // 起播前先攒够目标水位，避免一上来就断音
        if priming {
            guard ring.count >= targetFrames else {
                underruns += 1
                fill(buffers, frames: frames, mono: nil)
                return
            }
            priming = false
        }

        // 积压超上限 → 丢最旧的，把附加延迟钉在 ~90 ms 以内
        let backlog = ring.count
        if backlog > maxBacklogFrames {
            let excess = backlog - targetFrames
            ring.dropOldest(excess)
            droppedFrames += excess
        }

        // 实时线程上不做堆分配：复用一块足够大的暂存缓冲
        if scratch.count < frames { scratch = [Float](repeating: 0, count: frames) }
        let taken = ring.read(into: &scratch, count: frames)
        if taken < frames { underruns += 1 }
        playedFrames += frames
        fill(buffers, frames: frames, mono: scratch)
    }

    private func fill(
        _ buffers: UnsafeMutableAudioBufferListPointer, frames: Int, mono: [Float]?
    ) {  // mono == nil → 输出静音
        for bufferIndex in buffers.indices {
            guard let data = buffers[bufferIndex].mData else { continue }
            let channels = max(Int(buffers[bufferIndex].mNumberChannels), 1)
            let pointer = data.bindMemory(to: Float.self, capacity: frames * channels)
            for frame in 0..<frames {
                let value = mono?[frame] ?? 0
                for channel in 0..<channels { pointer[frame * channels + channel] = value }
            }
        }
    }

    // MARK: - CoreAudio 查询

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func bufferFrameSize(of device: AudioDeviceID) -> Int {
        var address = address(kAudioDevicePropertyBufferFrameSize)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return 0
        }
        return Int(value)
    }

    @discardableResult
    private static func setBufferFrameSize(_ frames: UInt32, of device: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyBufferFrameSize)
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue else { return false }
        var value = frames
        return AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value
        ) == noErr
    }

    private static func findDevice(named name: String) -> AudioDeviceID? {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices
        ) == noErr else { return nil }
        return devices.first { deviceName(of: $0) == name }
    }

    private static func deviceName(of device: AudioDeviceID) -> String? {
        var address = address(kAudioObjectPropertyName)
        let value = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
        value.initialize(to: nil)
        defer {
            value.deinitialize(count: 1)
            value.deallocate()
        }
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, value) == noErr,
              let name = value.pointee else { return nil }
        return name as String
    }

    private static func nominalSampleRate(of device: AudioDeviceID) -> Double? {
        var address = address(kAudioDevicePropertyNominalSampleRate)
        var rate = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr else {
            return nil
        }
        return rate
    }
}
