import Foundation
import IOBluetooth
import os

/// Read-only discovery of services exposed by the remote over Bluetooth Classic.
/// The address is neither persisted nor used for device identity.
final class ClassicBluetoothProbe: NSObject, IOBluetoothDeviceAsyncCallbacks,
                                   @unchecked Sendable {
    private static let logger = Logger(
        subsystem: "local.iprc1000.adapter",
        category: "ClassicBluetooth"
    )

    var onTargetStatus: @Sendable (String) -> Void = { _ in }

    private var target: IOBluetoothDevice?
    private var dumpedServices = false

    func start() {
        guard target == nil else { return }
        if let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice])?
            .first(where: { $0.name == "IPRC1000" }) {
            inspect(paired)
        }
    }

    private func inspect(_ device: IOBluetoothDevice) {
        guard target == nil, device.name == "IPRC1000" else { return }
        target = device
        Self.logger.notice(
            "classic target found name=\(device.nameOrAddress, privacy: .public) class=\(device.classOfDevice, privacy: .public)"
        )
        if dumpTargetServices() { return }
        onTargetStatus("已发现 IPRC1000，正在读取经典蓝牙 SDP 服务…")
        let result = device.performSDPQuery(self)
        Self.logger.notice("SDP query start status=\(result, privacy: .public)")
        if result != kIOReturnSuccess {
            onTargetStatus("经典蓝牙 SDP 查询启动失败：\(result)")
        } else {
            for delay in [2.0, 6.0, 12.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.dumpTargetServices()
                }
            }
        }
    }

    func remoteNameRequestComplete(_ device: IOBluetoothDevice?, status: IOReturn) {}

    func connectionComplete(_ device: IOBluetoothDevice?, status: IOReturn) {}

    func sdpQueryComplete(_ device: IOBluetoothDevice?, status: IOReturn) {
        guard device != nil else {
            onTargetStatus("经典蓝牙 SDP 查询没有返回设备")
            return
        }
        _ = dumpTargetServices(status: status)
    }

    @discardableResult
    private func dumpTargetServices(status: IOReturn = kIOReturnSuccess) -> Bool {
        guard !dumpedServices, let target else { return dumpedServices }
        let records = target.services as? [IOBluetoothSDPServiceRecord] ?? []
        Self.logger.notice(
            "SDP query complete status=\(status, privacy: .public) records=\(records.count, privacy: .public)"
        )
        guard status == kIOReturnSuccess else {
            onTargetStatus("经典蓝牙 SDP 查询失败：\(status)")
            return false
        }
        guard !records.isEmpty else { return false }
        dumpedServices = true
        var hasPublishedVoiceChannel = false

        for (index, record) in records.enumerated() {
            var psm: BluetoothL2CAPPSM = 0
            var channel: BluetoothRFCOMMChannelID = 0
            let hasPSM = record.getL2CAPPSM(&psm) == kIOReturnSuccess
            let hasRFCOMM = record.getRFCOMMChannelID(&channel) == kIOReturnSuccess
            if hasRFCOMM || (hasPSM && psm != 0x0001 && psm != 0x0011) {
                hasPublishedVoiceChannel = true
            }
            let name = record.getServiceName() ?? "<unnamed>"
            let attributes = record.attributes
                .sorted { String(describing: $0.key) < String(describing: $1.key) }
                .map { key, value in
                    let attribute = (key as? NSNumber)?.uint16Value ?? 0
                    let element = value as? IOBluetoothSDPDataElement
                    return String(
                        format: "0x%04X=%@", attribute,
                        String(describing: element?.getValue() ?? value as AnyObject)
                    )
                }
                .joined(separator: ";")
            Self.logger.notice(
                "SDP record=\(index, privacy: .public) name=\(name, privacy: .public) psm=\(hasPSM ? String(format: "0x%04X", psm) : "none", privacy: .public) rfcomm=\(hasRFCOMM ? String(channel) : "none", privacy: .public) attrs=\(attributes, privacy: .public)"
            )
        }
        if hasPublishedVoiceChannel {
            onTargetStatus("经典蓝牙 SDP 已读取：发现 \(records.count) 条服务")
        } else {
            onTargetStatus("当前遥控器固件仅公开键盘 HID，未提供麦克风数据通道")
        }
        return true
    }
}
