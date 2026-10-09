// SPDX-License-Identifier: GPL-3.0-or-later
// Runs isolated protected-key session interchange over process pipes or native TCP.
import CryptoKit
import Foundation

func emit(_ value: [String: Any]) throws {
  let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  FileHandle.standardOutput.write(data + Data([10]))
}
func input() throws -> [String: Any] {
  guard let line = readLine(), let bytes = line.data(using: .utf8), bytes.count <= 8192,
    let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
  else { throw SessionFailure.malformed }
  return value
}
func hex(_ value: Any?) throws -> Data {
  guard let text = value as? String, text.count % 2 == 0, text.count <= 8192 else {
    throw SessionFailure.malformed
  }
  var data = Data()
  for i in stride(from: 0, to: text.count, by: 2) {
    let a = text.index(text.startIndex, offsetBy: i)
    guard let b = UInt8(text[a..<text.index(a, offsetBy: 2)], radix: 16) else {
      throw SessionFailure.malformed
    }
    data.append(b)
  }
  return data
}
func text(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

actor InterchangeMailbox {
  private var bytes = Data()
  func put(_ value: Data) { bytes = value }
  func take() -> Data { bytes }
}
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--cleanup" {
  let target = CommandLine.arguments[2]
  let prefix = "io.github.anisharyal09.anice.tests.session."
  guard target.hasPrefix(prefix), UUID(uuidString: String(target.dropFirst(prefix.count))) != nil else { exit(2) }
  do {
    let disposable = MacIdentityStorage(namespace: target, backend: .developmentKeychain,
      recordURL: FileManager.default.temporaryDirectory.appendingPathComponent(target).appendingPathComponent("identity.json"))
    for tag in try disposable.keyTags() { try disposable.deleteKey(tag: tag) }
    guard try disposable.keyTags().isEmpty else { throw SessionFailure.state }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(target)
    if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    exit(0)
  } catch { exit(2) }
}
let namespace = "io.github.anisharyal09.anice.tests.session." + UUID().uuidString.lowercased()
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(namespace)
let storage = MacIdentityStorage(
  namespace: namespace, backend: .developmentKeychain,
  recordURL: directory.appendingPathComponent("identity.json"))
let identity = IdentityService(
  storage: storage, deviceName: "Session interchange", tagPrefix: namespace + ".")
func cleanup() throws {
  for tag in try storage.keyTags() { try storage.deleteKey(tag: tag) }
  guard try storage.keyTags().isEmpty else { throw SessionFailure.state }
  if FileManager.default.fileExists(atPath: directory.path) {
    try FileManager.default.removeItem(at: directory)
  }
}
do {
  if CommandLine.arguments.contains("--tcp") {
    try await tcpInterchange(identity: identity)
    try cleanup()
    try emit(["cleanup": true, "tcp": true, "bidirectionalBytes": 4000])
    exit(0)
  }
  let local = try await identity.publicIdentity()
  let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(local))
  try emit(["identity": object])
  let first = try input()
  guard let object = first["identity"] else { throw SessionFailure.malformed }
  let peer = try DeviceIdentity.decode(JSONSerialization.data(withJSONObject: object))
  let engine = try SessionHandshakeEngine(
    local: local, responder: true, trusted: { [peer] },
    currentIdentity: { try await identity.publicIdentity() },
    signer: { try await identity.sign(message: $0) })
  let m2 = try await engine.respond(hex(first["message1Hex"]))
  try emit(["message2Hex": text(m2)])
  let second = try input()
  let m4 = try await engine.authenticateInitiator(hex(second["message3Hex"]))
  let digest = try await SessionCrypto.hash(
    engine.export(context: Data("aniCe session interchange v1".utf8), length: 32))
  try emit(["message4Hex": text(m4), "exportDigestHex": text(digest)])
  let mailbox = InterchangeMailbox()
  let channel = try await SecureSession.fromHandshake(
    engine, responder: true, capacity: { _ in true }, submit: { await mailbox.put($0) })
  let ready = try await channel.receive(hex(input()["readyHex"]))
  guard ready.0 == .ready else { throw SessionFailure.state }
  try await channel.send(.readyAck)
  try emit(["readyAckHex": text(await mailbox.take())])
  // Verify control bytes inside the existing authenticated directional record channel.
  for (name, request, reply, value): (String, ControlKind, ControlKind, Int64) in [
    ("hello", .hello, .helloAck, 1), ("ping", .ping, .pong, 0),
  ] {
    let incoming = try await channel.receive(hex(input()[name + "Hex"]))
    guard incoming.0 == .data,
      try SessionControl.decode(incoming.1) == SessionControl(kind: request, value: value)
    else { throw SessionFailure.state }
    try await channel.send(.data, plaintext: SessionControl(kind: reply, value: value).encode())
    try emit([name + "ReplyHex": text(await mailbox.take())])
  }
  let payload = try await channel.receive(hex(input()["clientDataHex"]))
  let expected = Data((0..<4000).map { UInt8(truncatingIfNeeded: $0) })
  guard payload.0 == .data, payload.1 == expected, await channel.stage == .secured else {
    throw SessionFailure.authentication
  }
  try await channel.send(.data, plaintext: Data(expected.reversed()))
  let serverData = await mailbox.take()
  try await channel.send(.data, plaintext: SessionControl(kind: .renewalRequest, value: 1).encode())
  try emit(["serverDataHex": text(serverData), "renewalHex": text(await mailbox.take())])
  let closing = try await channel.receive(hex(input()["closeHex"]))
  guard closing.0 == .close, await channel.stage == .closed else { throw SessionFailure.state }
  let after = try await identity.publicIdentity()
  guard after == local else { throw SessionFailure.state }
  await engine.close()
  try cleanup()
  try emit(["cleanup": true])
} catch {
  do { try cleanup() } catch {
    FileHandle.standardError.write(Data("Isolated Keychain cleanup failed\n".utf8))
    exit(2)
  }
  FileHandle.standardError.write(Data("Session interchange failed: \(error)\n".utf8))
  exit(1)
}
