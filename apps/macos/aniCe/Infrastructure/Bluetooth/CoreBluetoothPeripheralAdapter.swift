// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@preconcurrency import CoreBluetooth

@MainActor
final class CoreBluetoothPeripheralAdapter: NSObject, PeripheralAdapter, @preconcurrency CBPeripheralManagerDelegate {
    private var manager: CBPeripheralManager?
    private var characteristic: CBMutableCharacteristic?
    private var event: ((PeripheralEvent) -> Void)?
    private var read: ((Bool, Int) -> DiscoveryRead)?

    func begin(event: @escaping (PeripheralEvent) -> Void, read: @escaping (Bool, Int) -> DiscoveryRead) {
        self.event = event; self.read = read
        switch CBManager.authorization {
        case .notDetermined: event(.permissionPending)
        case .denied, .restricted: event(.denied); return
        case .allowedAlways: event(.initializing)
        @unknown default: event(.failure); return
        }
        manager = CBPeripheralManager(delegate: self, queue: nil,
                                      options: [CBPeripheralManagerOptionShowPowerAlertKey: false])
    }
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral === manager else { return }
        switch peripheral.state {
        case .poweredOn: event?(.available)
        case .poweredOff: event?(.off)
        case .unauthorized: event?(.denied)
        case .unsupported: event?(.unsupported)
        case .resetting: event?(.resetting)
        case .unknown:
            event?(CBManager.authorization == .notDetermined ? .permissionPending : .initializing)
        @unknown default: event?(.failure)
        }
    }
    func publish() {
        guard let manager, manager.state == .poweredOn else { event?(.failure); return }
        let value = CBMutableCharacteristic(type: CBUUID(string: BlePayloadCodec.characteristicUUID),
                                            properties: .read, value: nil, permissions: .readable)
        characteristic = value
        let service = CBMutableService(type: CBUUID(string: BlePayloadCodec.serviceUUID), primary: true)
        service.characteristics = [value]
        manager.add(service)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard peripheral === manager, service.uuid == CBUUID(string: BlePayloadCodec.serviceUUID) else { return }
        event?(error == nil ? .published : .failure)
    }
    func advertise() {
        manager?.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: BlePayloadCodec.serviceUUID)],
                                   CBAdvertisementDataLocalNameKey: "aniCe"])
    }
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard peripheral === manager else { return }
        event?(error == nil ? .advertising : .failure)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard peripheral === manager else { peripheral.respond(to: request, withResult: .unlikelyError); return }
        let result = read?(characteristic != nil && request.characteristic.uuid == characteristic?.uuid, request.offset) ?? .unavailable
        switch result {
        case .value(let data): request.value = data; peripheral.respond(to: request, withResult: .success)
        case .invalidOffset: peripheral.respond(to: request, withResult: .invalidOffset)
        case .unknownCharacteristic: peripheral.respond(to: request, withResult: .attributeNotFound)
        case .unavailable: peripheral.respond(to: request, withResult: .unlikelyError)
        }
    }
    func stop() {
        event = nil; read = nil
        manager?.stopAdvertising()
        if manager?.state == .poweredOn { manager?.removeAllServices() }
        manager?.delegate = nil; manager = nil; characteristic = nil
    }
}
