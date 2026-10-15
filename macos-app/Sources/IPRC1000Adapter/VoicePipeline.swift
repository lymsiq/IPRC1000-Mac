import CRemoteSupport
import CoreBluetooth
import Foundation
import os

enum VoicePacketAssembler {
    private static let sequences: Set<UInt8> = [0x08, 0x38, 0xC8, 0xF8]

    struct State {
        fileprivate var bytes: [UInt8] = []
        fileprivate var packetCount = 0
    }

    /// The remote splits one 57-byte mSBC frame across three 20-byte BLE packets.
    /// Packet one starts with the two-byte H2 header; byte 59 is padding.
    static func append(_ packet: [UInt8], to state: inout State) -> [UInt8]? {
        guard packet.count == 20 else {
            state = State()
            return nil
        }
        let isStart = packet.count >= 3 && packet[0] == 0x01
            && sequences.contains(packet[1]) && packet[2] == 0xAD
        if isStart {
            state.bytes = packet
            state.packetCount = 1
            return nil
        }
        guard state.packetCount > 0 else { return nil }
        state.bytes.append(contentsOf: packet)
        state.packetCount += 1
        guard state.packetCount == 3 else { return nil }
        defer { state = State() }
        guard state.bytes.count == 60 else { return nil }
        return Array(state.bytes[2..<59])
    }
}

final class MSBCDecoder {
    private let reference: IPRCSBCDecoderRef

    init?() {
        guard let decoder = iprc_sbc_decoder_create() else { return nil }
        reference = decoder
    }

    deinit { iprc_sbc_decoder_destroy(reference) }

    func decode(_ frame: [UInt8]) -> [Int16]? {
        guard frame.count == 57 else { return nil }
        var output = [Int16](repeating: 0, count: 256)
        let count = frame.withUnsafeBytes { input in
            output.withUnsafeMutableBufferPointer { pcm in
                iprc_sbc_decode_msbc(
                    reference,
                    input.bindMemory(to: UInt8.self).baseAddress,
                    frame.count,
                    pcm.baseAddress,
                    pcm.count
                )
            }
        }
        guard count > 0 else { return nil }
        return Array(output.prefix(Int(count)))
    }
}

enum GoogleVoiceADPCM {
    private static let stepTable = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31,
        34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143,
        157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544,
        598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707,
        1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871,
        5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635,
        13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767
    ]
    private static let indexTable = [-1, -1, -1, -1, 2, 4, 6, 8]

    /// Google Voice 0.4/1.0: big-endian sequence, reserved byte, predictor,
    /// step index, then 256 IMA-ADPCM samples packed into 128 bytes.
    static func decode(_ packet: [UInt8]) -> [Int16]? {
        guard packet.count >= 134, packet[2] == 0, packet[5] <= 88 else { return nil }
        var predictor = Int(Int16(bitPattern: UInt16(packet[3]) << 8 | UInt16(packet[4])))
        var index = Int(packet[5])
        var output: [Int16] = []
        output.reserveCapacity(256)

        for byte in packet[6..<134] {
            for code in [Int(byte & 0x0F), Int(byte >> 4)] {
                let step = stepTable[index]
                var difference = step >> 3
                if code & 1 != 0 { difference += step >> 2 }
                if code & 2 != 0 { difference += step >> 1 }
                if code & 4 != 0 { difference += step }
                predictor += code & 8 != 0 ? -difference : difference
                predictor = min(32767, max(-32768, predictor))
                index = min(88, max(0, index + indexTable[code & 7]))
                output.append(Int16(predictor))
            }
        }
        return output
    }
}

final class VoiceController: NSObject, @unchecked Sendable {
    private static let logger = Logger(subsystem: "local.iprc1000.adapter", category: "BluetoothVoice")
    private static var hidService: CBUUID { CBUUID(string: "1812") }
    private static var atvService: CBUUID { CBUUID(string: "AB5E0001-5A21-4F05-BC7D-AF01F617B664") }
    private static var atvTX: CBUUID { CBUUID(string: "AB5E0002-5A21-4F05-BC7D-AF01F617B664") }
    private static var atvRX: CBUUID { CBUUID(string: "AB5E0003-5A21-4F05-BC7D-AF01F617B664") }
    private static var atvControl: CBUUID { CBUUID(string: "AB5E0004-5A21-4F05-BC7D-AF01F617B664") }
    var onStatus: @Sendable (String, Bool) -> Void = { _, _ in }
    var onLevel: @Sendable (Float) -> Void = { _ in }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var reportReferences: [ObjectIdentifier: CBCharacteristic] = [:]
    private var audioCharacteristic: CBCharacteristic?
    private var controlInputCharacteristic: CBCharacteristic?
    private var controlFeatureCharacteristic: CBCharacteristic?
    private var atvTXCharacteristic: CBCharacteristic?
    private var atvRXCharacteristic: CBCharacteristic?
    private var atvControlCharacteristic: CBCharacteristic?
    private var sentATVCapabilities = false
    private var assembler = VoicePacketAssembler.State()
    private let decoder = MSBCDecoder()
    private let output = BlackHoleOutput()
    private let classicProbe = ClassicBluetoothProbe()
    private var voicePackets = 0

