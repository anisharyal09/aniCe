// SPDX-License-Identifier: GPL-3.0-or-later
// Checks independently generated numeric-comparison vectors, ordered disclosure and trust activation.
import CryptoKit
import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import aniCe

final class PairingSasTests: XCTestCase, @unchecked Sendable {
  func testCompanionSetupEnvelopeIsBoundedAndDirectional() throws {
    for message in [CompanionSetupMessage(kind: 1), CompanionSetupMessage(kind: 2, seconds: 60),
      CompanionSetupMessage(kind: 2), CompanionSetupMessage(kind: 3, available: true)] {
      XCTAssertEqual(try CompanionSetupMessage.decode(message.encode()), message)
    }
    XCTAssertThrowsError(try CompanionSetupMessage(kind: 2, seconds: 61).encode())
    let bad = try SessionCbor.encode(.array([.text(CompanionSetupMessage.tag), .integer(1),
      .integer(2), .array([.integer(60), .integer(60)])]))
    XCTAssertThrowsError(try CompanionSetupMessage.decode(bad))
    let messages = [CompanionSetupMessage(kind: 1), CompanionSetupMessage(kind: 2, seconds: 60),
      CompanionSetupMessage(kind: 2), CompanionSetupMessage(kind: 3, available: true),
      CompanionSetupMessage(kind: 3, available: false)]
    XCTAssertEqual(try messages.map { try $0.encode().map { String(format: "%02x", $0) }.joined() }, [
      "8475616e69436520636f6d70616e696f6e20736574757001018101",
      "8475616e69436520636f6d70616e696f6e207365747570010281183c",
      "8475616e69436520636f6d70616e696f6e20736574757001028100",
      "8475616e69436520636f6d70616e696f6e207365747570010381f5",
      "8475616e69436520636f6d70616e696f6e207365747570010381f4",
    ])
  }
  @MainActor func testCompanionSetupRequiresCapabilityAndDoesNotExtendDuplicateWindow() async throws {
    let identity = IdentityService(storage: PairingMemoryIdentity(), deviceName: "Test", tagPrefix: "test.")
    let initial = try await identity.publicIdentity()
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: PairingCodec.identityBytes(initial)) as? [String: Any])
    json["platform"] = "android"
    let peer = try DeviceIdentity.decode(JSONSerialization.data(withJSONObject: json))
    let link = NamesLink(peer: peer)
    var transitions: [Bool] = []
    let owner = MacCompanionSetup(advertising: { transitions.append($0); return true },
      wait: { try await Task.sleep(for: .seconds(1000)) })
    owner.available(link)
    let early = await owner.handle(try CompanionSetupMessage(kind: 2, seconds: 60).encode(), on: link.descriptor)
    XCTAssertEqual(early, .discarded)
    XCTAssertTrue(transitions.isEmpty)
    _ = await owner.handle(try CompanionSetupMessage(kind: 1).encode(), on: link.descriptor)
    _ = await owner.handle(try CompanionSetupMessage(kind: 2, seconds: 60).encode(), on: link.descriptor)
    _ = await owner.handle(try CompanionSetupMessage(kind: 2, seconds: 60).encode(), on: link.descriptor)
    XCTAssertEqual(transitions, [true])
    owner.retired(link.descriptor)
    XCTAssertEqual(transitions, [true, false])
    let late = await owner.handle(try CompanionSetupMessage(kind: 2, seconds: 60).encode(), on: link.descriptor)
    XCTAssertEqual(late, .discarded)
  }
  @MainActor func testCompanionWindowExpiresAndLanDoesNotSwallowOtherFeatures() async throws {
    let identity = IdentityService(storage: PairingMemoryIdentity(), deviceName: "Test", tagPrefix: "test.")
    let initial = try await identity.publicIdentity()
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: PairingCodec.identityBytes(initial)) as? [String: Any])
    json["platform"] = "android"
    let peer = try DeviceIdentity.decode(JSONSerialization.data(withJSONObject: json))
    let link = NamesLink(peer: peer)
    var transitions: [Bool] = []
    let owner = MacCompanionSetup(advertising: { transitions.append($0); return true }, wait: {})
    owner.available(link)
    _ = await owner.handle(try CompanionSetupMessage(kind: 1).encode(), on: link.descriptor)
    _ = await owner.handle(try CompanionSetupMessage(kind: 2, seconds: 60).encode(), on: link.descriptor)
    try await waitFor { transitions == [true, false] }
    let lan = ChannelDescriptor(instance: "lan", transport: "lan", peer: peer)
    let unrelated = await owner.handle(try NameWire.encode(), on: lan)
    XCTAssertEqual(unrelated, .unrecognized)
    let foreign = await owner.handle(try CompanionSetupMessage(kind: 1).encode(), on: lan)
    XCTAssertEqual(foreign, .discarded)
    let wrongDirection = await owner.handle(try CompanionSetupMessage(kind: 3, available: true).encode(), on: link.descriptor)
    XCTAssertEqual(wrongDirection, .discarded)
    owner.retired(link.descriptor)
    XCTAssertEqual(transitions, [true, false])
  }
  @MainActor func testCompanionCapabilityRetainsCapacityEventDuringRefusedSend() async throws {
    let identity = IdentityService(storage: PairingMemoryIdentity(), deviceName: "Test", tagPrefix: "test.")
    let peer = try await identity.publicIdentity()
    let link = NamesLink(peer: peer)
    var release: CheckedContinuation<Void, Never>?
    var attempts = 0
    link.submit = { _ in
      attempts += 1
      if attempts == 1 {
        await withCheckedContinuation { release = $0 }
        throw SessionBackpressure()
      }
    }
    let owner = MacCompanionSetup(advertising: { _ in true })
    owner.available(link)
    try await waitFor { release != nil }
    owner.capacityAvailable(link.descriptor)
    release?.resume()
    try await waitFor { attempts == 2 }
    for _ in 0..<5 { owner.capacityAvailable(link.descriptor) }
    await Task.yield()
    XCTAssertEqual(attempts, 2, "Successful capability must not be replayed")
    owner.retired(link.descriptor)
  }
  @MainActor func testSyncedNamesPreserveTrustAndPrivateAliasPrecedence() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("anice-names-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let identity = IdentityService(storage: PairingMemoryIdentity(), deviceName: "Mac", tagPrefix: "test.")
    let local = try await identity.publicIdentity()
    let signing = P256.Signing.PrivateKey()
    let initial = try DeviceIdentity(deviceId: UUID().uuidString.lowercased(), deviceName: "Original Phone",
      publicKey: signing.publicKey.x963Representation)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: PairingCodec.identityBytes(initial)) as? [String: Any])
    object["platform"] = "android"
    let peer = try DeviceIdentity.decode(JSONSerialization.data(withJSONObject: object))
    let trust = try PeerTrustStore(url: directory.appendingPathComponent("trust.json"))
    let hash = Data(repeating: 9, count: 32)
    try trust.prepare(PeerTrustRecord(peer: peer, localFingerprint: local.fingerprint,
      method: .qr, pairedAt: Date(), transcriptHash: hash, active: false))
    try trust.activate(peerID: peer.deviceId, hash: hash,
      receipt: signing.signature(for: PairingCodec.receipt(hash, 1)).derRepresentation)
    let owner = PeerNames(url: directory.appendingPathComponent("names.json"))
    owner.configure(identity: identity, trust: { trust })
    try await owner.awaitRefresh()
    try await owner.saveNickname(peer: peer, name: "Private Phone", enabled: true)
    XCTAssertEqual(owner.displayName(peer), "Private Phone")
    let link = NamesLink(peer: peer)
    owner.available(link)
    _ = await owner.handle(try NameWire.encode(), on: link.descriptor)
    let handled = await owner.handle(try NameWire.encode(NameReport(revision: 4, name: "Renamed Phone")),
      on: link.descriptor)
    XCTAssertEqual(handled, .handled)
    XCTAssertEqual(owner.deviceName(peer), "Renamed Phone")
    XCTAssertEqual(owner.displayName(peer), "Private Phone")
    try await owner.saveNickname(peer: peer, name: "Private Phone", enabled: false)
    XCTAssertEqual(owner.displayName(peer), "Renamed Phone")
    XCTAssertEqual(trust.list(localFingerprint: local.fingerprint).first?.peer.deviceName, "Original Phone")
    let stale = await owner.handle(try NameWire.encode(NameReport(revision: 3, name: "Stale")), on: link.descriptor)
    XCTAssertEqual(stale, .discarded)
    owner.retired(link.descriptor)
    let retired = await owner.handle(try NameWire.encode(NameReport(revision: 5, name: "Retired")), on: link.descriptor)
    XCTAssertEqual(retired, .discarded)
    let reopened = PeerNames(url: directory.appendingPathComponent("names.json"))
    reopened.configure(identity: identity, trust: { trust })
    try await reopened.awaitRefresh()
    XCTAssertEqual(reopened.deviceName(peer), "Renamed Phone")
    try trust.remove(peer.deviceId)
    reopened.invalidate()
    try await reopened.awaitRefresh()
    XCTAssertNil(reopened.nickname(peer))
    XCTAssertEqual(reopened.deviceName(peer), peer.deviceName)
  }

  func testNameWireBoundsAndUniformNativeEncoding() throws {
    XCTAssertEqual(try NameWire.encode().map { String(format: "%02x", $0) }.joined(),
      "8472616e69436520646576696365206e616d657301018101")
    for name in ["Mac", String(repeating: "😀", count: 64)] {
      let report = NameReport(revision: Int64.max, name: name)
      XCTAssertEqual(try NameWire.decode(NameWire.encode(report))?.1, report)
    }
    XCTAssertThrowsError(try NameWire.encode(NameReport(revision: -1, name: "Mac")))
    XCTAssertThrowsError(try NameWire.encode(NameReport(revision: 1, name: " Mac ")))
    XCTAssertThrowsError(try NameWire.encode(NameReport(revision: 1, name: String(repeating: "x", count: 65))))
  }

  @MainActor func testNamesPersistenceFailureKeepsPreviousDisplay() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("anice-names-fault-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let identity = IdentityService(storage: PairingMemoryIdentity(), deviceName: "Mac", tagPrefix: "test.")
    let local = try await identity.publicIdentity()
    let key = P256.Signing.PrivateKey()
    let peer = try DeviceIdentity(deviceId: UUID().uuidString.lowercased(), deviceName: "Peer",
      publicKey: key.publicKey.x963Representation)
    let trust = try PeerTrustStore(url: directory.appendingPathComponent("trust.json"))
    let hash = Data(repeating: 3, count: 32)
    try trust.prepare(PeerTrustRecord(peer: peer, localFingerprint: local.fingerprint, method: .qr,
      pairedAt: Date(), transcriptHash: hash, active: false))
    try trust.activate(peerID: peer.deviceId, hash: hash,
      receipt: key.signature(for: PairingCodec.receipt(hash, 2)).derRepresentation)
    let memory = NamesMemory()
    let owner = PeerNames(url: directory.appendingPathComponent("names.json"),
      read: { memory.read() }, write: { try memory.write($0) })
    owner.configure(identity: identity, trust: { trust })
    try await owner.awaitRefresh()
    try await owner.saveNickname(peer: peer, name: "First", enabled: true)
    memory.failWrites()
    do { try await owner.saveNickname(peer: peer, name: "Second", enabled: true)
      XCTFail("Storage error ignored")
    } catch {}
    XCTAssertEqual(owner.displayName(peer), "First")
  }

  private final class NamesMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var fail = false
    func read() -> Data? { lock.lock(); defer { lock.unlock() }; return data }
    func write(_ value: Data) throws {
      lock.lock(); defer { lock.unlock() }
      if fail { throw SessionFailure.state }
      data = value
    }
    func failWrites() { lock.lock(); defer { lock.unlock() }; fail = true }
  }

  @MainActor private final class NamesLink: SecuredChannel {
    let descriptor: ChannelDescriptor
    init(peer: DeviceIdentity) { descriptor = ChannelDescriptor(instance: UUID().uuidString, transport: "ble", peer: peer) }
    var submit: (Data) async throws -> Void = { _ in }
    func sendData(_ bytes: Data) async throws { try await submit(bytes) }
  }
  func testNicknameKeepsCredentialAndRealNameSeparate() async throws {
    let identity = IdentityService(storage: PairingMemoryIdentity(), deviceName: "Real Mac", tagPrefix: "test.")
    let peer = try await identity.publicIdentity()
    let before = PeerNickname.credential(peer)
    XCTAssertEqual(try PeerNickname(name: "Private Mac", enabled: false).displayedName(for: peer), "Real Mac")
    XCTAssertEqual(try PeerNickname(name: "Private Mac", enabled: true).displayedName(for: peer), "Private Mac")
    XCTAssertEqual(PeerNickname.credential(peer), before)
    XCTAssertThrowsError(try PeerNickname(name: "", enabled: true))
    XCTAssertNoThrow(try PeerNickname(name: String(repeating: "😀", count: 64), enabled: true))
  }
  private func hex(_ string: String) -> Data {
    let chars = Array(string)
    return Data(stride(from: 0, to: chars.count, by: 2).map {
      UInt8(String(chars[$0...($0 + 1)]), radix: 16)!
    })
  }

  func testIndependentVectorsAndLeadingZero() throws {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sas-vectors", withExtension: "json"))
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    XCTAssertEqual(root["fixtureVersion"] as? Int, 1)
    let vectors = try XCTUnwrap(root["valid"] as? [[String: Any]])
    XCTAssertEqual(vectors.count, 2)
    for vector in vectors {
      func bytes(_ name: String) throws -> Data { hex(try XCTUnwrap(vector[name + "Hex"] as? String)) }
      let clientIC = try PairingSas.identityCommitment(role: 1,
        salt: bytes("clientIdentitySalt"), identity: bytes("clientIdentity"))
      let serverIC = try PairingSas.identityCommitment(role: 2,
        salt: bytes("serverIdentitySalt"), identity: bytes("serverIdentity"))
      XCTAssertEqual(clientIC, try bytes("clientIdentityCommitment"))
      XCTAssertEqual(serverIC, try bytes("serverIdentityCommitment"))
      let transcript = try PairingSas.transcript(rendezvous: bytes("rendezvous"),
        serverNonce: bytes("serverNonce"), clientCommitment: bytes("clientCommitment"),
        serverCommitment: bytes("serverCommitment"), clientPublic: bytes("clientPublic"),
        serverPublic: bytes("serverPublic"), clientNonce: bytes("clientNonce"),
        serverComparisonNonce: bytes("serverComparisonNonce"),
        clientIdentityCommitment: clientIC, serverIdentityCommitment: serverIC)
      XCTAssertEqual(transcript, try bytes("transcript"))
      let key = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0, count: 31) + Data([1]))
      let shared = try key.sharedSecretFromKeyAgreement(with:
        P256.KeyAgreement.PublicKey(x963Representation: bytes("serverPublic")))
      let secret = shared.withUnsafeBytes { Data($0) }
      XCTAssertEqual(secret, try bytes("sharedSecret"))
      let bootstrap = PairingSas.bootstrap(shared: secret, transcript: transcript)
      XCTAssertEqual(bootstrap, try bytes("bootstrapKey"))
      let digits = try PairingSas.digits(key: bootstrap, transcript: transcript)
      XCTAssertEqual(digits, vector["digits"] as? String)
      if vector["name"] as? String == "leading-zero" { XCTAssertTrue(digits.hasPrefix("0")) }
      let channel = PairingChannel(key: bootstrap, transcript: transcript, server: false)
      XCTAssertEqual(channel.confirm(), try bytes("serverFinish"))
      XCTAssertEqual(try channel.seal(PairingCodec.message(15)), try bytes("encryptedComparison"))
      XCTAssertEqual(PairingCodec.mac(PairingCodec.derive(bootstrap, "client-auth",
        PairingCodec.hash(transcript)), transcript), try bytes("clientFinish"))
      var alteredNonce = try bytes("clientNonce")
      alteredNonce[0] ^= 1
      XCTAssertThrowsError(try PairingSas.transcript(rendezvous: bytes("rendezvous"),
        serverNonce: bytes("serverNonce"), clientCommitment: bytes("clientCommitment"),
        serverCommitment: bytes("serverCommitment"), clientPublic: bytes("clientPublic"),
        serverPublic: bytes("serverPublic"), clientNonce: alteredNonce,
        serverComparisonNonce: bytes("serverComparisonNonce"), clientIdentityCommitment: clientIC,
        serverIdentityCommitment: serverIC))
    }
    let decimals = try XCTUnwrap(root["decimal"] as? [[String: Any]])
    for decimal in decimals {
      XCTAssertEqual(try PairingSas.decimal(hex(try XCTUnwrap(decimal["hex"] as? String))),
        decimal["digits"] as? String)
    }
    XCTAssertThrowsError(try PairingSas.decimal(Data(count: 3)))
  }

  private actor Bus {
    var output: [Data] = []
    var events: [String] = []
    var digits: String?
    func send(_ bytes: Data) { output.append(bytes) }
    func event(_ value: String) { events.append(value) }
    func compared(_ value: String) { digits = value }
    func take() -> [Data] { defer { output.removeAll() }; return output }
  }

  private struct Exchange {
    let directory: URL
    let store: PeerTrustStore
    let storage: PairingMemoryIdentity
    let identity: IdentityService
    let engine: PairingEngine
    let bus: Bus
    let client: PairingChannel
    let androidKey: P256.Signing.PrivateKey
    let android: DeviceIdentity
    let androidBytes: Data
    let salt: Data
    let serverIC: Data
    let transcript: Data
    let lease: PairingAttemptLease
  }

  private func exchange() async throws -> Exchange {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "anice-sas-test-" + UUID().uuidString)
    let store = try PeerTrustStore(url: directory.appendingPathComponent("trust.json"))
    let storage = PairingMemoryIdentity()
    let identity = IdentityService(storage: storage, deviceName: "Synthetic Mac", tagPrefix: "test.")
    let bus = Bus()
    let lease = PairingAttemptLease()
    let engine = try await PairingEngine(method: .sas, identity: identity, store: store,
      send: { await bus.send($0) }, event: { state, _ in await bus.event(state) },
      comparison: { await bus.compared($0) }, isCurrent: { lease.active })
    let invitation = try PairingCodec.unpack(await engine.invitation(), type: 2, count: 3)
    let androidKey = P256.Signing.PrivateKey()
    let provisional = try DeviceIdentity(deviceId: UUID().uuidString.lowercased(),
      deviceName: "Synthetic Android", publicKey: androidKey.publicKey.x963Representation)
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: PairingCodec.identityBytes(provisional)) as? [String: Any])
    json["platform"] = "android"
    let androidBytes = try JSONSerialization.data(withJSONObject: json)
    let android = try DeviceIdentity.decode(androidBytes)
    let salt = Data(repeating: 7, count: 32)
    let clientIC = try PairingSas.identityCommitment(role: 1, salt: salt, identity: androidBytes)
    let key = P256.KeyAgreement.PrivateKey()
    let nonce = Data(repeating: 8, count: 32)
    let publicKey = key.publicKey.x963Representation
    let commitment = try PairingSas.commitment(role: 1, rendezvous: invitation[1],
      serverNonce: invitation[2], publicKey: publicKey, nonce: nonce, identityCommitment: clientIC)
    try await engine.receive(PairingCodec.message(3, [Data([3]), invitation[1], commitment]))
    let serverCommit = await bus.take()
    XCTAssertEqual(serverCommit.count, 1)
    let hello = try PairingCodec.unpack(serverCommit[0], type: 4, count: 2)
    XCTAssertEqual(hello[0], invitation[2])
    try await engine.receive(PairingCodec.message(8, [publicKey, nonce, clientIC]))
    let serverReveal = await bus.take()
    XCTAssertEqual(serverReveal.count, 1)
    let reveal = try PairingCodec.unpack(serverReveal[0], type: 9, count: 3)
    let transcript = try PairingSas.transcript(rendezvous: invitation[1], serverNonce: invitation[2],
      clientCommitment: commitment, serverCommitment: hello[1], clientPublic: publicKey,
      serverPublic: reveal[0], clientNonce: nonce, serverComparisonNonce: reveal[1],
      clientIdentityCommitment: clientIC, serverIdentityCommitment: reveal[2])
    let shared = try key.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: reveal[0]))
    let bootstrap = PairingSas.bootstrap(shared: shared.withUnsafeBytes { Data($0) }, transcript: transcript)
    let channel = PairingChannel(key: bootstrap, transcript: transcript, server: false)
    try await engine.receive(PairingCodec.message(5, [
      PairingCodec.mac(PairingCodec.derive(bootstrap, "client-auth", PairingCodec.hash(transcript)), transcript),
    ]))
    let finish = await bus.take()
    XCTAssertEqual(finish.count, 1, "No identity traffic before user confirmation")
    XCTAssertEqual(try PairingCodec.unpack(finish[0], type: 6, count: 1)[0], channel.confirm())
    let digits = await bus.digits
    XCTAssertEqual(digits, try PairingSas.digits(key: bootstrap, transcript: transcript))
    XCTAssertEqual(storage.signatures, 1, "Only identity creation signs before comparison")
    return Exchange(directory: directory, store: store, storage: storage, identity: identity,
      engine: engine, bus: bus, client: channel, androidKey: androidKey, android: android,
      androidBytes: androidBytes, salt: salt, serverIC: reveal[2], transcript: transcript, lease: lease)
  }

  func testBothConfirmThenVerifyIdentityAndDurableReceipts() async throws {
    let e = try await exchange()
    defer { try? FileManager.default.removeItem(at: e.directory) }
    let local = await e.engine.local
    try await e.engine.confirmComparison()
    let approval = await e.bus.take()
    XCTAssertEqual(approval.count, 1)
    XCTAssertEqual(try e.client.open(approval[0]), PairingCodec.message(15))
    XCTAssertTrue(e.store.list(localFingerprint: local.fingerprint).isEmpty)
    try await e.engine.receive(e.client.seal(PairingCodec.message(15)))
    let disclosure = await e.bus.take()
    let fields = try PairingCodec.unpack(e.client.open(disclosure[0]), type: 10, count: 2)
    XCTAssertEqual(try PairingSas.identityCommitment(role: 2, salt: fields[1], identity: fields[0]), e.serverIC)
    let macBytes = fields[0]
    try await e.engine.receive(e.client.seal(PairingCodec.message(10, [e.androidBytes, e.salt])))
    let proofs = await e.bus.take()
    let proof = try PairingCodec.unpack(e.client.open(proofs[0]), type: 11, count: 1)[0]
    let hash = PairingCodec.hash(e.transcript)
    XCTAssertTrue(local.verify(message: PairingCodec.proof(hash, e.androidBytes, macBytes, 2), signature: proof))
    let signed = try e.androidKey.signature(for: PairingCodec.proof(hash, e.androidBytes, macBytes, 1)).derRepresentation
    try await e.engine.receive(e.client.seal(PairingCodec.message(11, [signed])))
    let approved = await e.bus.take()
    XCTAssertEqual(try e.client.open(approved[0]), PairingCodec.message(12))
    XCTAssertTrue(e.store.list(localFingerprint: local.fingerprint).isEmpty)
    try await e.engine.receive(e.client.seal(PairingCodec.message(12)))
    let receiptMessages = await e.bus.take()
    let receipt = try PairingCodec.unpack(e.client.open(receiptMessages[0]), type: 13, count: 1)[0]
    let trustHash = PairingCodec.hash(PairingCodec.proof(hash, e.androidBytes, macBytes))
    XCTAssertTrue(local.verify(message: PairingCodec.receipt(trustHash, 2), signature: receipt))
    XCTAssertTrue(e.store.list(localFingerprint: local.fingerprint).isEmpty)
    let peerReceipt = try e.androidKey.signature(for: PairingCodec.receipt(trustHash, 1)).derRepresentation
    try await e.engine.receive(e.client.seal(PairingCodec.message(13, [peerReceipt])))
    XCTAssertEqual(e.store.list(localFingerprint: local.fingerprint).first?.method, .sas)
    let names = await e.bus.events
    XCTAssertTrue(names.contains("paired"))
    await e.engine.close()
    let reopened = try PeerTrustStore(url: e.directory.appendingPathComponent("trust.json"))
    XCTAssertEqual(reopened.list(localFingerprint: local.fingerprint).count, 1)
  }

  func testEarlyIdentityApprovalAndReceiptRetireAttempt() async throws {
    for type: UInt8 in [10, 11, 12, 13] {
      let e = try await exchange()
      defer { try? FileManager.default.removeItem(at: e.directory) }
      let message = type == 10 ? PairingCodec.message(10, [e.androidBytes, e.salt])
        : type == 12 ? PairingCodec.message(12) : PairingCodec.message(type, [Data([1])])
      do { try await e.engine.receive(e.client.seal(message)); XCTFail("Early trust message accepted") }
      catch {}
      do { try await e.engine.confirmComparison(); XCTFail("Retired comparison remained usable") }
      catch {}
      let local = await e.engine.local
      XCTAssertTrue(e.store.list(localFingerprint: local.fingerprint).isEmpty)
    }
  }

  func testDismissSendsCancellationAndCreatesNoTrust() async throws {
    let e = try await exchange()
    defer { try? FileManager.default.removeItem(at: e.directory) }
    try await e.engine.decline()
    let messages = await e.bus.take()
    XCTAssertEqual(messages.count, 1)
    XCTAssertEqual(try e.client.open(messages[0]), PairingCodec.message(14))
    do { try await e.engine.confirmComparison(); XCTFail("Dismissed comparison accepted") } catch {}
    let local = await e.engine.local
    XCTAssertTrue(e.store.list(localFingerprint: local.fingerprint).isEmpty)
  }

  func testIdentityOpeningChangeFailsEvenAfterBothConfirm() async throws {
    let e = try await exchange()
    defer { try? FileManager.default.removeItem(at: e.directory) }
    try await e.engine.receive(e.client.seal(PairingCodec.message(15)))
    try await e.engine.confirmComparison()
    var salt = e.salt
    salt[0] ^= 1
    do { try await e.engine.receive(e.client.seal(PairingCodec.message(10, [e.androidBytes, salt])))
      XCTFail("Different identity opening accepted")
    } catch {}
    let local = await e.engine.local
    XCTAssertTrue(e.store.list(localFingerprint: local.fingerprint).isEmpty)
  }

  func testRenamingCancelsComparisonBeforeIdentityDisclosure() async throws {
    let e = try await exchange()
    defer { try? FileManager.default.removeItem(at: e.directory) }
    _ = try await e.identity.rename("Renamed Mac")
    do { try await e.engine.confirmComparison(); XCTFail("Renamed identity comparison accepted") } catch {}
    let messages = await e.bus.take()
    XCTAssertTrue(messages.isEmpty)
    await e.engine.close()
  }

  func testSynchronousRevocationBlocksDisclosureBeforeActorCleanup() async throws {
    let e = try await exchange()
    defer { try? FileManager.default.removeItem(at: e.directory) }
    e.lease.cancel()
    do { try await e.engine.confirmComparison(); XCTFail("Revoked attempt accepted confirmation") } catch {}
    do { try await e.engine.receive(e.client.seal(PairingCodec.message(15)))
      XCTFail("Revoked attempt accepted peer confirmation")
    } catch {}
    let output = await e.bus.take()
    XCTAssertTrue(output.isEmpty)
    let local = await e.engine.local
    XCTAssertTrue(e.store.list(localFingerprint: local.fingerprint).isEmpty)
  }

  func testWrongCommitmentCannotBeReopenedOnSameEngine() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("anice-sas-invalid-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try PeerTrustStore(url: directory.appendingPathComponent("trust.json"))
    let identity = IdentityService(storage: PairingMemoryIdentity(), deviceName: "Test", tagPrefix: "test.")
    let bus = Bus()
    let engine = try await PairingEngine(method: .sas, identity: identity, store: store,
      send: { await bus.send($0) }, event: { state, _ in await bus.event(state) })
    let invitation = try PairingCodec.unpack(await engine.invitation(), type: 2, count: 3)
    try await engine.receive(PairingCodec.message(3, [Data([3]), invitation[1], Data(count: 32)]))
    let publicKey = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
    do { try await engine.receive(PairingCodec.message(8, [publicKey, Data(count: 32), Data(count: 32)]))
      XCTFail("Invalid opening accepted")
    } catch {}
    do { try await engine.receive(PairingCodec.message(1)); XCTFail("Retired engine reopened") } catch {}
    let messages = await bus.take()
    XCTAssertEqual(messages.count, 1, "Only the commitment reply may be sent")
  }

  func testAdmissionIsGlobalAndDismissalCannotBeResetByRetry() {
    var admission = NearbyPairingAdmission()
    XCTAssertTrue(admission.admit(at: 0))
    XCTAssertFalse(admission.admit(at: 9.9))
    for time: TimeInterval in [10, 20, 30, 40] { XCTAssertTrue(admission.admit(at: time)) }
    XCTAssertFalse(admission.admit(at: 50))
    XCTAssertTrue(admission.admit(at: 120))
    admission.dismiss(at: 121)
    XCTAssertFalse(admission.admit(at: 180.9))
    XCTAssertTrue(admission.admit(at: 181))
  }
  func testAdmissionAvailabilityDeadlinePreservesSpacingBudgetAndDismissal() {
    var admission = NearbyPairingAdmission()
    XCTAssertEqual(admission.nextAdmission(at: 0), 0)
    XCTAssertTrue(admission.admit(at: 0))
    XCTAssertEqual(admission.nextAdmission(at: 1), 10)
    for time: TimeInterval in [10, 20, 30, 40] { XCTAssertTrue(admission.admit(at: time)) }
    XCTAssertEqual(admission.nextAdmission(at: 50), 120)
    admission.dismiss(at: 100)
    XCTAssertEqual(admission.nextAdmission(at: 120), 160)
    XCTAssertEqual(admission.nextAdmission(at: 160), 160)
  }

  @MainActor private final class Radio: PairingPeripheralAdapter {
    var pairingWrite: ((Data) -> Bool)?
    var pairingDisconnect: (() -> Void)?
    var pairingAdmitted: (() -> Bool)?
    var pairingStopsAdvertisingOnAdmission = false
    var output: [Data] = []
    var reader: ((Bool, Int) -> DiscoveryRead)?
    var event: ((PeripheralEvent) -> Void)?
    func begin(event: @escaping (PeripheralEvent) -> Void,
      read: @escaping (Bool, Int) -> DiscoveryRead) {
      self.event = event
      reader = read
      event(.available)
    }
    func publish() { event?(.published) }
    func advertise() { event?(.advertising) }
    func stop() { event = nil; reader = nil }
    func sendPairing(_ message: Data) throws { output.append(message) }
    func drainPairing() async {}
    func retirePairingConnection() { output.removeAll() }
  }

  @MainActor private func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0..<100 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Expected nearby pairing state did not arrive")
  }

  @MainActor private func renderComparison(_ model: MacPairingModel) throws {
    XCTAssertNotNil(NSImage(systemSymbolName: "smartphone", accessibilityDescription: nil))
    let name = "aniCe.ComparisonRender.\(UUID())"
    let preferences = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { preferences.removePersistentDomain(forName: name) }
    let code = model.comparisonCode
    let attempt = model.comparisonAttempt
    var renders = 0
    for dark in [false, true] {
      for scale in [0.8, 1.0, 1.2] {
        for width in [320.0, 360.0] {
          preferences.set(scale, forKey: "ui.fontScale")
          let view = MacComparisonCard(model: model, openApp: {}).frame(width: width)
            .environment(\.colorScheme, dark ? .dark : .light).defaultAppStorage(preferences)
          let host = NSHostingView(rootView: view)
          let size = host.fittingSize
          XCTAssertEqual(size.width, width, accuracy: 1)
          XCTAssertGreaterThan(size.height, 150)
          XCTAssertLessThan(size.height, 400)
          host.frame = NSRect(origin: .zero, size: size)
          host.layoutSubtreeIfNeeded()
          let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
          host.cacheDisplay(in: host.bounds, to: bitmap)
          let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
          XCTAssertGreaterThan(data.count, 1000)
          if let path = ProcessInfo.processInfo.environment["ANICE_REVIEW_RENDER_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(
               "comparison-\(dark ? "dark" : "light")-\(Int(width))-\(Int(scale * 100)).png"))
          }
          renders += 1
        }
      }
    }
    XCTAssertEqual(renders, 12)
    XCTAssertEqual(model.phase, "comparison", "Rendering must never confirm the attempt")
    XCTAssertEqual(model.comparisonCode, code)
    XCTAssertEqual(model.comparisonAttempt, attempt)
  }

  @MainActor func testModelSharesCodeAndRejectsStaleConfirmationAfterDismissal() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "anice-sas-model-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try PeerTrustStore(url: directory.appendingPathComponent("trust.json"))
    let identity = IdentityService(storage: PairingMemoryIdentity(), deviceName: "Test Mac", tagPrefix: "test.")
    let radio = Radio()
    let discovery = MacDiscoveryModel(adapter: radio)
    var locked = false
    let model = MacPairingModel(identity: identity, discovery: discovery, makeStore: { store },
      isScreenLocked: { locked })
    defer { model.cancel() }
    model.start(.sas)
    try await waitFor { model.phase == "nearby" }
    XCTAssertTrue(radio.pairingStopsAdvertisingOnAdmission)
    guard case .value(let bytes) = radio.reader?(true, 0) else { XCTFail("No nearby payload"); return }
    XCTAssertEqual(try BlePayloadCodec.decode(bytes).flags, 1)
    XCTAssertTrue(radio.pairingAdmitted?() == true)
    XCTAssertFalse(radio.pairingAdmitted?() == true, "A second central cannot take the active slot")
    XCTAssertTrue(radio.pairingWrite?(PairingCodec.message(1)) == true)
    try await waitFor { radio.output.count == 1 }
    let invitation = try PairingCodec.unpack(radio.output.removeFirst(), type: 2, count: 3)
    let key = P256.KeyAgreement.PrivateKey()
    let publicKey = key.publicKey.x963Representation
    let nonce = Data(repeating: 3, count: 32)
    let ic = Data(repeating: 4, count: 32)
    let cc = try PairingSas.commitment(role: 1, rendezvous: invitation[1], serverNonce: invitation[2],
      publicKey: publicKey, nonce: nonce, identityCommitment: ic)
    XCTAssertTrue(radio.pairingWrite?(PairingCodec.message(3, [Data([3]), invitation[1], cc])) == true)
    try await waitFor { radio.output.count == 1 }
    let hello = try PairingCodec.unpack(radio.output.removeFirst(), type: 4, count: 2)
    XCTAssertTrue(radio.pairingWrite?(PairingCodec.message(8, [publicKey, nonce, ic])) == true)
    try await waitFor { radio.output.count == 1 }
    let reveal = try PairingCodec.unpack(radio.output.removeFirst(), type: 9, count: 3)
    let transcript = try PairingSas.transcript(rendezvous: invitation[1], serverNonce: invitation[2],
      clientCommitment: cc, serverCommitment: hello[1], clientPublic: publicKey,
      serverPublic: reveal[0], clientNonce: nonce, serverComparisonNonce: reveal[1],
      clientIdentityCommitment: ic, serverIdentityCommitment: reveal[2])
    let shared = try key.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: reveal[0]))
    let bootstrap = PairingSas.bootstrap(shared: shared.withUnsafeBytes { Data($0) }, transcript: transcript)
    let client = PairingChannel(key: bootstrap, transcript: transcript, server: false)
    let hash = PairingCodec.hash(transcript)
    XCTAssertTrue(radio.pairingWrite?(PairingCodec.message(5, [
      PairingCodec.mac(PairingCodec.derive(bootstrap, "client-auth", hash), transcript),
    ])) == true)
    try await waitFor { model.phase == "comparison" }
    XCTAssertEqual(model.comparisonCode, try PairingSas.digits(key: bootstrap, transcript: transcript))
    try renderComparison(model)
    let attempt = model.comparisonAttempt
    model.confirmComparison(attempt: UUID())
    XCTAssertEqual(model.phase, "comparison")
    let finish = try XCTUnwrap(radio.output.first)
    radio.output.removeFirst()
    XCTAssertEqual(try PairingCodec.unpack(finish, type: 6, count: 1)[0], client.confirm())
    locked = true
    model.confirmComparison(attempt: attempt)
    XCTAssertEqual(model.phase, "comparison", "A locked screen cannot confirm")
    XCTAssertTrue(radio.output.isEmpty)
    locked = false
    model.confirmComparison(attempt: attempt)
    try await waitFor { radio.output.count == 1 }
    XCTAssertEqual(model.phase, "waiting", "Confirm must wait for the phone, not dismiss")
    let confirmed = try XCTUnwrap(radio.output.first)
    radio.output.removeFirst()
    XCTAssertEqual(try client.open(confirmed), PairingCodec.message(15))
    XCTAssertEqual(model.comparisonAttempt, attempt)
    XCTAssertNotNil(model.comparisonCode)
    model.confirmComparison(attempt: attempt)
    XCTAssertTrue(radio.output.isEmpty, "Repeated confirmation must not emit another approval")
    model.dismissComparison(attempt: attempt)
    try await waitFor { !model.active }
    XCTAssertFalse(radio.pairingStopsAdvertisingOnAdmission)
    XCTAssertEqual(try client.open(try XCTUnwrap(radio.output.first)), PairingCodec.message(14))
    XCTAssertNil(model.comparisonCode)
    model.confirmComparison(attempt: attempt)
    XCTAssertFalse(model.active)
    model.start(.sas)
    try await waitFor { model.phase == "cooldown" }
    XCTAssertFalse(radio.pairingAdmitted?() == true, "Dismissal cooldown survives an explicit retry")
    XCTAssertNil(radio.reader, "Cooldown must not advertise a comparison the Mac cannot admit")
    model.confirmComparison(attempt: attempt)
    XCTAssertEqual(model.phase, "cooldown")
  }
}
