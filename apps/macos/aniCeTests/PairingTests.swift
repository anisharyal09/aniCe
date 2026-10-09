// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import XCTest

@testable import aniCe

final class PairingTests: XCTestCase, @unchecked Sendable {
  func vectors() throws -> [String: Any] {
    let url = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "pairing-vectors", withExtension: "json"))
    return try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  }
  func hex(_ root: [String: Any], _ name: String) throws -> Data {
    let s = try XCTUnwrap(root[name] as? String)
    return Data(
      stride(from: 0, to: s.count, by: 2).map {
        let a = s.index(s.startIndex, offsetBy: $0)
        return UInt8(s[a..<s.index(a, offsetBy: 2)], radix: 16)!
      })
  }
  func testSharedQRAndCryptoVectors() throws {
    let v = try vectors()
    XCTAssertEqual(v["fixtureVersion"] as? Int, 1)
    let text = try XCTUnwrap(v["qr"] as? String)
    let qr = try PairingQR.decode(text)
    XCTAssertEqual(qr.text, text)
    XCTAssertEqual(qr.rendezvous, try hex(v, "rendezvousHex"))
    XCTAssertEqual(qr.secret, try hex(v, "secretHex"))
    XCTAssertEqual(qr.fingerprint, try hex(v, "fingerprintHex"))
    XCTAssertEqual(PairingCodec.hash(try hex(v, "serverPublicHex")), qr.fingerprint)
    XCTAssertEqual(PairingCodec.hash(try hex(v, "transcriptHex")), try hex(v, "transcriptHashHex"))
    let clientKey = try P256.KeyAgreement.PrivateKey(
      rawRepresentation: Data(repeating: 0, count: 31) + Data([1]))
    let serverKey = try P256.KeyAgreement.PrivateKey(
      rawRepresentation: Data(repeating: 0, count: 31) + Data([2]))
    XCTAssertEqual(clientKey.publicKey.x963Representation, try hex(v, "clientPublicHex"))
    XCTAssertEqual(serverKey.publicKey.x963Representation, try hex(v, "serverPublicHex"))
    let nativeShared = try clientKey.sharedSecretFromKeyAgreement(with: serverKey.publicKey)
    XCTAssertEqual(nativeShared.withUnsafeBytes { Data($0) }, try hex(v, "sharedSecretHex"))
    let h = try hex(v, "transcriptHashHex")
    let k = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: try hex(v, "sharedSecretHex")), salt: qr.secret,
      info: PairingCodec.fields([Data("aniCe qr bootstrap v1".utf8), h]), outputByteCount: 32
    ).withUnsafeBytes { Data($0) }
    XCTAssertEqual(k, try hex(v, "bootstrapKeyHex"))
    XCTAssertEqual(
      PairingCodec.mac(PairingCodec.derive(k, "server-auth", h), try hex(v, "transcriptHex")),
      try hex(v, "serverMacHex"))
    XCTAssertEqual(
      PairingCodec.mac(PairingCodec.derive(k, "client-auth", h), try hex(v, "transcriptHex")),
      try hex(v, "clientMacHex"))
    let invalidQR = try XCTUnwrap(v["invalidQR"] as? [[String: String]])
    XCTAssertGreaterThanOrEqual(invalidQR.count, 3, "Negative QR fixture inventory was reduced")
    for bad in invalidQR {
      XCTAssertThrowsError(try PairingQR.decode(bad["text"]!))
    }
  }
  func testDirectionalEncryptionReplayAndTamper() throws {
    let v = try vectors()
    let key = try hex(v, "bootstrapKeyHex")
    let t = try hex(v, "transcriptHex")
    let c = PairingChannel(key: key, transcript: t, server: false)
    let s = PairingChannel(key: key, transcript: t, server: true)
    XCTAssertEqual(c.confirm(), try hex(v, "confirmationHex"))
    let wire = try c.seal(PairingCodec.message(12))
    XCTAssertEqual(wire, try hex(v, "encryptedApprovalHex"))
    XCTAssertEqual(try s.open(wire), PairingCodec.message(12))
    XCTAssertThrowsError(try s.open(wire))
    var bad = wire
    bad[bad.count - 1] ^= 1
    XCTAssertThrowsError(try PairingChannel(key: key, transcript: t, server: true).open(bad))
    XCTAssertThrowsError(
      try PairingChannel(key: Data(count: 32), transcript: t, server: true).open(wire))
  }
  func testFragmentationAndBounds() throws {
    for capacity in [20, 253, 514] {
      let data = Data((0..<2048).map { UInt8(truncatingIfNeeded: $0) })
      let frames = try PairingReassembler.fragments(data, id: 0, capacity: capacity)
      var r = PairingReassembler()
      for f in frames.dropLast() { XCTAssertNil(try r.receive(f)) }
      XCTAssertEqual(try r.receive(frames.last!), data)
      XCTAssertThrowsError(try r.receive(frames[0]))
    }
    var r = PairingReassembler()
    let frames = try PairingReassembler.fragments(Data(count: 40), id: 0, capacity: 20)
    XCTAssertThrowsError(try r.receive(frames[1]))
    XCTAssertThrowsError(try PairingCodec.parse(Data([0, 0, 0, 7])))
    for id in 0..<8 {
      for f in try PairingReassembler.fragments(Data(count: 4096), id: UInt64(id), capacity: 514) {
        _ = try r.receive(f)
      }
    }
    XCTAssertThrowsError(
      try r.receive(PairingReassembler.fragments(Data([1]), id: 8, capacity: 20)[0]))
  }
}