    override init() {
        super.init()
        classicProbe.onTargetStatus = { [weak self] message in
            self?.onStatus(message, false)
        }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func start() {
        let audioStatus = output.start()
        if !audioStatus.ok {
            onStatus(audioStatus.message, false)
        } else {
            onStatus("BlackHole 2ch 已就绪，正在连接遥控器…", false)
        }
        if central.state == .poweredOn { findRemote() }
        classicProbe.start()
    }

    private func findRemote() {
        let connectedPeripherals = central.retrieveConnectedPeripherals(
            withServices: [Self.atvService, Self.hidService]
        )
        let connectedNames = connectedPeripherals.map { $0.name ?? "<nil>" }.joined(separator: ",")
        Self.logger.notice(
            "connected HID peripherals=\(connectedPeripherals.count, privacy: .public) names=\(connectedNames, privacy: .public)"
        )
        if let connected = connectedPeripherals.first(where: { $0.name == "IPRC1000" }) {
            connect(connected)
            return
        }
        central.scanForPeripherals(
            // This firmware does not include its service UUIDs in pairing advertisements.
            // Discovery remains isolated by the exact IPRC1000 name before connecting.
            withServices: nil,
            options: nil
        )
        onStatus("正在查找 IPRC1000 的 BLE 语音服务…", false)
    }

    private func connect(_ remote: CBPeripheral) {
        guard peripheral == nil else { return }
        central.stopScan()
        peripheral = remote
        remote.delegate = self
        central.connect(remote)
        onStatus("正在连接 IPRC1000 语音通道…", false)
    }

    private func resetCharacteristics() {
        reportReferences.removeAll()
        audioCharacteristic = nil
        controlInputCharacteristic = nil
        controlFeatureCharacteristic = nil
        atvTXCharacteristic = nil
        atvRXCharacteristic = nil
        atvControlCharacteristic = nil
        sentATVCapabilities = false
        assembler = .init()
    }

    private func sendControl(_ bytes: [UInt8]) {
        guard let peripheral, let characteristic = controlFeatureCharacteristic else {
            onStatus("遥控器未暴露语音控制写入报告（F8 Feature）", false)
            return
        }
        peripheral.writeValue(Data(bytes), for: characteristic, type: .withResponse)
    }

    private func sendATV(_ bytes: [UInt8]) {
        guard let peripheral, let characteristic = atvTXCharacteristic else { return }
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write)
            ? .withResponse : .withoutResponse
        peripheral.writeValue(Data(bytes), for: characteristic, type: type)
    }

    private func finishATVSetupIfReady() {
        guard !sentATVCapabilities, peripheral != nil,
              let rx = atvRXCharacteristic, let control = atvControlCharacteristic,
              rx.isNotifying, control.isNotifying else { return }
        sentATVCapabilities = true
        // Android TV Voice 1.0, host supports ADPCM at 8 kHz and 16 kHz.
        sendATV([0x0A, 0x01, 0x00, 0x00, 0x03])
        Self.logger.notice("Android TV Voice notifications enabled; sent capabilities request")
        onStatus("语音通道就绪；按住遥控器麦克风键说话", true)
    }
}

