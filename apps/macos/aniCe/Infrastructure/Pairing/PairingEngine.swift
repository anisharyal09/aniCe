// SPDX-License-Identifier: GPL-3.0-or-later
// Owns Mac pairing authentication, mutual approval and signed trust-receipt exchange.
import CryptoKit
import Foundation

actor PairingEngine {
  let method: PairingMethod
  let rendezvous: Data
  let serverNonce: Data
  private(set) var qr: PairingQR?
  private(set) var pin: String?
  let local: DeviceIdentity

  private let identity: IdentityService
  private let store: PeerTrustStore
  private let send: @Sendable (Data) async -> Void
  private let event: @Sendable (String, DeviceIdentity?) async -> Void

  private var pake: Data?
  private var stage = 0
  private var attempts = 0
  private var generation = 0
  private var ephemeral: P256.KeyAgreement.PrivateKey?
  private var clientPublic = Data()
  private var clientNonce = Data()
  private var serverPublic = Data()
  private var bootstrap = Data()
  private var channel: PairingChannel?
  private var peer: DeviceIdentity?
  private var peerBytes: Data?
  private var proofVerified = false
  private var localApproved = false
  private var peerApproved = false
  private var prepared = false
  private var receiptSent = false
  private var receiptReceived = false
  private let localBytes: Data

  init(
    method: PairingMethod, identity: IdentityService, store: PeerTrustStore,
    send: @escaping @Sendable (Data) async -> Void,
    event: @escaping @Sendable (String, DeviceIdentity?) async -> Void
  ) async throws {
    self.method = method
    self.identity = identity
    self.store = store
    self.send = send
    self.event = event
    local = try await identity.publicIdentity()
    localBytes = try PairingCodec.identityBytes(local)
    rendezvous = try PairingCodec.random(16)
    serverNonce = try PairingCodec.random(32)
    if method == .qr {
      let fingerprintText = local.fingerprint
      let fingerprint = Data(
        stride(from: 0, to: 64, by: 2).map { offset in
          let a = fingerprintText.index(fingerprintText.startIndex, offsetBy: offset)
          let b = fingerprintText.index(a, offsetBy: 2)
          return UInt8(fingerprintText[a..<b], radix: 16)!
        })
      qr = PairingQR(
        rendezvous: rendezvous, secret: try PairingCodec.random(32), fingerprint: fingerprint)
      pin = nil
    } else {
      qr = nil
      pin = try PairingCodec.pin()
      pake = try NativePake.call(1, [Data(pin!.utf8), rendezvous])
    }
  }

  func invitation() -> Data {
    PairingCodec.message(2, [Data([method.rawValue]), rendezvous, serverNonce])
  }

  func receive(_ data: Data) async throws {
    if data == PairingCodec.message(1) {
      await send(invitation())
      return
    }

    if stage == 0 {
      let f = try PairingCodec.unpack(data, type: 3, count: 4)
      guard attempts < 5, f[0] == Data([method.rawValue]), f[1] == rendezvous, f[2].count == 32
      else { throw PairingFailure.authentication }
      attempts += 1
      clientNonce = f[2]
      clientPublic = f[3]
      stage = 1
      await event("authenticating", nil)

      if method == .qr {
        // QR mode: P-256 ECDH with 256-bit QR PSK salt
        guard clientPublic.count == 65 else { throw PairingFailure.authentication }
        let publicKey = try P256.KeyAgreement.PublicKey(x963Representation: clientPublic)
        let key = P256.KeyAgreement.PrivateKey()
        ephemeral = key
        serverPublic = key.publicKey.x963Representation
        let shared = try key.sharedSecretFromKeyAgreement(with: publicKey)
        let t = transcript()
        let h = PairingCodec.hash(t)
        let k = shared.hkdfDerivedSymmetricKey(
          using: SHA256.self, salt: qr!.secret,
          sharedInfo: PairingCodec.fields([Data("aniCe qr bootstrap v1".utf8), h]),
          outputByteCount: 32)
        bootstrap = k.withUnsafeBytes { Data($0) }
        let mac = PairingCodec.mac(PairingCodec.derive(bootstrap, "server-auth", h), t)
        await send(PairingCodec.message(4, [serverNonce, serverPublic, mac]))
      } else {
        // PIN mode: OPAQUE login start via Rust bridge
        guard let pake else { throw PairingFailure.authentication }
        serverPublic = try NativePake.call(3, [pake, clientPublic, context()])
        await send(PairingCodec.message(4, [serverNonce, serverPublic, Data()]))
      }
    // Stage 1: Process ClientFinish (Message 5) -> establish directional encrypted channel
    } else if stage == 1 {
      let f = try PairingCodec.unpack(data, type: 5, count: 1)
      let t = transcript()
      let h = PairingCodec.hash(t)
      if method == .qr {
        guard
          PairingCodec.equal(
            f[0], PairingCodec.mac(PairingCodec.derive(bootstrap, "client-auth", h), t))
        else { throw PairingFailure.authentication }
      } else {
        guard let pake else { throw PairingFailure.authentication }
        var key = try NativePake.call(5, [pake, f[0]])
        defer { key.resetBytes(in: 0..<key.count) }
        let k = HKDF<SHA256>.deriveKey(
          inputKeyMaterial: SymmetricKey(data: key), salt: h,
          info: Data("aniCe pin bootstrap v1".utf8), outputByteCount: 32)
        bootstrap = k.withUnsafeBytes { Data($0) }
      }
      channel = PairingChannel(key: bootstrap, transcript: t, server: true)
      bootstrap.resetBytes(in: 0..<bootstrap.count)
      bootstrap.removeAll()
      ephemeral = nil
      stage = 2
      await send(PairingCodec.message(6, [channel!.confirm()]))
      await send(try channel!.seal(PairingCodec.message(10, [localBytes])))
    // Stage 2+: Process inner encrypted messages (Type 7 payload)
    } else {
      guard let channel else { throw PairingFailure.authentication }
      let plain = try channel.open(data)
      switch plain.first {
      case 10:
        guard peer == nil else { throw PairingFailure.malformed }
        let f = try PairingCodec.unpack(plain, type: 10, count: 1)
        guard f[0].count <= 2048 else { throw PairingFailure.malformed }
        let record: DeviceIdentity
        do { record = try DeviceIdentity.decode(f[0]) }
        catch { throw PairingFailure.malformed }
        guard record.platform == "android", record.deviceId != local.deviceId else {
          throw PairingFailure.authentication
        }
        peer = record
        peerBytes = f[0]
        let op = generation
        let signature = try await identity.sign(
          message: PairingCodec.proof(channel.hash, f[0], localBytes, 2))
        guard op == generation, signature.identity == local else { throw PairingFailure.cancelled }
        await send(try channel.seal(PairingCodec.message(11, [signature.signature])))

      case 11:
        guard let peer, let peerBytes, !proofVerified else { throw PairingFailure.authentication }
        let f = try PairingCodec.unpack(plain, type: 11, count: 1)
        guard
          peer.verify(
            message: PairingCodec.proof(channel.hash, peerBytes, localBytes, 1), signature: f[0])
        else { throw PairingFailure.authentication }
        proofVerified = true
        await event("approval", peer)

      case 12:
        _ = try PairingCodec.unpack(plain, type: 12, count: 0)
        guard proofVerified, !peerApproved else { throw PairingFailure.authentication }
        peerApproved = true
        try await prepare()

      case 13:
        let f = try PairingCodec.unpack(plain, type: 13, count: 1)
        guard prepared, let peer, let peerBytes, !receiptReceived else {
          throw PairingFailure.authentication
        }
        let hash = PairingCodec.hash(PairingCodec.proof(channel.hash, peerBytes, localBytes))
        try store.activate(peerID: peer.deviceId, hash: hash, receipt: f[0])
        receiptReceived = true
        await complete()

      case 14:
        _ = try PairingCodec.unpack(plain, type: 14, count: 0)
        throw PairingFailure.cancelled

      default:
        throw PairingFailure.malformed
      }
    }
  }

  func approve() async throws {
    guard proofVerified, !localApproved, let channel else { throw PairingFailure.authentication }
    localApproved = true
    await send(try channel.seal(PairingCodec.message(12)))
    try await prepare()
  }

  /// Writes durable pending trust record and exchanges signed storage receipt once both peers approve.
  private func prepare() async throws {
    guard localApproved, peerApproved, !prepared, let peer, let peerBytes, let channel else {
      return
    }
    prepared = true
    await event("saving", peer)
    let hash = PairingCodec.hash(PairingCodec.proof(channel.hash, peerBytes, localBytes))
    let op = generation
    try store.prepare(
      PeerTrustRecord(
        peer: peer, localFingerprint: local.fingerprint, method: method, pairedAt: Date(),
        transcriptHash: hash, active: false))
    // Signing can suspend the actor; cancellation or identity replacement invalidates its result.
    let signature = try await identity.sign(message: PairingCodec.receipt(hash, 2))
    guard op == generation, signature.identity == local else { throw PairingFailure.cancelled }
    await send(try channel.seal(PairingCodec.message(13, [signature.signature])))
    receiptSent = true
    await complete()
  }

  private func complete() async {
    if receiptSent && receiptReceived { await event("paired", peer) }
  }

  private func context() -> Data {
    PairingCodec.fields([
      Data("aniCe pin bootstrap v1".utf8), Data([method.rawValue]), rendezvous, clientNonce,
      serverNonce,
    ])
  }

  private func transcript() -> Data {
    PairingCodec.fields([
      Data("aniCe pairing v1".utf8), Data([method.rawValue]), rendezvous, clientNonce, serverNonce,
      clientPublic, serverPublic,
    ])
  }

  /// Aborts an individual candidate attempt while retaining the parent invitation.
  func abortAttempt() throws {
    generation += 1
    channel?.destroy()
    channel = nil
    ephemeral = nil
    bootstrap.resetBytes(in: 0..<bootstrap.count)
    bootstrap.removeAll()
    peer = nil
    peerBytes = nil
    proofVerified = false
    localApproved = false
    peerApproved = false
    prepared = false
    receiptSent = false
    receiptReceived = false
    stage = 0
    try store.discardPending()
    if attempts >= 5 { throw PairingFailure.authentication }
  }

  /// Notify the authenticated peer before discarding the channel needed to encrypt cancellation.
  func decline() async throws {
    defer { close() }
    guard proofVerified, let channel else { throw PairingFailure.authentication }
    await send(try channel.seal(PairingCodec.message(14)))
  }

  /// Clears retained secret buffers, drops key references and releases the PAKE handle.
  func close() {
    let secretSize = qr?.secret.count ?? 0
    qr?.secret.resetBytes(in: 0..<secretSize)
    qr = nil
    pin = nil
    generation += 1
    channel?.destroy()
    channel = nil
    ephemeral = nil
    bootstrap.resetBytes(in: 0..<bootstrap.count)
    bootstrap.removeAll()
    if let pake { _ = try? NativePake.call(6, [pake]) }
    pake = nil
    try? store.discardPending()
  }
}