private final class PairingMemoryIdentity: IdentityStorage, @unchecked Sendable {
  var record: IdentityRecord?
  var keys: [String: P256.Signing.PrivateKey] = [:]
  var signatures = 0
  func loadRecord() throws -> IdentityRecord? { record }
  func saveRecord(_ record: IdentityRecord) throws { self.record = record }
  func keyTags() throws -> [String] { Array(keys.keys) }
  func key(tag: String) throws -> StoredPublicKey? {
    keys[tag].map {
      StoredPublicKey(bytes: $0.publicKey.x963Representation, protection: .keychainSoftware)
    }
  }
  func createKey(tag: String) throws -> StoredPublicKey {
    let k = P256.Signing.PrivateKey()
    keys[tag] = k
    return StoredPublicKey(bytes: k.publicKey.x963Representation, protection: .keychainSoftware)
  }
  func sign(tag: String, message: Data) throws -> Data {
    signatures += 1
    return try keys[tag]!.signature(for: message).derRepresentation
  }
  func deleteKey(tag: String) throws { keys.removeValue(forKey: tag) }
}
private actor PairingBus {
  var messages: [Data] = []
  var events: [String] = []
  func send(_ data: Data) { messages.append(data) }
  func event(_ name: String) { events.append(name) }
  func take() -> [Data] {
    let result = messages
    messages.removeAll()
    return result
  }
  func names() -> [String] { events }
}
extension PairingTests {
  func testNativePakeBridgeLeadingZeroAndContextBinding() throws {
    let id = Data(repeating: 7, count: 16)
    let server = try NativePake.call(1, [Data("000001".utf8), id])
    defer { _ = try? NativePake.call(6, [server]) }
    let client = try PairingCodec.parse(NativePake.call(2, [Data("000001".utf8)]))
    let context = Data("context".utf8)
    let response = try NativePake.call(3, [server, client[1], context])
    let finish = try PairingCodec.parse(
      NativePake.call(4, [client[0], Data("000001".utf8), response, context]))
    XCTAssertEqual(try NativePake.call(5, [server, finish[0]]), finish[1])
    let bad = try PairingCodec.parse(NativePake.call(2, [Data("000002".utf8)]))
    let reply = try NativePake.call(3, [server, bad[1], context])
    XCTAssertThrowsError(try NativePake.call(4, [bad[0], Data("000002".utf8), reply, context]))
    let changed = try PairingCodec.parse(NativePake.call(2, [Data("000001".utf8)]))
    let next = try NativePake.call(3, [server, changed[1], context])
    XCTAssertThrowsError(
      try NativePake.call(4, [changed[0], Data("000001".utf8), next, Data("changed".utf8)]))
  }
  func testFullQRPairingRequiresBothConsentAndSignedReceipt() async throws {
    try await fullPairing(.qr)
  }
  func testFullPINPairingRequiresBothConsentAndSignedReceipt() async throws {
    try await fullPairing(.pin)
  }
  func testQRDeclineSendsEncryptedCancellationWithoutTrust() async throws {
    try await fullPairing(.qr, decline: true)
  }
  func testPINDeclineSendsEncryptedCancellationWithoutTrust() async throws {
    try await fullPairing(.pin, decline: true)
  }
  private func fullPairing(_ method: PairingMethod, decline: Bool = false) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "anice-pairing-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try PeerTrustStore(url: directory.appendingPathComponent("trust.json"))
    let storage = PairingMemoryIdentity()
    let identity = IdentityService(storage: storage, deviceName: "Mac test", tagPrefix: "test.")
    let bus = PairingBus()
    let engine = try await PairingEngine(
      method: method, identity: identity, store: store, send: { await bus.send($0) },
      event: { name, _ in await bus.event(name) })
    let exportedQR = await engine.qr
    let code = await engine.pin
    let invitation = try PairingCodec.unpack(await engine.invitation(), type: 2, count: 3)
    let ck = P256.KeyAgreement.PrivateKey()
    let cn = Data(repeating: 3, count: 32)
    let pakeClient =
      method == .pin ? try PairingCodec.parse(NativePake.call(2, [Data(code!.utf8)])) : []
    let cp = method == .qr ? ck.publicKey.x963Representation : pakeClient[1]
    try await engine.receive(
      PairingCodec.message(3, [Data([method.rawValue]), invitation[1], cn, cp]))
    let helloMessages = await bus.take()
    let hello = try PairingCodec.unpack(try XCTUnwrap(helloMessages.first), type: 4, count: 3)
    let t = PairingCodec.fields([
      Data("aniCe pairing v1".utf8), Data([method.rawValue]), invitation[1], cn, invitation[2], cp,
      hello[1],
    ])
    let h = PairingCodec.hash(t)
    let k: Data
    let finish: Data
    if method == .qr {
      let shared = try ck.sharedSecretFromKeyAgreement(
        with: P256.KeyAgreement.PublicKey(x963Representation: hello[1]))
      k = shared.hkdfDerivedSymmetricKey(
        using: SHA256.self, salt: exportedQR!.secret,
        sharedInfo: PairingCodec.fields([Data("aniCe qr bootstrap v1".utf8), h]),
        outputByteCount: 32
      ).withUnsafeBytes { Data($0) }
      XCTAssertTrue(
        PairingCodec.equal(hello[2], PairingCodec.mac(PairingCodec.derive(k, "server-auth", h), t)))
      finish = PairingCodec.mac(PairingCodec.derive(k, "client-auth", h), t)
    } else {
      let context = PairingCodec.fields([
        Data("aniCe pin bootstrap v1".utf8), Data([2]), invitation[1], cn, invitation[2],
      ])
      let out = try PairingCodec.parse(
        NativePake.call(4, [pakeClient[0], Data(code!.utf8), hello[1], context]))
      finish = out[0]
      k = HKDF<SHA256>.deriveKey(
        inputKeyMaterial: SymmetricKey(data: out[1]), salt: h,
        info: Data("aniCe pin bootstrap v1".utf8), outputByteCount: 32
      ).withUnsafeBytes { Data($0) }
    }
    let client = PairingChannel(key: k, transcript: t, server: false)
    try await engine.receive(PairingCodec.message(5, [finish]))
    let initial = await bus.take()
    XCTAssertEqual(try PairingCodec.unpack(initial[0], type: 6, count: 1)[0], client.confirm())
    let serverBytes = try PairingCodec.unpack(client.open(initial[1]), type: 10, count: 1)[0]
    let mac = try DeviceIdentity.decode(serverBytes)
    let signing = P256.Signing.PrivateKey()
    let initialIdentity = try DeviceIdentity(
      deviceId: UUID().uuidString.lowercased(), deviceName: "Android test",
      publicKey: signing.publicKey.x963Representation)
    var json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: PairingCodec.identityBytes(initialIdentity))
        as? [String: Any])
    json["platform"] = "android"
    let clientBytes = try JSONSerialization.data(withJSONObject: json)
    let android = try DeviceIdentity.decode(clientBytes)
    try await engine.receive(client.seal(PairingCodec.message(10, [clientBytes])))
    let proofMessages = await bus.take()
    let serverSignature = try PairingCodec.unpack(
      client.open(proofMessages[0]), type: 11, count: 1)[0]
    XCTAssertTrue(
      mac.verify(
        message: PairingCodec.proof(h, clientBytes, serverBytes, 2), signature: serverSignature))
    let proof = try signing.signature(for: PairingCodec.proof(h, clientBytes, serverBytes, 1))
      .derRepresentation
    try await engine.receive(client.seal(PairingCodec.message(11, [proof])))
    XCTAssertTrue(store.list(localFingerprint: mac.fingerprint).isEmpty)
    try await engine.receive(client.seal(PairingCodec.message(12)))
    XCTAssertTrue(store.list(localFingerprint: mac.fingerprint).isEmpty)
    if decline {
      await bus.take().forEach { _ in XCTFail("Trust traffic sent before mutual approval") }
      try await engine.decline()
      let cancelled = await bus.take()
      XCTAssertEqual(cancelled.count, 1)
      XCTAssertEqual(try client.open(try XCTUnwrap(cancelled.first)), PairingCodec.message(14))
      let clearedQR = await engine.qr
      let clearedPIN = await engine.pin
      XCTAssertNil(clearedQR)
      XCTAssertNil(clearedPIN)
      XCTAssertTrue(store.list(localFingerprint: mac.fingerprint).isEmpty)
      let reopened = try PeerTrustStore(url: directory.appendingPathComponent("trust.json"))
      XCTAssertTrue(reopened.list(localFingerprint: mac.fingerprint).isEmpty)
      do {
        try await engine.approve()
        XCTFail("Declined channel still accepted approval")
      } catch {}
      return
    }
    try await engine.approve()
    let receipts = await bus.take()
    XCTAssertEqual(receipts.count, 2)
    XCTAssertEqual(try client.open(receipts[0]), PairingCodec.message(12))
    let hash = PairingCodec.hash(PairingCodec.proof(h, clientBytes, serverBytes))
    let macReceipt = try PairingCodec.unpack(client.open(receipts[1]), type: 13, count: 1)[0]
    XCTAssertTrue(mac.verify(message: PairingCodec.receipt(hash, 2), signature: macReceipt))
    XCTAssertTrue(store.list(localFingerprint: mac.fingerprint).isEmpty)
    let receipt = try signing.signature(for: PairingCodec.receipt(hash, 1)).derRepresentation
    try await engine.receive(client.seal(PairingCodec.message(13, [receipt])))
    XCTAssertEqual(store.list(localFingerprint: mac.fingerprint).map(\.peer), [android])
    let names = await bus.names()
    XCTAssertTrue(names.contains("paired"))
    await engine.close()
    let reopened = try PeerTrustStore(url: directory.appendingPathComponent("trust.json"))
    XCTAssertEqual(reopened.list(localFingerprint: mac.fingerprint).count, 1)
    XCTAssertTrue(reopened.list(localFingerprint: "changed").isEmpty)
    try reopened.remove(android.deviceId)
    XCTAssertTrue(reopened.list(localFingerprint: mac.fingerprint).isEmpty)
    // Creation, proof and receipt each sign once. Public access causes no extra signature.
    XCTAssertEqual(storage.signatures, 3)
  }
}

