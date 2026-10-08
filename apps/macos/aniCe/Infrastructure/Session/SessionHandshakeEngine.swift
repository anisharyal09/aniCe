// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import Security

enum HandshakeStage: Sendable { case new, message2, message3, message4, complete, closed }

/// EDHOC method 0 / suite 5, isolated from transport and persistent trust mutations.
actor SessionHandshakeEngine {
  private let local: DeviceIdentity
  private let responder: Bool
  private let trusted: @Sendable () async throws -> [DeviceIdentity]
  private let currentIdentity: @Sendable () async throws -> DeviceIdentity
  private let signer: @Sendable (Data) async throws -> SignedIdentityPayload
  private let selectedPeer: DeviceIdentity?
  private var ephemeral: P256.KeyAgreement.PrivateKey?
  private let connectionId: Data
  private let now: @Sendable () -> TimeInterval
  private let started: TimeInterval
  private var generation = 0
  private var inFlight = false
  private(set) var stage: HandshakeStage = .new
  private var message1 = Data()
  private var prk = Data()
  private var th = Data()
  private var peer: DeviceIdentity?
  private var prkExporter = Data()

  init(
    local: DeviceIdentity, responder: Bool,
    trusted: @escaping @Sendable () async throws -> [DeviceIdentity],
    currentIdentity: @escaping @Sendable () async throws -> DeviceIdentity,
    signer: @escaping @Sendable (Data) async throws -> SignedIdentityPayload,
    selectedPeer: DeviceIdentity? = nil,
    ephemeral: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey(),
    connectionId: Data? = nil,
    now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  ) throws {
    try local.validate()
    if let selectedPeer {
      try selectedPeer.validate()
      guard selectedPeer.platform == (responder ? "android" : "macos") else {
        throw SessionFailure.state
      }
    }
    guard local.platform == (responder ? "macos" : "android"),
      responder || selectedPeer?.platform == "macos"
    else { throw SessionFailure.state }
    self.local = local
    self.responder = responder
    self.trusted = trusted
    self.currentIdentity = currentIdentity
    self.signer = signer
    self.selectedPeer = selectedPeer
    self.ephemeral = ephemeral
    self.now = now
    self.started = now()
    if let connectionId {
      guard connectionId.count == 8 else { throw SessionFailure.malformed }
      self.connectionId = connectionId
    } else {
      var bytes = Data(count: 8)
      let status = bytes.withUnsafeMutableBytes {
        SecRandomCopyBytes(kSecRandomDefault, 8, $0.baseAddress!)
      }
      guard status == errSecSuccess else { throw SessionFailure.authentication }
      self.connectionId = bytes
    }
  }
  private func same(_ a: DeviceIdentity, _ b: DeviceIdentity) -> Bool {
    a.deviceId == b.deviceId && a.fingerprint == b.fingerprint && a.publicKey == b.publicKey
  }
  private func ensure(_ op: Int) throws {
    guard generation == op, stage != .closed else { throw SessionFailure.cancelled }
  }
  private func check(_ op: Int) async throws {
    try ensure(op)
    guard stage == .complete || now() - started < 30 else { throw SessionFailure.expired }
    // Revalidate current identity and pinned trust even after handshake completion.
    let identity = try await currentIdentity()
    try ensure(op)
    guard same(identity, local) else { throw SessionFailure.cancelled }
    if let peer {
      let active = try await resolve(SessionCrypto.kid(peer), op)
      guard same(active, peer) else { throw SessionFailure.untrustedPeer }
    }
  }
  private func resolve(_ kid: Data, _ op: Int) async throws -> DeviceIdentity {
    let records = try await trusted()
    try ensure(op)
    let matches = try records.filter {
      try $0.platform == (responder ? "android" : "macos") && SessionCrypto.kid($0) == kid
    }
    guard matches.count == 1 else { throw SessionFailure.untrustedPeer }
    let result = matches[0]
    // Resolve against the complete active journal first so duplicate credentials cannot be hidden
    // by the UI selection. A selected responder target is checked only after identity decryption.
    if let selectedPeer {
      guard same(result, selectedPeer) else { throw SessionFailure.untrustedPeer }
    }
    return result
  }
  private func run<T>(_ expected: HandshakeStage, _ body: (Int) async throws -> T) async throws -> T
  {
    let op = generation
    do {
      guard stage != .closed else { throw SessionFailure.cancelled }
      guard !inFlight, stage == expected else { throw SessionFailure.state }
      inFlight = true
      try await check(op)
      let result = try await body(op)
      try ensure(op)
      inFlight = false
      return result
    } catch {
      close()
      throw error
    }
  }
  private func fields(_ data: Data, _ count: Int) throws -> [SessionCBOR] {
    let values = try SessionCbor.decodeSequence(data)
    guard values.count == count else { throw SessionFailure.malformed }
    return values
  }
  private func proof(_ input: Data, _ op: Int) async throws -> Data {
    // Protected signing may prompt or suspend; reject reset/cancelled results before use.
    let signed = try await signer(input)
    try ensure(op)
    guard same(signed.identity, local) else { throw SessionFailure.cancelled }
    try await check(op)
    let signature = try SessionSignature.derToCose(signed.signature)
    guard local.verify(message: input, signature: signed.signature) else {
      throw SessionFailure.authentication
    }
    return signature
  }
  private func verify(_ identity: DeviceIdentity, _ input: Data, _ signature: Data) throws {
    let der: Data
    do { der = try SessionSignature.coseToDer(signature) } catch SessionFailure.malformed {
      throw SessionFailure.authentication
    }
    guard identity.verify(message: input, signature: der) else {
      throw SessionFailure.authentication
    }
  }
  private func derive(_ label: Int64, _ context: Data, _ length: Int) throws -> Data {
    try SessionCrypto.kdf(prk, label, context, length)
  }
  private func crypt(_ data: Data, encrypt: Bool, final: Bool = false) throws -> Data {
    var key = try derive(final ? 8 : 3, th, 32)
    var iv = try derive(final ? 9 : 4, th, 12)
    defer {
      key.resetBytes(in: 0..<key.count)
      iv.resetBytes(in: 0..<iv.count)
    }
    return try SessionCrypto.aead(key, iv, th, data, encrypt: encrypt)
  }
  func initiate() async throws -> Data {
    try await run(.new) { op in
      guard !responder, let selectedPeer, let ephemeral else { throw SessionFailure.state }
      _ = try await resolve(SessionCrypto.kid(selectedPeer), op)
      message1 = try SessionCbor.sequence(
        .integer(0), .integer(5), .bytes(Data(ephemeral.publicKey.x963Representation[1..<33])),
        .bytes(connectionId))
      stage = .message2
      return message1
    }
  }
  func respond(_ message: Data) async throws -> Data {
    try await run(.new) { op in
      guard responder, let key = ephemeral else { throw SessionFailure.state }
      let f = try fields(message, 4)
      guard f[0] == .integer(0), f[1] == .integer(5) else {
        throw SessionFailure.unsupportedProfile
      }
      let gx = try f[2].bytes(32)
      _ = try f[3].bytes(8)
      message1 = message
      let gy = Data(key.publicKey.x963Representation[1..<33])
      th = try SessionCrypto.hash(
        SessionCbor.sequence(.bytes(gy), .bytes(SessionCrypto.hash(message1))))
      var z = try SessionCrypto.agree(key, gx)
      prk = SessionCrypto.extract(th, z)
      z.resetBytes(in: 0..<z.count)
      ephemeral = nil
      let context = try SessionCbor.sequence(
        .bytes(connectionId), SessionCrypto.idCredential(local), .bytes(th),
        SessionCrypto.credential(local))
      let signature = try await proof(
        SessionCrypto.signingInput(local, th, derive(2, context, 32)), op)
      let plaintext = try SessionCbor.sequence(
        .bytes(connectionId), .bytes(SessionCrypto.kid(local)), .bytes(signature))
      var stream = try derive(0, th, plaintext.count)
      // EDHOC message 2 uses its specified XOR keystream; AEAD starts with message 3.
      let ciphertext = Data(zip(plaintext, stream).map { $0 ^ $1 })
      stream.resetBytes(in: 0..<stream.count)
      th = try SessionCrypto.hash(
        SessionCbor.encode(.bytes(th)) + plaintext
          + SessionCbor.encode(SessionCrypto.credential(local)))
      stage = .message3
      return try SessionCbor.encode(.bytes(gy + ciphertext))
    }
  }
  func authenticateResponder(_ message: Data) async throws -> Data {
    try await run(.message2) { op in
      guard let key = ephemeral else { throw SessionFailure.state }
      let payload = try SessionCbor.decode(message).bytes(141)
      let gy = payload.subdata(in: 0..<32)
      th = try SessionCrypto.hash(
        SessionCbor.sequence(.bytes(gy), .bytes(SessionCrypto.hash(message1))))
      var z = try SessionCrypto.agree(key, gy)
      prk = SessionCrypto.extract(th, z)
      z.resetBytes(in: 0..<z.count)
      ephemeral = nil
      var stream = try derive(0, th, payload.count - 32)
      let plaintext = Data(zip(payload.dropFirst(32), stream).map { $0 ^ $1 })
      stream.resetBytes(in: 0..<stream.count)
      let f = try fields(plaintext, 3)
      let cr = try f[0].bytes(8)
      let identity = try await resolve(f[1].bytes(32), op)
      peer = identity
      let context = try SessionCbor.sequence(
        .bytes(cr), SessionCrypto.idCredential(identity), .bytes(th),
        SessionCrypto.credential(identity))
      try verify(
        identity, SessionCrypto.signingInput(identity, th, derive(2, context, 32)), f[2].bytes(64))
      th = try SessionCrypto.hash(
        SessionCbor.encode(.bytes(th)) + plaintext
          + SessionCbor.encode(SessionCrypto.credential(identity)))
      let context3 = try SessionCbor.sequence(
        SessionCrypto.idCredential(local), .bytes(th), SessionCrypto.credential(local))
      let signature = try await proof(
        SessionCrypto.signingInput(local, th, derive(6, context3, 32)), op)
      let p3 = try SessionCbor.sequence(.bytes(SessionCrypto.kid(local)), .bytes(signature))
      let message3 = try SessionCbor.encode(.bytes(crypt(p3, encrypt: true)))
      th = try SessionCrypto.hash(
        SessionCbor.encode(.bytes(th)) + p3 + SessionCbor.encode(SessionCrypto.credential(local)))
      stage = .message4
      return message3
    }
  }
  func authenticateInitiator(_ message: Data) async throws -> Data {
    try await run(.message3) { op in
      let plaintext = try crypt(SessionCbor.decode(message).bytes(116), encrypt: false)
      let f = try fields(plaintext, 2)
      let identity = try await resolve(f[0].bytes(32), op)
      peer = identity
      let context = try SessionCbor.sequence(
        SessionCrypto.idCredential(identity), .bytes(th), SessionCrypto.credential(identity))
      try verify(
        identity, SessionCrypto.signingInput(identity, th, derive(6, context, 32)), f[1].bytes(64))
      th = try SessionCrypto.hash(
        SessionCbor.encode(.bytes(th)) + plaintext
          + SessionCbor.encode(SessionCrypto.credential(identity)))
      try await check(op)
      let message4 = try SessionCbor.encode(.bytes(crypt(Data(), encrypt: true, final: true)))
      try complete()
      return message4
    }
  }
  func confirmResponder(_ message: Data) async throws {
    try await run(.message4) { op in
      let plaintext = try crypt(SessionCbor.decode(message).bytes(), encrypt: false, final: true)
      guard plaintext.isEmpty else { throw SessionFailure.malformed }
      try await check(op)
      try complete()
    }
  }
  private func complete() throws {
    var out = try derive(7, th, 32)
    defer { out.resetBytes(in: 0..<out.count) }
    prkExporter = try SessionCrypto.kdf(out, 10, Data(), 32)
    prk.resetBytes(in: 0..<prk.count)
    prk = Data()
    message1 = Data()
    stage = .complete
  }
  func export(context: Data, length: Int) async throws -> Data {
    try await run(.complete) { _ in try SessionCrypto.kdf(prkExporter, 32768, context, length) }
  }
  func authenticatedPeer() async throws -> DeviceIdentity {
    try await run(.complete) { _ in
      guard let peer else { throw SessionFailure.state }
      return peer
    }
  }
  // Canonical credentials are returned in wire-role order, independent of the local role.
  func bindings() async throws -> (Data, Data) {
    try await run(.complete) { _ in
      guard let peer else { throw SessionFailure.state }
      return (
        try SessionCbor.encode(SessionCrypto.credential(responder ? peer : local)),
        try SessionCbor.encode(SessionCrypto.credential(responder ? local : peer))
      )
    }
  }
  func receiveError(_ message: Data) throws {
    defer { close() }
    guard stage != .complete, stage != .closed else { throw SessionFailure.state }
    try SessionError.validate(message)
    throw SessionFailure.authentication
  }
  func checkDeadline() async throws {
    do { try await check(generation) } catch {
      close()
      throw error
    }
  }
  func close() {
    generation += 1
    stage = .closed
    inFlight = false
    ephemeral = nil
    peer = nil
    prk.resetBytes(in: 0..<prk.count)
    prkExporter.resetBytes(in: 0..<prkExporter.count)
    prk = Data()
    prkExporter = Data()
    th = Data()
    message1 = Data()
  }
  static func responder(
    identity: IdentityService, trust: PeerTrustStore, selectedPeer: DeviceIdentity? = nil
  ) async throws
    -> SessionHandshakeEngine
  {
    let local = try await identity.publicIdentity()
    return try SessionHandshakeEngine(
      local: local, responder: true,
      trusted: { trust.list(localFingerprint: local.fingerprint).map(\.peer) },
      currentIdentity: { try await identity.publicIdentity() },
      signer: { try await identity.sign(message: $0) }, selectedPeer: selectedPeer)
  }
}

enum SessionError {
  static func generic() throws -> Data {
    try SessionCbor.sequence(.integer(1), .text("Handshake failed"))
  }
  static func validate(_ message: Data) throws {
    let f = try SessionCbor.decodeSequence(message)
    guard f.count == 2 else { throw SessionFailure.malformed }
    switch (f[0], f[1]) {
    case (.integer(1), .text(let text)):
      guard text.utf8.count <= 64 else { throw SessionFailure.malformed }
    case (.integer(2), .integer(5)), (.integer(3), .bool(true)): break
    default: throw SessionFailure.malformed
    }
  }
}
