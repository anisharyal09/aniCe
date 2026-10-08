// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

enum SessionCrypto {
  static func hash(_ bytes: Data) -> Data { Data(SHA256.hash(data: bytes)) }
  static func extract(_ salt: Data, _ ikm: Data) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: ikm, using: SymmetricKey(data: salt)))
  }
  static func kdf(_ prk: Data, _ label: Int64, _ context: Data, _ length: Int) throws -> Data {
    guard prk.count == 32, (1...4096).contains(length) else { throw SessionFailure.malformed }
    let info = try SessionCbor.sequence(.integer(label), .bytes(context), .integer(Int64(length)))
    return HKDF<SHA256>.expand(
      pseudoRandomKey: SymmetricKey(data: prk), info: info, outputByteCount: length
    ).withUnsafeBytes { Data($0) }
  }
  // Only immutable device ID/key fields bind trust; display names do not enter the transcript.
  static func credential(_ identity: DeviceIdentity) throws -> SessionCBOR {
    try identity.validate()
    guard let point = Data(base64Encoded: identity.publicKey) else {
      throw SessionFailure.malformed
    }
    let key = SessionCBOR.map([
      .init(.integer(1), .integer(2)), .init(.integer(3), .integer(-7)),
      .init(.integer(-1), .integer(1)), .init(.integer(-2), .bytes(point.subdata(in: 1..<33))),
      .init(.integer(-3), .bytes(point.subdata(in: 33..<65))),
    ])
    return .map([
      .init(.integer(2), .text(identity.deviceId)),
      .init(.integer(8), .map([.init(.integer(1), key)])),
    ])
  }
  static func kid(_ identity: DeviceIdentity) throws -> Data {
    try identity.validate()
    guard let point = Data(base64Encoded: identity.publicKey) else {
      throw SessionFailure.malformed
    }
    return hash(point)
  }
  static func idCredential(_ identity: DeviceIdentity) throws -> SessionCBOR {
    .map([.init(.integer(4), .bytes(try kid(identity)))])
  }
  static func signingInput(_ identity: DeviceIdentity, _ th: Data, _ mac: Data) throws -> Data {
    try SessionCbor.encode(
      .array([
        .text("Signature1"), .bytes(try SessionCbor.encode(idCredential(identity))),
        .bytes(try SessionCbor.sequence(.bytes(th), credential(identity))), .bytes(mac),
      ]))
  }
  static func aad(_ th: Data) throws -> Data {
    try SessionCbor.encode(.array([.text("Encrypt0"), .bytes(Data()), .bytes(th)]))
  }
  static func aead(_ key: Data, _ iv: Data, _ th: Data, _ bytes: Data, encrypt: Bool) throws -> Data
  {
    guard key.count == 32, iv.count == 12 else { throw SessionFailure.malformed }
    let nonce = try ChaChaPoly.Nonce(data: iv)
    if encrypt {
      let sealed = try ChaChaPoly.seal(
        bytes, using: SymmetricKey(data: key), nonce: nonce, authenticating: aad(th))
      return sealed.ciphertext + sealed.tag
    }
    guard bytes.count >= 16 else { throw SessionFailure.malformed }
    do {
      let box = try ChaChaPoly.SealedBox(
        nonce: nonce, ciphertext: bytes.dropLast(16), tag: bytes.suffix(16))
      return try ChaChaPoly.open(box, using: SymmetricKey(data: key), authenticating: aad(th))
    } catch CryptoKitError.authenticationFailure { throw SessionFailure.authentication }
  }
  static func agree(_ privateKey: P256.KeyAgreement.PrivateKey, _ peerX: Data) throws -> Data {
    guard peerX.count == 32 else { throw SessionFailure.malformed }
    let publicKey: P256.KeyAgreement.PublicKey
    do {
      publicKey = try P256.KeyAgreement.PublicKey(compressedRepresentation: Data([2]) + peerX)
    } catch { throw SessionFailure.malformed }
    return try privateKey.sharedSecretFromKeyAgreement(with: publicKey).withUnsafeBytes { Data($0) }
  }
}

/// Converts strict minimal DER to/from fixed-width COSE ES256, enforcing 1 <= r,s < n.
enum SessionSignature {
  private static let order = Data([
    0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xbc, 0xe6, 0xfa, 0xad, 0xa7, 0x17, 0x9e, 0x84, 0xf3, 0xb9, 0xca, 0xc2, 0xfc, 0x63, 0x25, 0x51,
  ])
  private static func validate(_ scalar: Data) throws {
    guard scalar.count == 32, scalar.contains(where: { $0 != 0 }),
      scalar.lexicographicallyPrecedes(order)
    else { throw SessionFailure.malformed }
  }
  static func derToCose(_ data: Data) throws -> Data {
    let der = Data(data)
    guard (8...72).contains(der.count), der[0] == 0x30, Int(der[1]) == der.count - 2 else {
      throw SessionFailure.malformed
    }
    var offset = 2
    var result = Data()
    for _ in 0..<2 {
      guard offset + 2 <= der.count, der[offset] == 2 else { throw SessionFailure.malformed }
      let length = Int(der[offset + 1])
      offset += 2
      guard (1...33).contains(length), offset + length <= der.count, der[offset] < 128 else {
        throw SessionFailure.malformed
      }
      if length > 1, der[offset] == 0 {
        guard der[offset + 1] & 128 != 0 else { throw SessionFailure.malformed }
      }
      var scalar = der.subdata(in: offset..<(offset + length))
      offset += length
      if scalar.count == 33 {
        guard scalar.first == 0 else { throw SessionFailure.malformed }
        scalar.removeFirst()
      }
      scalar = Data(repeating: 0, count: 32 - scalar.count) + scalar
      try validate(scalar)
      result.append(scalar)
    }
    guard offset == der.count else { throw SessionFailure.malformed }
    return result
  }
  static func coseToDer(_ data: Data) throws -> Data {
    guard data.count == 64 else { throw SessionFailure.malformed }
    var body = Data()
    for i in 0..<2 {
      var scalar = data.subdata(in: (i * 32)..<(i * 32 + 32))
      try validate(scalar)
      while scalar.count > 1, scalar.first == 0 { scalar.removeFirst() }
      if let first = scalar.first, first >= 128 { scalar = Data([0]) + scalar }
      body.append(Data([2, UInt8(scalar.count)]) + scalar)
    }
    return Data([0x30, UInt8(body.count)]) + body
  }
}