@MainActor private final class PairingRadioFake: PairingPeripheralAdapter {
  var pairingWrite: ((Data) -> Bool)?
  var pairingDisconnect: (() -> Void)?
  var output: [Data] = []
  var events: ((PeripheralEvent) -> Void)?
  var holdDrain = false
  var draining = false
  func begin(
    event: @escaping (PeripheralEvent) -> Void, read: @escaping (Bool, Int) -> DiscoveryRead
  ) {
    events = event
    event(.available)
  }
  func publish() { events?(.published) }
  func advertise() { events?(.advertising) }
  func stop() { events = nil }
  func sendPairing(_ message: Data) throws { output.append(message) }
  func drainPairing() async {
    draining = true
    while holdDrain { try? await Task.sleep(for: .milliseconds(10)) }
  }
  func retirePairingConnection() { output.removeAll() }
}

extension PairingTests {
  @MainActor func testMacDeclineWaitsForTransportThenStopsAndAllowsFreshInvitation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "anice-decline-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try PeerTrustStore(url: directory.appendingPathComponent("trust.json"))
    let identity = IdentityService(
      storage: PairingMemoryIdentity(), deviceName: "Mac test", tagPrefix: "test.")
    let radio = PairingRadioFake()
    let model = MacPairingModel(
      identity: identity, discovery: MacDiscoveryModel(adapter: radio), makeStore: { store })
    defer {
      radio.holdDrain = false
      model.cancel()
    }
    model.start(.qr)
    try await waitFor { model.phase == "starting" || model.phase == "invitation" }
    model.tick()
    let qr = try PairingQR.decode(try XCTUnwrap(model.qrText))
    XCTAssertTrue(radio.pairingWrite?(PairingCodec.message(1)) == true)
    try await waitFor { radio.output.count == 1 }
    let invitation = try PairingCodec.unpack(radio.output.removeFirst(), type: 2, count: 3)
    let key = P256.KeyAgreement.PrivateKey()
    let nonce = Data(repeating: 3, count: 32)
    let publicKey = key.publicKey.x963Representation
    XCTAssertTrue(
      radio.pairingWrite?(PairingCodec.message(3, [Data([1]), qr.rendezvous, nonce, publicKey]))
        == true)
    try await waitFor { radio.output.count == 1 }
    let hello = try PairingCodec.unpack(radio.output.removeFirst(), type: 4, count: 3)
    let transcript = PairingCodec.fields([
      Data("aniCe pairing v1".utf8), Data([1]), qr.rendezvous, nonce, invitation[2], publicKey,
      hello[1],
    ])
    let hash = PairingCodec.hash(transcript)
    let shared = try key.sharedSecretFromKeyAgreement(
      with: P256.KeyAgreement.PublicKey(x963Representation: hello[1]))
    let bootstrap = shared.hkdfDerivedSymmetricKey(
      using: SHA256.self, salt: qr.secret,
      sharedInfo: PairingCodec.fields([Data("aniCe qr bootstrap v1".utf8), hash]),
      outputByteCount: 32
    ).withUnsafeBytes { Data($0) }
    let channel = PairingChannel(key: bootstrap, transcript: transcript, server: false)
    XCTAssertTrue(
      radio.pairingWrite?(
        PairingCodec.message(
          5, [PairingCodec.mac(PairingCodec.derive(bootstrap, "client-auth", hash), transcript)]))
        == true)
    try await waitFor { radio.output.count == 2 }
    XCTAssertEqual(
      try PairingCodec.unpack(radio.output.removeFirst(), type: 6, count: 1)[0], channel.confirm())
    let macBytes = try PairingCodec.unpack(
      channel.open(radio.output.removeFirst()), type: 10, count: 1)[0]
    let signing = P256.Signing.PrivateKey()
    let android = try DeviceIdentity(
      deviceId: UUID().uuidString.lowercased(), deviceName: "Android test",
      publicKey: signing.publicKey.x963Representation)
    var json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: PairingCodec.identityBytes(android)) as? [String: Any])
    json["platform"] = "android"
    let androidBytes = try JSONSerialization.data(withJSONObject: json)
    XCTAssertTrue(
      radio.pairingWrite?(try channel.seal(PairingCodec.message(10, [androidBytes]))) == true)
    try await waitFor { radio.output.count == 1 }
    _ = try channel.open(radio.output.removeFirst())
    let proof = try signing.signature(for: PairingCodec.proof(hash, androidBytes, macBytes, 1))
      .derRepresentation
    XCTAssertTrue(radio.pairingWrite?(try channel.seal(PairingCodec.message(11, [proof]))) == true)
    try await waitFor { model.phase == "approval" }
    radio.holdDrain = true
    model.decline()
    try await waitFor { radio.draining }
    XCTAssertEqual(model.phase, "cancelling")
    model.tick()
    XCTAssertEqual(model.remaining, 0)
    radio.pairingDisconnect?()
    XCTAssertEqual(model.phase, "cancelling")
    XCTAssertEqual(try channel.open(try XCTUnwrap(radio.output.first)), PairingCodec.message(14))
    radio.holdDrain = false
    try await waitFor { !model.active }
    XCTAssertEqual(model.phase, "idle")
    XCTAssertNil(model.qrText)
    XCTAssertNil(radio.pairingWrite)
    let mac = try DeviceIdentity.decode(macBytes)
    XCTAssertTrue(store.list(localFingerprint: mac.fingerprint).isEmpty)
    model.start(.qr)
    try await waitFor { model.phase == "starting" || model.phase == "invitation" }
    XCTAssertNotEqual(model.qrText, qr.text)
  }

  @MainActor private func waitFor(_ check: () -> Bool) async throws {
    for _ in 0..<100 {
      if check() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Expected pairing state did not arrive")
  }
  @MainActor func testInvitationSurvivesBadMessageAndFourAuthenticationFailuresThenExpires()
    async throws
  {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "anice-invitation-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try PeerTrustStore(url: directory.appendingPathComponent("trust.json"))
    let storage = PairingMemoryIdentity()
    let identity = IdentityService(storage: storage, deviceName: "Mac test", tagPrefix: "test.")
    let radio = PairingRadioFake()
    var now: TimeInterval = 0
    let discovery = MacDiscoveryModel(adapter: radio, now: { now })
    let model = MacPairingModel(identity: identity, discovery: discovery, makeStore: { store })
    defer { model.cancel() }
    model.start(.qr)
    try await waitFor { model.phase == "starting" || model.phase == "invitation" }
    model.tick()
    let invitation = try XCTUnwrap(model.qrText)
    let qr = try PairingQR.decode(invitation)
    XCTAssertEqual(model.phase, "invitation")
    XCTAssertTrue(radio.pairingWrite?(Data([99])) == true)
    try await waitFor { model.status.contains("did not authenticate") }
    XCTAssertTrue(model.active)
    XCTAssertEqual(model.qrText, invitation)
    XCTAssertEqual(model.remaining, 120)
    let key = P256.KeyAgreement.PrivateKey()
    for attempt in 1...5 {
      XCTAssertTrue(
        radio.pairingWrite?(
          PairingCodec.message(
            3, [Data([1]), qr.rendezvous, Data(count: 32), key.publicKey.x963Representation]))
          == true)
      try await waitFor { model.phase == "authenticating" }
      XCTAssertTrue(radio.pairingWrite?(PairingCodec.message(5, [Data(count: 32)])) == true)
      try await waitFor { model.phase == "invitation" || model.phase == "failed" }
      XCTAssertEqual(model.active, attempt < 5)
      if attempt < 5 { XCTAssertEqual(model.qrText, invitation) }
    }
    XCTAssertNil(model.qrImage)
    XCTAssertEqual(model.remaining, 0)
    model.start(.qr)
    try await waitFor { model.phase == "starting" || model.phase == "invitation" }
    model.tick()
    now = 120
    model.tick()
    XCTAssertFalse(model.active)
    XCTAssertNil(model.qrText)
    XCTAssertNil(model.qrImage)
    XCTAssertTrue(model.status.contains("expired"))
  }
  func testEmptyNativeCallFailsWithoutCrash() {
    XCTAssertThrowsError(try NativePake.call(1, []))
  }
  func testRenamePreservesIdentityKeyAndPersists() async throws {
    let memory = PairingMemoryIdentity()
    let service = IdentityService(storage: memory, deviceName: "Original", tagPrefix: "test.")
    let original = try await service.publicIdentity()
    let signs = memory.signatures
    let renamed = try await service.rename("  My MacBook  ").identity
    XCTAssertEqual(renamed.deviceName, "My MacBook")
    XCTAssertEqual(renamed.deviceId, original.deviceId)
    XCTAssertEqual(renamed.publicKey, original.publicKey)
    XCTAssertEqual(renamed.fingerprint, original.fingerprint)
    XCTAssertEqual(memory.signatures, signs)
    let reopened = IdentityService(storage: memory, deviceName: "System", tagPrefix: "test.")
    let loaded = try await reopened.publicIdentity()
    XCTAssertEqual(loaded, renamed)
    do {
      _ = try await service.rename(" ")
      XCTFail("Empty name accepted")
    } catch {}
  }
  func testCorruptTrustRequiresExplicitRecoveryAndPreservesFile() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "anice-corruption-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("trust.json")
    let corrupt = Data("invalid json".utf8)
    try corrupt.write(to: file)
    XCTAssertThrowsError(try PeerTrustStore(url: file)) { XCTAssertTrue($0 is TrustStoreLoadError) }
    XCTAssertEqual(try Data(contentsOf: file), corrupt)
    let restored = try PeerTrustStore.recover(url: file)
    XCTAssertTrue(restored.list(localFingerprint: "anything").isEmpty)
    let backups = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.contains("quarantined") }
    XCTAssertEqual(backups.count, 1)
    XCTAssertEqual(try Data(contentsOf: backups[0]), corrupt)
  }
  func testWriteFailureRollsBackInMemoryState() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "anice-rollback-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: directory.path)
      try? FileManager.default.removeItem(at: directory)
    }
    let file = directory.appendingPathComponent("trust.json")
    let store = try PeerTrustStore(url: file)

    let key = P256.Signing.PrivateKey()
    let localFp = "local-fingerprint-test"
    let peerId = UUID().uuidString.lowercased()
    let peer = try DeviceIdentity(
      deviceId: peerId, deviceName: "Peer", publicKey: key.publicKey.x963Representation)
    let hash = Data(repeating: 0xaa, count: 32)
    let receipt = try key.signature(for: PairingCodec.receipt(hash, 2)).derRepresentation
    let record = PeerTrustRecord(
      peer: peer, localFingerprint: localFp, method: .qr,
      pairedAt: Date(), transcriptHash: hash, receipt: nil, active: false)

    try store.prepare(record)
    try store.activate(peerID: peerId, hash: hash, receipt: receipt)
    XCTAssertEqual(store.list(localFingerprint: localFp).count, 1)

    // Revoke write permission on directory so temp file creation fails
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)

    // Attempting to remove peer when writing fails must throw and rollback in-memory state
    XCTAssertThrowsError(try store.remove(peerId))
    XCTAssertEqual(store.list(localFingerprint: localFp).count, 1)
    XCTAssertEqual(store.list(localFingerprint: localFp).first?.peer.deviceId, peerId)

    // Restore write permissions
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
    try store.remove(peerId)
    XCTAssertTrue(store.list(localFingerprint: localFp).isEmpty)
  }
  func testRepairingAtCapacityReplacesExistingPeerAndRejectsNewPeer() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "anice-capacity-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("trust.json")
    var store = try PeerTrustStore(url: file)

    let key = P256.Signing.PrivateKey()
    let localFp = "local-fingerprint-test"

    let peer0Id = UUID().uuidString.lowercased()
    for i in 0..<128 {
      let id = i == 0 ? peer0Id : UUID().uuidString.lowercased()
      let peer = try DeviceIdentity(
        deviceId: id, deviceName: "Peer \(i)", publicKey: key.publicKey.x963Representation)
      let hash = Data((0..<32).map { UInt8(($0 + i) & 0xff) })
      let receipt = try key.signature(for: PairingCodec.receipt(hash, 2)).derRepresentation
      try store.prepare(
        PeerTrustRecord(
          peer: peer, localFingerprint: localFp, method: .qr,
          pairedAt: Date(timeIntervalSince1970: 1000 + Double(i)),
          transcriptHash: hash, receipt: nil, active: false))
      try store.activate(peerID: id, hash: hash, receipt: receipt)
    }
    XCTAssertEqual(store.list(localFingerprint: localFp).count, 128)

    // Attempting to add a 129th new peer is rejected
    let newPeerId = UUID().uuidString.lowercased()
    let newPeer = try DeviceIdentity(
      deviceId: newPeerId, deviceName: "Peer 129", publicKey: key.publicKey.x963Representation)
    let newHash = Data(count: 32)
    XCTAssertThrowsError(
      try store.prepare(
        PeerTrustRecord(
          peer: newPeer, localFingerprint: localFp, method: .qr,
          pairedAt: Date(timeIntervalSince1970: 2000),
          transcriptHash: newHash, receipt: nil, active: false)))

    // Re-pairing existing peer0 succeeds at capacity
    let updatedPeer0 = try DeviceIdentity(
      deviceId: peer0Id, deviceName: "Peer 0 Renamed", publicKey: key.publicKey.x963Representation)
    let updatedHash = Data(repeating: 0xee, count: 32)
    let updatedReceipt = try key.signature(for: PairingCodec.receipt(updatedHash, 2))
      .derRepresentation
    let pending = PeerTrustRecord(
      peer: updatedPeer0, localFingerprint: localFp, method: .qr,
      pairedAt: Date(timeIntervalSince1970: 3000),
      transcriptHash: updatedHash, receipt: nil, active: false)
    let original = try XCTUnwrap(
      store.list(localFingerprint: localFp).first { $0.peer.deviceId == peer0Id })
    let changedKey = P256.Signing.PrivateKey()
    let changedPeer = try DeviceIdentity(
      deviceId: peer0Id, deviceName: "Changed key",
      publicKey: changedKey.publicKey.x963Representation)
    XCTAssertThrowsError(
      try store.prepare(
        PeerTrustRecord(
          peer: changedPeer, localFingerprint: localFp, method: .qr,
          pairedAt: Date(), transcriptHash: updatedHash, receipt: nil, active: false)))
    try store.prepare(pending)
    XCTAssertEqual(
      store.list(localFingerprint: localFp).first { $0.peer.deviceId == peer0Id }?.peer,
      original.peer)
    // Restart before receipt exchange must discard the extra pending row, retaining active trust.
    store = try PeerTrustStore(url: file)
    XCTAssertEqual(store.list(localFingerprint: localFp).count, 128)
    XCTAssertEqual(
      store.list(localFingerprint: localFp).first { $0.peer.deviceId == peer0Id }?.transcriptHash,
      original.transcriptHash)
    try store.prepare(pending)
    try store.discardPending()
    XCTAssertEqual(
      store.list(localFingerprint: localFp).first { $0.peer.deviceId == peer0Id }?.peer,
      original.peer)
    try store.prepare(pending)
    XCTAssertThrowsError(try store.activate(peerID: peer0Id, hash: updatedHash, receipt: Data([1])))
    XCTAssertEqual(
      store.list(localFingerprint: localFp).first { $0.peer.deviceId == peer0Id }?.peer,
      original.peer)
    try store.activate(peerID: peer0Id, hash: updatedHash, receipt: updatedReceipt)

    XCTAssertEqual(store.list(localFingerprint: localFp).count, 128)
    let reloaded = try PeerTrustStore(url: file)
    XCTAssertEqual(reloaded.list(localFingerprint: localFp).count, 128)
    let peer0Record = try XCTUnwrap(
      reloaded.list(localFingerprint: localFp).first { $0.peer.deviceId == peer0Id })
    XCTAssertEqual(peer0Record.transcriptHash, updatedHash)
    XCTAssertEqual(peer0Record.peer.deviceName, "Peer 0 Renamed")
  }
}

