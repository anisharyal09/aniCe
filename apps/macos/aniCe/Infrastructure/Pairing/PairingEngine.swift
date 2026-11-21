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
  private let comparison: @Sendable (String) async -> Void
  private let isCurrent: @Sendable () -> Bool

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
  private var clientCommitment = Data()
  private var serverCommitment = Data()
  private var serverComparisonNonce = Data()
  private var localIdentitySalt = Data()
  private var clientIdentityCommitment = Data()
  private var serverIdentityCommitment = Data()
  private var localCompared = false
  private var peerCompared = false
  private var identitySent = false
  private var comparisonCode: String?

  init(
    method: PairingMethod, identity: IdentityService, store: PeerTrustStore,
    send: @escaping @Sendable (Data) async -> Void,
    event: @escaping @Sendable (String, DeviceIdentity?) async -> Void,
    comparison: @escaping @Sendable (String) async -> Void = { _ in },
    isCurrent: @escaping @Sendable () -> Bool = { true }
  ) async throws {
    self.method = method
    self.identity = identity
    self.store = store
    self.send = send
    self.event = event
    self.comparison = comparison
    self.isCurrent = isCurrent
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
    } else if method == .pin {
      qr = nil
      pin = try PairingCodec.pin()
      pake = try NativePake.call(1, [Data(pin!.utf8), rendezvous])
    } else {
      localIdentitySalt = try PairingCodec.random(32)
      serverIdentityCommitment = try PairingSas.identityCommitment(
        role: 2, salt: localIdentitySalt, identity: localBytes)
    }
  }

  func invitation() -> Data {
    PairingCodec.message(2, [Data([method.rawValue]), rendezvous, serverNonce])
  }

  func receive(_ data: Data) async throws {
    do { try await receiveMessage(data) }
    catch {
      if method == .sas { close() }
      throw error
    }
  }

  private func receiveMessage(_ data: Data) async throws {
    guard stage >= 0, method != .sas || isCurrent() else { throw PairingFailure.cancelled }
    if method == .sas && stage != 2 {
      try await receiveSasBootstrap(data)
      return
    }
    if method != .sas && data == PairingCodec.message(1) {
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
        if method == .sas {
          guard localCompared, peerCompared, identitySent else { throw PairingFailure.authentication }
        }
        let f = try PairingCodec.unpack(plain, type: 10, count: method == .sas ? 2 : 1)
        guard f[0].count <= 2048 else { throw PairingFailure.malformed }
        if method == .sas {
          let opened = try PairingSas.identityCommitment(role: 1, salt: f[1], identity: f[0])
          guard PairingCodec.equal(opened, clientIdentityCommitment) else {
            throw PairingFailure.authentication
          }
        }
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
        if method == .sas, !isCurrent() { throw PairingFailure.cancelled }
        await send(try channel.seal(PairingCodec.message(11, [signature.signature])))

      case 11:
        guard let peer, let peerBytes, !proofVerified else { throw PairingFailure.authentication }
        let f = try PairingCodec.unpack(plain, type: 11, count: 1)
        guard
          peer.verify(
            message: PairingCodec.proof(channel.hash, peerBytes, localBytes, 1), signature: f[0])
        else { throw PairingFailure.authentication }
        proofVerified = true
        if method == .sas {
          guard localCompared, peerCompared else { throw PairingFailure.authentication }
          try await approve()
        } else { await event("approval", peer) }

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
        if method == .sas, !isCurrent() { throw PairingFailure.cancelled }
        try store.activate(peerID: peer.deviceId, hash: hash, receipt: f[0])
        receiptReceived = true
        await complete()

      case 14:
        _ = try PairingCodec.unpack(plain, type: 14, count: 0)
        throw PairingFailure.cancelled

      case 15:
        _ = try PairingCodec.unpack(plain, type: 15, count: 0)
        guard method == .sas, comparisonCode != nil, !peerCompared, !identitySent else {
          throw PairingFailure.authentication
        }
        peerCompared = true
        try await discloseIdentity()

      default:
        throw PairingFailure.malformed
      }
    }
  }

  /// Both peers commit before comparison randomness is revealed; the channel is not trusted yet.
  private func receiveSasBootstrap(_ data: Data) async throws {
    if stage == 0, data == PairingCodec.message(1) {
      await send(invitation())
      return
    }
    if stage == 0 {
      let fields = try PairingCodec.unpack(data, type: 3, count: 3)
      guard attempts < 5, fields[0] == Data([3]), fields[1] == rendezvous, fields[2].count == 32
      else { throw PairingFailure.authentication }
      attempts += 1
      clientCommitment = fields[2]
      let key = P256.KeyAgreement.PrivateKey()
      ephemeral = key
      serverPublic = key.publicKey.x963Representation
      serverComparisonNonce = try PairingCodec.random(32)
      serverCommitment = try PairingSas.commitment(role: 2, rendezvous: rendezvous,
        serverNonce: serverNonce, publicKey: serverPublic, nonce: serverComparisonNonce,
        identityCommitment: serverIdentityCommitment)
      stage = 10
      await event("authenticating", nil)
      await send(PairingCodec.message(4, [serverNonce, serverCommitment]))
    } else if stage == 10 {
      let fields = try PairingCodec.unpack(data, type: 8, count: 3)
      clientPublic = fields[0]
      clientNonce = fields[1]
      clientIdentityCommitment = fields[2]
      let transcript = try sasTranscript()
      guard let ephemeral else { throw PairingFailure.authentication }
      let shared = try ephemeral.sharedSecretFromKeyAgreement(
        with: P256.KeyAgreement.PublicKey(x963Representation: clientPublic))
      var sharedBytes = shared.withUnsafeBytes { Data($0) }
      defer { sharedBytes.resetBytes(in: 0..<sharedBytes.count) }
      bootstrap = PairingSas.bootstrap(shared: sharedBytes, transcript: transcript)
      comparisonCode = try PairingSas.digits(key: bootstrap, transcript: transcript)
      self.ephemeral = nil
      stage = 11
      await send(PairingCodec.message(9, [serverPublic, serverComparisonNonce, serverIdentityCommitment]))
    } else if stage == 11 {
      let fields = try PairingCodec.unpack(data, type: 5, count: 1)
      let transcript = try sasTranscript()
      let hash = PairingCodec.hash(transcript)
      guard PairingCodec.equal(fields[0],
        PairingCodec.mac(PairingCodec.derive(bootstrap, "client-auth", hash), transcript))
      else { throw PairingFailure.authentication }
      let channel = PairingChannel(key: bootstrap, transcript: transcript, server: true)
      self.channel = channel
      bootstrap.resetBytes(in: 0..<bootstrap.count)
      bootstrap.removeAll()
      stage = 2
      await send(PairingCodec.message(6, [channel.confirm()]))
      guard let comparisonCode else { throw PairingFailure.authentication }
      await comparison(comparisonCode)
      await event("comparison", nil)
    } else { throw PairingFailure.authentication }
  }

  private func sasTranscript() throws -> Data {
    try PairingSas.transcript(rendezvous: rendezvous, serverNonce: serverNonce,
      clientCommitment: clientCommitment, serverCommitment: serverCommitment,
      clientPublic: clientPublic, serverPublic: serverPublic, clientNonce: clientNonce,
      serverComparisonNonce: serverComparisonNonce, clientIdentityCommitment: clientIdentityCommitment,
      serverIdentityCommitment: serverIdentityCommitment)
  }

  func confirmComparison() async throws {
    guard method == .sas, isCurrent(), stage == 2, comparisonCode != nil, !localCompared, let channel else {
      throw PairingFailure.authentication
    }
    let op = generation
    let current = try await identity.publicIdentity()
    guard op == generation, isCurrent(), current == local, stage == 2, !localCompared else {
      throw PairingFailure.cancelled
    }
    localCompared = true
    await send(try channel.seal(PairingCodec.message(15)))
    try await discloseIdentity()
  }

  private func discloseIdentity() async throws {
    guard localCompared, peerCompared, !identitySent, let channel else { return }
    let op = generation
    let current = try await identity.publicIdentity()
    guard op == generation, isCurrent(), current == local else { throw PairingFailure.cancelled }
    identitySent = true
    await event("verifying", nil)
    await send(try channel.seal(PairingCodec.message(10, [localBytes, localIdentitySalt])))
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
    if method == .sas, !isCurrent() { throw PairingFailure.cancelled }
    let hash = PairingCodec.hash(PairingCodec.proof(channel.hash, peerBytes, localBytes))
    let op = generation
    try store.prepare(
      PeerTrustRecord(
        peer: peer, localFingerprint: local.fingerprint, method: method, pairedAt: Date(),
        transcriptHash: hash, active: false))
    // Signing can suspend the actor; cancellation or identity replacement invalidates its result.
    let signature = try await identity.sign(message: PairingCodec.receipt(hash, 2))
    guard op == generation, signature.identity == local else { throw PairingFailure.cancelled }
    if method == .sas, !isCurrent() { throw PairingFailure.cancelled }
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
    // Nearby attempts never reuse comparison material or a previously displayed code.
    if method == .sas { close(); throw PairingFailure.cancelled }
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
    guard proofVerified || (method == .sas && comparisonCode != nil), let channel else {
      throw PairingFailure.authentication
    }
    await send(try channel.seal(PairingCodec.message(14)))
  }

  /// Clears retained secret buffers, drops key references and releases the PAKE handle.
  func close() {
    stage = -1
    comparisonCode = nil
    localCompared = false
    peerCompared = false
    localIdentitySalt.resetBytes(in: 0..<localIdentitySalt.count)
    localIdentitySalt.removeAll()
    serverComparisonNonce.resetBytes(in: 0..<serverComparisonNonce.count)
    serverComparisonNonce.removeAll()
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
