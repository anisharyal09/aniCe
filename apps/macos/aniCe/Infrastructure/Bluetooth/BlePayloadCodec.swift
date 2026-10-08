// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum DiscoveryState: String { case idle, permissionNeeded, bluetoothOff, discovering, found, connecting, ready, failed }

enum BlePayloadCodec {
    static let serviceUUID = "414E4953-4843-654A-494C-534149303901"
    static let characteristicUUID = "414E4953-4843-654A-494C-534149303902"
    struct Payload: Equatable { let flags: UInt16; let nonce: Data }
    enum Failure: Error { case length, version }
    static func decode(_ data: Data) throws -> Payload {
        let bytes = [UInt8](data)
        guard bytes.count == 20 else { throw Failure.length }
        guard bytes[0] == 0 && bytes[1] == 1 else { throw Failure.version }
        return Payload(flags: UInt16(bytes[2]) << 8 | UInt16(bytes[3]), nonce: Data(bytes[4...]))
    }
    static func encode(nonce: Data, flags: UInt16 = 0) throws -> Data {
        guard nonce.count == 16 else { throw Failure.length }
        return Data([0, 1, UInt8(flags >> 8), UInt8(flags & 255)]) + nonce
    }
}