extension VoiceController: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Self.logger.notice("central state=\(central.state.rawValue, privacy: .public)")
        switch central.state {
        case .poweredOn: findRemote()
        case .unauthorized: onStatus("请在“隐私与安全性 → 蓝牙”中允许本 App", false)
        case .poweredOff: onStatus("蓝牙已关闭", false)
        case .unsupported: onStatus("当前运行环境未向 App 提供蓝牙控制器", false)
        default: onStatus("正在等待蓝牙可用…", false)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if peripheral.name == "IPRC1000" {
            Self.logger.notice("discovered BLE target name=IPRC1000")
            connect(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Self.logger.notice(
            "connected name=\(peripheral.name ?? "<nil>", privacy: .public) id=\(peripheral.identifier.uuidString, privacy: .public)"
        )
        resetCharacteristics()
        peripheral.discoverServices(nil)
        onStatus("已连接，正在读取 HID 语音报告…", false)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        self.peripheral = nil
        onStatus("语音通道连接失败：\(error?.localizedDescription ?? "未知错误")", false)
        findRemote()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?) {
        self.peripheral = nil
        resetCharacteristics()
        onStatus("IPRC1000 语音通道已断开", false)
        findRemote()
    }
}

extension VoiceController: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            onStatus("读取 BLE 服务失败：\(error!.localizedDescription)", false)
            return
        }
        let services = peripheral.services?.map { $0.uuid.uuidString }.joined(separator: ",") ?? "<none>"
        Self.logger.notice("services=\(services, privacy: .public)")
        if let atv = peripheral.services?.first(where: { $0.uuid == Self.atvService }) {
            peripheral.discoverCharacteristics(
                [Self.atvTX, Self.atvRX, Self.atvControl], for: atv
            )
        } else if let hid = peripheral.services?.first(where: { $0.uuid == Self.hidService }) {
            peripheral.discoverCharacteristics([CBUUID(string: "2A4D")], for: hid)
        } else {
            onStatus("遥控器未暴露 Android TV Voice 或 HID 语音服务", false)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        let discovered = service.characteristics?.map {
            "\($0.uuid.uuidString):\($0.properties.rawValue)"
        }.joined(separator: ",") ?? "<none>"
        Self.logger.notice(
            "characteristics service=\(service.uuid.uuidString, privacy: .public) values=\(discovered, privacy: .public)"
        )
        guard error == nil, let characteristics = service.characteristics,
              !characteristics.isEmpty else {
            onStatus("语音服务中没有可用特征", false)
            return
        }
        if service.uuid == Self.atvService {
            atvTXCharacteristic = characteristics.first { $0.uuid == Self.atvTX }
            atvRXCharacteristic = characteristics.first { $0.uuid == Self.atvRX }
            atvControlCharacteristic = characteristics.first { $0.uuid == Self.atvControl }
            guard atvTXCharacteristic != nil,
                  let rx = atvRXCharacteristic, let control = atvControlCharacteristic else {
                onStatus("Android TV Voice 服务特征不完整", false)
                return
            }
            peripheral.setNotifyValue(true, for: rx)
            peripheral.setNotifyValue(true, for: control)
            return
        }
        for characteristic in characteristics {
            peripheral.discoverDescriptors(for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil else {
            onStatus("启用语音通知失败：\(error!.localizedDescription)", false)
            return
        }
        finishATVSetupIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil else { return }
        for descriptor in characteristic.descriptors ?? [] where descriptor.uuid == CBUUID(string: "2908") {
            reportReferences[ObjectIdentifier(descriptor)] = characteristic
            peripheral.readValue(for: descriptor)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor,
                    error: Error?) {
        guard error == nil,
              let characteristic = reportReferences.removeValue(forKey: ObjectIdentifier(descriptor)),
              let data = descriptor.value as? Data, data.count >= 2 else { return }
        let reportID = data[data.startIndex]
        let reportType = data[data.index(after: data.startIndex)]
        switch (reportID, reportType) {
        case (0xF7, 1):
            audioCharacteristic = characteristic
            peripheral.setNotifyValue(true, for: characteristic)
        case (0xF8, 1):
            controlInputCharacteristic = characteristic
            peripheral.setNotifyValue(true, for: characteristic)
        case (0xF8, 3):
            controlFeatureCharacteristic = characteristic
        default: break
        }
        if audioCharacteristic != nil && controlInputCharacteristic != nil
            && controlFeatureCharacteristic != nil {
            onStatus("语音通道就绪；按住遥控器麦克风键说话", true)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil, let value = characteristic.value else { return }
        let bytes = [UInt8](value)
        if characteristic === atvControlCharacteristic {
            guard let command = bytes.first else { return }
            Self.logger.notice("Android TV Voice control=\(command, format: .hex)")
            if command == 0x08 {
                sendATV([0x0C, 0x00, 0x02])
                onStatus("正在传送遥控器麦克风到 BlackHole 2ch", true)
            } else if command == 0x00 {
                onLevel(0)
                onStatus("语音通道就绪；按住麦克风键说话", true)
            }
        } else if characteristic === atvRXCharacteristic {
            voicePackets += 1
            if let pcm = GoogleVoiceADPCM.decode(bytes) {
                output.enqueue16kMono(pcm)
                let peak = pcm.reduce(Int16(0)) { max($0, Int16(clamping: abs(Int($1)))) }
                onLevel(Float(peak) / Float(Int16.max))
            } else {
                Self.logger.error("invalid Android TV Voice audio packet length=\(bytes.count)")
            }
        } else if characteristic === controlInputCharacteristic {
            let payload = bytes.first == 0xF8 ? Array(bytes.dropFirst()) : bytes
            guard let command = payload.first else { return }
            if command == 0x0C {
                assembler = .init()
                sendControl([0x02, 0, 1, 0, 0, 0, 0])
                onStatus("正在传送遥控器麦克风到 BlackHole 2ch", true)
            } else if command == 0x0D {
                sendControl([0x03, 0, 1, 0, 0, 0, 0])
                onStatus("语音通道就绪；按住麦克风键说话", true)
            }
        } else if characteristic === audioCharacteristic {
            voicePackets += 1
            if let frame = VoicePacketAssembler.append(bytes, to: &assembler),
               let pcm = decoder?.decode(frame) {
                output.enqueue16kMono(pcm)
                let peak = pcm.reduce(Int16(0)) { max($0, Int16(clamping: abs(Int($1)))) }
                onLevel(Float(peak) / Float(Int16.max))
            }
        }
    }
}