extension PairingTests {
  @MainActor func testPublicGattProfileIsStableAcrossDiscoveryAndPairingWindows() throws {
    for _ in 0..<4 {
      let service = CoreBluetoothPeripheralAdapter.makeProfile()
      XCTAssertEqual(service.uuid.uuidString, BlePayloadCodec.serviceUUID)
      XCTAssertTrue(service.isPrimary)
      let characteristics = try XCTUnwrap(service.characteristics)
      XCTAssertEqual(
        characteristics.map(\.uuid.uuidString),
        [BlePayloadCodec.characteristicUUID, PairingCodec.writeUUID, PairingCodec.indicateUUID])
      XCTAssertEqual(characteristics.map(\.properties), [.read, .write, .indicate])
      XCTAssertTrue(characteristics.allSatisfy { $0.value == nil })
    }
  }
  func testLateAdvertisingCallbackCannotConfirmANewWindow() {
    var gate = AdvertisingGate()
    gate.begin()
    gate.request()
    XCTAssertTrue(gate.takeRequest())
    gate.stop()
    gate.begin()
    gate.request()
    XCTAssertFalse(gate.takeRequest())  // wait for retired operation's callback
    XCTAssertFalse(gate.complete())
    XCTAssertFalse(gate.isConfirmed)
    XCTAssertTrue(gate.takeRequest())
    XCTAssertTrue(gate.complete())
    XCTAssertTrue(gate.isConfirmed)
    XCTAssertFalse(gate.takeRequest())  // duplicate Start is idempotent
    gate.stop()
    XCTAssertFalse(gate.isConfirmed)
    gate.begin()
    gate.request()
    XCTAssertTrue(gate.takeRequest())
    gate.resetRadio()
    XCTAssertFalse(gate.complete())
    XCTAssertFalse(gate.isConfirmed)
  }
}

