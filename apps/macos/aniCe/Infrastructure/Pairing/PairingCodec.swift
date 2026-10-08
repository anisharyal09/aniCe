// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import Security

/// Typed errors encountered during the pairing handshake or transport.
enum PairingFailure: Error {
  case malformed, authentication, expired, transport, storage, cancelled
}

/// Pairing authentication method.
enum PairingMethod: UInt8, Codable {
  case qr = 1
  case pin = 2
}

/// Representation of an ephemeral QR pairing payload.
///
/// Encodes/decodes the canonical URI format:
/// `anice:pair:1:<base64url(version || rendezvous16 || psk32 || fingerprint32)>` (81 decoded bytes).
struct PairingQR {
  let rendezvous: Data
  var secret: Data
  let fingerprint: Data

  /// Canonical URI text representation.
  var text: String {
    "anice:pair:1:"
      + (Data([1]) + rendezvous + secret + fingerprint).base64EncodedString().replacingOccurrences(
        of: "+", with: "-"
      ).replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }

  /// Decodes and validates a QR URI string according to v1 specifications.
  static func decode(_ text: String) throws -> PairingQR {
    let prefix = "anice:pair:1:"
    guard text.hasPrefix(prefix), text.utf8.count == prefix.utf8.count + 108 else {
      throw PairingFailure.malformed
    }
    let body = String(text.dropFirst(prefix.count))
    guard
      let bytes = Data(
        base64Encoded: body.replacingOccurrences(of: "-", with: "+").replacingOccurrences(
          of: "_", with: "/")), bytes.count == 81, bytes.first == 1
    else { throw PairingFailure.malformed }
    let qr = PairingQR(
      rendezvous: bytes.subdata(in: 1..<17), secret: bytes.subdata(in: 17..<49),
      fingerprint: bytes.subdata(in: 49..<81))
    guard qr.text == text else { throw PairingFailure.malformed }
    return qr
  }
}

/// Wire serialization, framing, and cryptographic helper routines.
enum PairingCodec {
  static let writeUUID = "414E4953-4843-654A-494C-534149303903"
  static let indicateUUID = "414E4953-4843-654A-494C-534149303904"

  /// Encodes an unsigned integer as big-endian bytes of fixed width.
  static func number(_ value: UInt64, bytes: Int) -> Data {
    Data((0..<bytes).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
  }

  /// Decodes big-endian bytes into an unsigned integer.
  static func integer(_ data: Data) -> UInt64 { data.reduce(0) { ($0 << 8) | UInt64($1) } }

  /// Packs multiple byte buffers with uint32 big-endian length prefixes: `fields(x1, x2, ...)`.
  static func fields(_ values: [Data]) -> Data {
    values.reduce(Data()) { $0 + number(UInt64($1.count), bytes: 4) + $1 }
  }

  /// Parses uint32 length-prefixed fields from input data with bounds checking.
  static func parse(_ data: Data, maxFields: Int = 10) throws -> [Data] {
    guard data.count <= 4096 else { throw PairingFailure.malformed }
    var result: [Data] = []
    var offset = 0
    while offset < data.count {
      guard offset + 4 <= data.count, result.count < maxFields else {
        throw PairingFailure.malformed
      }
      let count = Int(integer(data.subdata(in: offset..<offset + 4)))
      offset += 4
      guard count <= data.count - offset else { throw PairingFailure.malformed }
      result.append(data.subdata(in: offset..<offset + count))
      offset += count
    }
    return result
  }

  /// Encodes a logical message with a 1-byte type header followed by packed fields.
  static func message(_ type: UInt8, _ values: [Data] = []) -> Data {
    Data([type]) + fields(values)
  }

  /// Validates message type and unpacks exact expected field count.
  static func unpack(_ data: Data, type: UInt8, count: Int) throws -> [Data] {
    guard data.first == type else { throw PairingFailure.malformed }
    let values = try parse(Data(data.dropFirst()))
    guard values.count == count else { throw PairingFailure.malformed }
    return values
  }

  /// Generates cryptographically secure random bytes via `SecRandomCopyBytes`.
  static func random(_ count: Int) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
      throw PairingFailure.authentication
    }
    return Data(bytes)
  }

  /// Generates a uniform random 6-digit PIN with rejection sampling to eliminate modulo bias.
  static func pin() throws -> String {
    while true {
      let n = integer(try random(4))
      if n < 4_294_000_000 { return String(format: "%06llu", n % 1_000_000) }
    }
  }

  /// Computes SHA-256 digest of input bytes.
  static func hash(_ bytes: Data) -> Data { Data(SHA256.hash(data: bytes)) }

  /// Derives labeled symmetric sub-key via HKDF-SHA256: `derive(K, label, H)`.
  static func derive(_ key: Data, _ label: String, _ hash: Data) -> SymmetricKey {
    HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: key), salt: hash,
      info: Data(("aniCe pairing v1 " + label).utf8), outputByteCount: 32)
  }

  /// Computes HMAC-SHA256 authentication code.
  static func mac(_ key: SymmetricKey, _ bytes: Data) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: bytes, using: key))
  }

  /// Constant-time byte array equality comparison.
  static func equal(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
  }

  /// Serializes and validates public device identity for transcript binding.
  static func identityBytes(_ identity: DeviceIdentity) throws -> Data {
    try identity.validate()
    return try JSONEncoder().encode(identity)
  }

  /// Encodes canonical identity proof bytes for P-256 ECDSA signing.
  static func proof(_ hash: Data, _ client: Data, _ server: Data, _ role: UInt8? = nil) -> Data {
    fields(
      [Data("aniCe identity proof v1".utf8), hash, client, server]
        + (role.map { [Data([$0])] } ?? []))
  }

  /// Encodes canonical storage receipt bytes for P-256 ECDSA signing.
  static func receipt(_ transcript: Data, _ role: UInt8) -> Data {
    fields([Data("aniCe trust stored v1".utf8), transcript, Data([role])])
  }
}

