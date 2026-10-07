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
  private func fullPairing(_ method: PairingMethod) async throws {
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
  func retirePairingConnection() { output.removeAll() }
}

extension PairingTests {
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
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
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