@MainActor private final class SessionRadioFake: SessionPeripheralAdapter {
  var pairingWrite: ((Data) -> Bool)?
  var pairingDisconnect: (() -> Void)?
  var sessionWrite: ((Data) -> Bool)?
  var sessionDisconnect: (() -> Void)?
  var sessionAdmitted: (() -> Bool)?
  var event: ((PeripheralEvent) -> Void)?
  var started = false
  var resumes = 0
  var stopped = 0
  var retirement = 0
  func begin(
    event: @escaping (PeripheralEvent) -> Void, read: @escaping (Bool, Int) -> DiscoveryRead
  ) {
    self.event = event
    started = true
    event(.available)
  }
  func publish() { event?(.published) }
  func advertise() { event?(.advertising) }
  func stop() {
    stopped += 1
    event = nil
  }
  func sendPairing(_ message: Data) throws { throw PairingFailure.transport }
  func drainPairing() async {}
  func retirePairingConnection() { retirement += 1 }
  func sessionCapacity(_ bytes: Int) -> Bool { true }
  var sent: [Data] = []
  var failReadyAck = false
  func sendSession(_ message: Data) async throws {
    if failReadyAck, message.first == 6 { throw SessionFailure.authentication }
    sent.append(message)
  }
  func resumeSessionAdvertising() { resumes += 1 }
  func tickSessionTransport() throws {}
}
@MainActor private final class SessionRecoveryWait {
  var delays = [TimeInterval]()
  var continuation: CheckedContinuation<Void, Never>?
  func pause(_ delay: TimeInterval) async {
    delays.append(delay)
    await withCheckedContinuation { continuation = $0 }
  }
  func release() { continuation?.resume(); continuation = nil }
}
@MainActor final class SessionLifecycleTests: XCTestCase {
  func testLatePairingCleanupRespectsDiscoveryPairingAndStop() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("trust.json")
    let trust = try PeerTrustStore(url: url), memory = PairingMemoryIdentity()
    let service = IdentityService(storage: memory, deviceName: "Mac test", tagPrefix: "radio.test.")
    _ = try await service.publicIdentity()
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let savedIdentity = try encoder.encode(memory.record), savedTrust = try Data(contentsOf: url)
    let radio = SessionRadioFake(), discovery = MacDiscoveryModel(adapter: radio)
    let pairing = MacPairingModel(identity: service, discovery: discovery, makeStore: { trust })
    let session = MacSessionModel(identity: service, adapter: radio, store: { trust })
    AniCeApp.configureSessionLifecycle(session: session, pairing: pairing, discovery: discovery)
    defer {
      session.quit(); pairing.cancel(); discovery.stop()
      session.beforeAllow = {}; pairing.beforePairing = {}; pairing.trustRemoved = {}; discovery.beforeStart = {}
    }
    session.setAutomatic(true)
    pairing.start(.qr)
    let lateCleanup = pairing.afterPairing
    lateCleanup()
    XCTAssertTrue(pairing.active); XCTAssertFalse(session.allowing)
    pairing.cancel()
    discovery.start()
    XCTAssertTrue(discovery.session.active)
    let stopped = radio.stopped
    lateCleanup() // Deliver the old completion after discovery has acquired the shared radio.
    XCTAssertTrue(discovery.session.active); XCTAssertFalse(session.allowing)
    XCTAssertEqual(radio.stopped, stopped)
    discovery.stop()
    lateCleanup() // Positive control: idle radio still restores enabled automatic availability.
    XCTAssertTrue(session.allowing)
    session.disconnect()
    lateCleanup()
    XCTAssertFalse(session.allowing); XCTAssertFalse(session.automatic)
    XCTAssertEqual(try Data(contentsOf: url), savedTrust)
    XCTAssertEqual(try encoder.encode(memory.record), savedIdentity)
  }

  func testProductionModelReadinessAndAuthenticatedPeerFeedback() async throws {
    try await exerciseProductionModel(failReadyAck: false)
  }
  func testProductionModelReadinessFailurePreservesIdentityAndTrust() async throws {
    try await exerciseProductionModel(failReadyAck: true)
  }
  private func exerciseProductionModel(failReadyAck: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("trust.json")
    let trust = try PeerTrustStore(url: url)
    let memory = PairingMemoryIdentity()
    let service = IdentityService(
      storage: memory, deviceName: "Mac test", tagPrefix: "session.test.")
    let mac = try await service.publicIdentity()
    let key = P256.Signing.PrivateKey()
    let android = try DeviceIdentity.decode(
      JSONSerialization.data(withJSONObject: [
        "identitySchemaVersion": 1, "algorithm": "ECDSA_P256_SHA256", "platform": "android",
        "deviceId": UUID().uuidString.lowercased(), "deviceName": "Phone test",
        "publicKey": key.publicKey.x963Representation.base64EncodedString(),
        "fingerprint": DeviceIdentity.fingerprint(key.publicKey.x963Representation),
      ]))
    let hash = Data(repeating: 7, count: 32)
    try trust.prepare(
      PeerTrustRecord(
        peer: android, localFingerprint: mac.fingerprint,
        method: .qr, pairedAt: Date(), transcriptHash: hash, active: false))
    try trust.activate(
      peerID: android.deviceId, hash: hash,
      receipt: key.signature(for: PairingCodec.receipt(hash, 1)).derRepresentation)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let savedIdentity = try encoder.encode(memory.record)
    let savedTrust = try Data(contentsOf: url)
    let radio = SessionRadioFake()
    radio.failReadyAck = failReadyAck
    let model = MacSessionModel(identity: service, adapter: radio, store: { trust })
    defer { model.cancel() }
    model.allow()
    try await waitFor { radio.started }
    XCTAssertTrue(radio.sessionAdmitted?() ?? false)
    XCTAssertFalse(radio.sessionAdmitted?() ?? true)
    let client = try SessionHandshakeEngine(
      local: android, responder: false,
      trusted: { [mac] }, currentIdentity: { android },
      signer: {
        SignedIdentityPayload(
          identity: android, signature: try key.signature(for: $0).derRepresentation)
      }, selectedPeer: mac)
    let message1 = try await client.initiate()
    XCTAssertTrue(radio.sessionWrite?(try SessionEnvelope.encode(1, message1)) ?? false)
    try await waitFor { !radio.sent.isEmpty }
    let message2 = try SessionEnvelope.decode(radio.sent.removeFirst())
    XCTAssertEqual(message2.0, 2)
    let message3 = try await client.authenticateResponder(message2.1)
    XCTAssertTrue(radio.sessionWrite?(try SessionEnvelope.encode(3, message3)) ?? false)
    try await waitFor { !radio.sent.isEmpty }
    let message4 = try SessionEnvelope.decode(radio.sent.removeFirst())
    XCTAssertEqual(message4.0, 4)
    try await client.confirmResponder(message4.1)
    XCTAssertEqual(model.state, "Connecting")
    XCTAssertEqual(model.receivedChecks, 0)
    let records = PairingBus()
    let channel = try await SecureSession.fromHandshake(
      client, responder: false,
      capacity: { _ in true }, submit: { await records.send($0) })
    try await channel.send(.ready)
    let readyRecords = await records.take()
    let ready = try XCTUnwrap(readyRecords.first)
    XCTAssertTrue(radio.sessionWrite?(try SessionEnvelope.encode(6, ready)) ?? false)
    if failReadyAck {
      try await waitFor { model.state == "Failed" }
      XCTAssertTrue(radio.sent.isEmpty)
      XCTAssertEqual(model.receivedChecks, 0)
      let stage = await channel.stage
      XCTAssertEqual(stage, .readySent)
    } else {
      try await waitFor { model.state == "Secured" }
      XCTAssertTrue(model.status.contains(android.deviceName))
      let ack = try SessionEnvelope.decode(try XCTUnwrap(radio.sent.first))
      XCTAssertEqual(ack.0, 6)
      _ = try await channel.receive(ack.1)
      try await channel.send(.data, plaintext: Data("aniCe connection check".utf8))
      let dataRecords = await records.take()
      let data = try XCTUnwrap(dataRecords.first)
      XCTAssertTrue(radio.sessionWrite?(try SessionEnvelope.encode(6, data)) ?? false)
      try await waitFor { model.receivedChecks == 1 }
      model.checkConnection()
      try await waitFor { radio.sent.count == 2 }
      let response = try SessionEnvelope.decode(radio.sent[1])
      let received = try await channel.receive(response.1)
      XCTAssertEqual(received.0, .data)
      XCTAssertEqual(received.1, Data("aniCe connection check".utf8))
    }
    XCTAssertEqual(try encoder.encode(memory.record), savedIdentity)
    XCTAssertEqual(try Data(contentsOf: url), savedTrust)
    await channel.close()
    await client.close()
  }
  private func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0..<2000 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    XCTFail("Production model transition did not complete")
    throw SessionFailure.expired
  }
  func testAutomaticAdmissionCooldownPauseSleepAndTrustBinding() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("trust.json")
    let trust = try PeerTrustStore(url: url)
    let memory = PairingMemoryIdentity()
    let service = IdentityService(storage: memory, deviceName: "Mac test", tagPrefix: "auto.test.")
    let mac = try await service.publicIdentity(), key = P256.Signing.PrivateKey()
    let android = try DeviceIdentity.decode(JSONSerialization.data(withJSONObject: [
      "identitySchemaVersion": 1, "algorithm": "ECDSA_P256_SHA256", "platform": "android",
      "deviceId": UUID().uuidString.lowercased(), "deviceName": "Phone test",
      "publicKey": key.publicKey.x963Representation.base64EncodedString(),
      "fingerprint": DeviceIdentity.fingerprint(key.publicKey.x963Representation),
    ]))
    let hash = Data(repeating: 9, count: 32)
    try trust.prepare(PeerTrustRecord(peer: android, localFingerprint: mac.fingerprint,
      method: .qr, pairedAt: Date(), transcriptHash: hash, active: false))
    try trust.activate(peerID: android.deviceId, hash: hash,
      receipt: key.signature(for: PairingCodec.receipt(hash, 1)).derRepresentation)
    let savedTrust = try Data(contentsOf: url)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let savedIdentity = try encoder.encode(memory.record)
    let suite = "anice.auto.test.\(UUID().uuidString)"
    let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let radio = SessionRadioFake(), cooldown = SessionRecoveryWait()
    var clock: TimeInterval = 0
    let model = MacSessionModel(identity: service, adapter: radio, store: { trust }, now: { clock },
      preferences: preferences, wait: { await cooldown.pause($0) })
    defer { model.cancel(); cooldown.release() }
    XCTAssertFalse(model.automatic)
    model.selectedPeer = android
    model.setAutomatic(true)
    try await waitFor { radio.started }
    let stale = radio.sessionAdmitted
    clock = 120; radio.started = false; model.tick()
    try await waitFor { radio.started }
    XCTAssertFalse(stale?() ?? true)
    XCTAssertTrue(model.automatic)
    for index in 1...5 {
      XCTAssertTrue(radio.sessionAdmitted?() ?? false)
      XCTAssertFalse(radio.sessionAdmitted?() ?? true)
      XCTAssertTrue(radio.sessionWrite?(Data([0])) ?? false)
      if index < 5 { try await waitFor { radio.resumes == index } }
      else { try await waitFor { !cooldown.delays.isEmpty } }
    }
    XCTAssertEqual(cooldown.delays, [120])
    model.allow() // A pending admission cooldown cannot be bypassed by a manual command.
    XCTAssertFalse(model.allowing)
    XCTAssertNil(radio.sessionAdmitted)
    // Stop wins even if the timer continuation is already queued for delivery.
    model.disconnect(); radio.started = false; cooldown.release()
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertFalse(radio.started); XCTAssertFalse(model.automatic)
    XCTAssertTrue(preferences.bool(forKey: "session.paused"))
    model.restoreAutomatic(); XCTAssertFalse(model.automatic)
    model.setAutomatic(true); try await waitFor { radio.started }
    let beforeSleep = radio.sessionAdmitted
    model.sleep(); XCTAssertFalse(model.allowing)
    XCTAssertFalse(beforeSleep?() ?? true)
    radio.started = false; model.wake(); try await waitFor { radio.started }
    model.suspendAutomatic(); XCTAssertFalse(model.allowing)
    radio.started = false; model.resumeAutomatic(); try await waitFor { radio.started }
    model.setAutomatic(false); radio.started = false
    model.resumeAutomatic(); XCTAssertFalse(radio.started)
    // Restored policy must not bind a remembered peer to a different local identity.
    preferences.set(true, forKey: "session.automatic")
    preferences.set(false, forKey: "session.paused")
    preferences.set("changed", forKey: "session.local")
    model.restoreAutomatic()
    try await waitFor { model.state == "Failed" }
    XCTAssertFalse(radio.started); XCTAssertFalse(model.automatic)
    XCTAssertEqual(try Data(contentsOf: url), savedTrust)
    XCTAssertEqual(try encoder.encode(memory.record), savedIdentity)
    model.quit(); model.wake(); XCTAssertFalse(model.allowing)
  }
  func testExpiryCancellationStaleCallbacksAndDurableState() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("trust.json")
    let trust = try PeerTrustStore(url: url)
    let memory = PairingMemoryIdentity()
    let identity = IdentityService(
      storage: memory, deviceName: "Mac test", tagPrefix: "session.test.")
    _ = try await identity.publicIdentity()
    let identityEncoder = JSONEncoder()
    identityEncoder.outputFormatting = [.sortedKeys]
    let savedIdentity = try identityEncoder.encode(memory.record)
    let savedTrust = try Data(contentsOf: url)
    let radio = SessionRadioFake()
    var clock: TimeInterval = 0
    let model = MacSessionModel(
      identity: identity, adapter: radio, store: { trust }, now: { clock })
    model.allow()
    for _ in 0..<200 {
      if radio.started { break }
      try await Task.sleep(for: .milliseconds(1))
    }
    XCTAssertTrue(radio.started)
    XCTAssertTrue(model.allowing)
    let staleAdmission = radio.sessionAdmitted
    let staleEvent = radio.event
    clock = 120
    model.tick()
    XCTAssertFalse(model.allowing)
    XCTAssertEqual(model.state, "Disconnected")
    XCTAssertFalse(staleAdmission?() ?? true)
    staleEvent?(.advertising)
    XCTAssertFalse(model.allowing)
    XCTAssertEqual(try Data(contentsOf: url), savedTrust)
    XCTAssertEqual(try identityEncoder.encode(memory.record), savedIdentity)
    clock = 200
    radio.started = false
    model.allow()
    for _ in 0..<200 {
      if radio.started { break }
      try await Task.sleep(for: .milliseconds(1))
    }
    XCTAssertTrue(radio.sessionAdmitted?() ?? false)
    XCTAssertFalse(radio.sessionAdmitted?() ?? true)
    clock = 230
    model.tick()
    XCTAssertEqual(model.state, "Failed")
    XCTAssertTrue(model.allowing)
    try await waitFor { radio.resumes == 1 }
    XCTAssertGreaterThan(radio.retirement, 0)
    model.cancel()
    XCTAssertNil(radio.sessionWrite)
    XCTAssertNil(radio.sessionAdmitted)
    XCTAssertEqual(try Data(contentsOf: url), savedTrust)
    XCTAssertEqual(try identityEncoder.encode(memory.record), savedIdentity)
  }
}