/// Fragmentation and reassembly handler for GATT MTU boundaries.
struct PairingReassembler {
  private var framing = GattReassembler(version: 1)
  private var budget = 0
  mutating func receive(_ fragment: Data) throws -> Data? {
    do {
      let result = try framing.receive(fragment)
      if let result {
        budget += result.count
        guard budget <= 32768 else { throw PairingFailure.malformed }
      }
      return result
    } catch is SessionFailure { throw PairingFailure.malformed }
  }
  static func fragments(_ data: Data, id: UInt64, capacity: Int) throws -> [Data] {
    do {
      return try GattReassembler.fragments(data, id: id, capacity: capacity, version: 1)
    } catch is SessionFailure { throw PairingFailure.malformed }
  }
}

/// Directional AES-256-GCM authenticated encryption channel.
///
/// Features:
/// - Direction-separated keys derived from bootstrap secret.
/// - Strict 64-bit sequence counters to prevent message replay.
/// - Authenticates transcript hash and direction byte as AAD.
final class PairingChannel {
  private var key: Data
  let hash: Data
  let transcript: Data
  let server: Bool
  private var sent: UInt64 = 0
  private var received: UInt64 = 0

  init(key: Data, transcript: Data, server: Bool) {
    self.key = key
    self.transcript = transcript
    hash = PairingCodec.hash(transcript)
    self.server = server
  }

  /// Generates the initial channel confirmation HMAC tag.
  func confirm() -> Data {
    PairingCodec.mac(PairingCodec.derive(key, "channel-confirm", hash), transcript)
  }

  /// Encrypts an inner message with AES-256-GCM, wrapping it in outer Message 7 format.
  func seal(_ bytes: Data) throws -> Data {
    guard sent < UInt64.max else { throw PairingFailure.authentication }
    let counter = PairingCodec.number(sent, bytes: 8)
    let direction: UInt8 = server ? 2 : 1
    let aad = PairingCodec.fields([
      Data("aniCe pairing encrypted v1".utf8), hash, Data([direction]), counter,
    ])
    let k = PairingCodec.derive(key, server ? "server-to-client" : "client-to-server", hash)
    let box = try AES.GCM.seal(
      bytes, using: k, nonce: AES.GCM.Nonce(data: Data(repeating: 0, count: 4) + counter),
      authenticating: aad)
    sent += 1
    return PairingCodec.message(7, [counter, box.ciphertext + box.tag])
  }

  /// Decrypts and authenticates outer Message 7, verifying sequence counters and AAD.
  func open(_ bytes: Data) throws -> Data {
    let f = try PairingCodec.unpack(bytes, type: 7, count: 2)
    guard f[0].count == 8, PairingCodec.integer(f[0]) == received, received < UInt64.max,
      f[1].count >= 16
    else { throw PairingFailure.authentication }
    let direction: UInt8 = server ? 1 : 2
    let aad = PairingCodec.fields([
      Data("aniCe pairing encrypted v1".utf8), hash, Data([direction]), f[0],
    ])
    let k = PairingCodec.derive(key, server ? "client-to-server" : "server-to-client", hash)
    let box = try AES.GCM.SealedBox(
      nonce: AES.GCM.Nonce(data: Data(repeating: 0, count: 4) + f[0]),
      ciphertext: f[1].dropLast(16), tag: f[1].suffix(16))
    let result = try AES.GCM.open(box, using: k, authenticating: aad)
    received += 1
    return result
  }

  /// Securely zeroes and purges encryption key material from memory.
  func destroy() {
    key.resetBytes(in: 0..<key.count)
    key.removeAll()
  }

  deinit { destroy() }
}
