// SPDX-License-Identifier: GPL-3.0-or-later
// Defines method-3 commitments and uniform numeric comparison using the shared pairing primitives.
import CryptoKit
import Foundation

/// Revocation is synchronous with a UI cancellation, even while the actor is signing or saving.
final class PairingAttemptLease: @unchecked Sendable {
  private let lock = NSLock()
  private var live = true
  var active: Bool { lock.lock(); defer { lock.unlock() }; return live }
  func cancel() { lock.lock(); defer { lock.unlock() }; live = false }
}

enum PairingSas {
  static let discoveryFlag: UInt16 = 1

  static func identityCommitment(role: UInt8, salt: Data, identity: Data) throws -> Data {
    guard role == 1 || role == 2, salt.count == 32, !identity.isEmpty, identity.count <= 2048 else {
      throw PairingFailure.malformed
    }
    return PairingCodec.hash(PairingCodec.fields([
      Data("aniCe sas identity v1".utf8), Data([role]), salt, identity,
    ]))
  }

  static func commitment(
    role: UInt8, rendezvous: Data, serverNonce: Data, publicKey: Data, nonce: Data,
    identityCommitment: Data
  ) throws -> Data {
    guard role == 1 || role == 2, rendezvous.count == 16, serverNonce.count == 32,
      publicKey.count == 65, nonce.count == 32, identityCommitment.count == 32
    else { throw PairingFailure.malformed }
    _ = try P256.KeyAgreement.PublicKey(x963Representation: publicKey)
    return PairingCodec.hash(PairingCodec.fields([
      Data("aniCe sas commitment v1".utf8), Data([3]), rendezvous, serverNonce,
      Data([role]), publicKey, nonce, identityCommitment,
    ]))
  }

  static func transcript(
    rendezvous: Data, serverNonce: Data, clientCommitment: Data, serverCommitment: Data,
    clientPublic: Data, serverPublic: Data, clientNonce: Data, serverComparisonNonce: Data,
    clientIdentityCommitment: Data, serverIdentityCommitment: Data
  ) throws -> Data {
    guard clientCommitment.count == 32, serverCommitment.count == 32,
      clientPublic != serverPublic
    else { throw PairingFailure.authentication }
    let client = try commitment(role: 1, rendezvous: rendezvous, serverNonce: serverNonce,
      publicKey: clientPublic, nonce: clientNonce, identityCommitment: clientIdentityCommitment)
    let server = try commitment(role: 2, rendezvous: rendezvous, serverNonce: serverNonce,
      publicKey: serverPublic, nonce: serverComparisonNonce, identityCommitment: serverIdentityCommitment)
    guard PairingCodec.equal(client, clientCommitment), PairingCodec.equal(server, serverCommitment)
    else { throw PairingFailure.authentication }
    return PairingCodec.fields([
      Data("aniCe pairing sas v1".utf8), Data([3]), rendezvous, serverNonce,
      clientCommitment, serverCommitment, clientPublic, serverPublic, clientNonce,
      serverComparisonNonce, clientIdentityCommitment, serverIdentityCommitment,
    ])
  }

  static func bootstrap(shared: Data, transcript: Data) -> Data {
    let hash = PairingCodec.hash(transcript)
    return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: shared), salt: hash,
      info: PairingCodec.fields([Data("aniCe sas bootstrap v1".utf8), hash]), outputByteCount: 32)
      .withUnsafeBytes { Data($0) }
  }

  static func digits(key: Data, transcript: Data) throws -> String {
    let hash = PairingCodec.hash(transcript)
    let digitsKey = PairingCodec.derive(key, "sas-digits", hash)
    for counter in UInt64(0)...UInt64(UInt32.max) {
      let bytes = PairingCodec.mac(digitsKey, PairingCodec.fields([
        Data("aniCe sas digits v1".utf8), hash, PairingCodec.number(counter, bytes: 4),
      ]))
      if let result = try decimal(Data(bytes.prefix(4))) { return result }
    }
    throw PairingFailure.authentication
  }

  static func decimal(_ bytes: Data) throws -> String? {
    guard bytes.count == 4 else { throw PairingFailure.malformed }
    let value = PairingCodec.integer(bytes)
    return value < 4_294_000_000 ? String(format: "%06llu", value % 1_000_000) : nil
  }
}
