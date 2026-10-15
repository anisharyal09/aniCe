// SPDX-License-Identifier: GPL-3.0-or-later
// Exchanges native EDHOC and bounded encrypted records over an isolated real TCP listener.
import Foundation
import Darwin
@preconcurrency import Network

@MainActor final class InterchangeTcpServer {
  let profile: SessionProfile
  init(profile: SessionProfile = .standard) { self.profile = profile }
  private var listener: NWListener?
  private var portReady: CheckedContinuation<UInt16, Error>?
  private var incoming: NWConnection?
  private var accepted: CheckedContinuation<NWConnection, Error>?
  func listen() async throws -> UInt16 {
    let server = try NWListener(using: LanTcpTransport.parameters(), on: .any)
    server.service = NWListener.Service(
      name: "aniCe-" + UUID().uuidString.lowercased(),
      type: profile == .bulkProbe ? "_anicebulk._tcp" : "_anice._tcp", txtRecord: NWTXTRecord(["v": profile == .lanTransfer ? "2" : "1"]))
    listener = server
    return try await withCheckedThrowingContinuation { continuation in
      portReady = continuation
      server.stateUpdateHandler = { [weak self] state in
        Task { @MainActor in
          guard let self, let ready = self.portReady else { return }
          switch state {
          case .ready:
            self.portReady = nil
            if let port = self.listener?.port {
              ready.resume(returning: port.rawValue)
            } else {
              ready.resume(throwing: SessionFailure.state)
            }
          case .failed(let error), .waiting(let error):
            self.portReady = nil
            ready.resume(throwing: error)
          default: break
          }
        }
      }
      server.newConnectionHandler = { [weak self] connection in
        Task { @MainActor in
          guard let self, self.incoming == nil else {
            connection.cancel()
            return
          }
          self.incoming = connection
          self.accepted?.resume(returning: connection)
          self.accepted = nil
        }
      }
      server.start(queue: DispatchQueue(label: "aniCe isolated TCP listener"))
    }
  }
  func accept() async throws -> InterchangeTcpPeer {
    let connection: NWConnection
    if let incoming {
      connection = incoming
    } else {
      connection = try await withCheckedThrowingContinuation { accepted = $0 }
    }
    let peer = InterchangeTcpPeer(connection, profile: profile)
    try await peer.start()
    return peer
  }
  func close() {
    listener?.cancel()
    incoming?.cancel()
    listener = nil
  }
}

actor InterchangeTcpPeer {
  private let transport: LanTcpTransport
  private var slot: Data?
  private var waiter: CheckedContinuation<Data, Error>?
  private var consumed: CheckedContinuation<Void, Error>?
  private var failure: Error?
  private(set) var socketSendSeconds = 0.0
  init(_ socket: NWConnection, profile: SessionProfile = .standard) { transport = LanTcpTransport(socket, profile: profile) }
  func start() async throws {
    await transport.start(deliver: { [weak self] bytes in
      guard let self else { throw SessionFailure.cancelled }
      try await self.offer(bytes)
    }, ended: { [weak self] error in Task { await self?.failed(error) } })
  }
  private func offer(_ bytes: Data) async throws {
    if let failure { throw failure }
    if let waiter {
      self.waiter = nil
      waiter.resume(returning: bytes)
      return
    }
    guard slot == nil else { throw SessionFailure.state }
    slot = bytes
    try await withCheckedThrowingContinuation { consumed = $0 }
  }
  private func failed(_ error: Error) {
    guard failure == nil else { return }
    failure = error
    slot = nil
    waiter?.resume(throwing: error)
    waiter = nil
    consumed?.resume(throwing: error)
    consumed = nil
  }
  func capacity(_ size: Int) async -> Bool { await transport.capacity(size) }
  func send(_ bytes: Data) async throws {
    let started = ProcessInfo.processInfo.systemUptime
    defer { socketSendSeconds += ProcessInfo.processInfo.systemUptime - started }
    try await transport.submit(bytes)
  }
  func receive() async throws -> Data {
    if let failure { throw failure }
    if let slot {
      self.slot = nil
      consumed?.resume()
      consumed = nil
      return slot
    }
    guard waiter == nil else { throw SessionFailure.state }
    return try await withCheckedThrowingContinuation { waiter = $0 }
  }
  func close() async {
    failed(SessionFailure.cancelled)
    await transport.close()
  }
}

// Benchmark traffic is isolated from application features and retains production session validation.
actor LanBenchmarkState {
  let total: Int
  let window: Int
  let chunkBytes: Int
  private var received = 0
  private var acknowledged = 0
  private var admitted = 0
  private var pendingAck: Int?
  private var version = 0
  private var waiters = [CheckedContinuation<Void, Never>]()
  private var failure: Error?
  init(total: Int, window: Int, chunkBytes: Int = 3072) { self.total = total; self.window = window; self.chunkBytes = chunkBytes }
  func changed() {
    version += 1
    let pending = waiters
    waiters.removeAll()
    pending.forEach { $0.resume() }
  }
  func failed(_ error: Error) { if failure == nil { failure = error }; changed() }
  func snapshot() throws -> (Int, Int, Int) {
    if let failure { throw failure }
    return (version, received, acknowledged)
  }
  func wait(_ previous: Int) async {
    if version != previous { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func handle(_ bytes: Data) {
    do {
      guard let kind = bytes.first, bytes.count >= 5 else { throw SessionFailure.malformed }
      let index = Int(bytes.dropFirst().prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
      if kind == 0x42 {
        guard index == received, received < total,
          bytes.count == 5 + min(chunkBytes, total - received),
          bytes.dropFirst(5).allSatisfy({ $0 == UInt8((index / chunkBytes) % 251) })
        else { throw SessionFailure.state }
        received += bytes.count - 5
        if received == total || (received / chunkBytes) % min(16, window / 2) == 0 { pendingAck = received }
      } else if kind == 0x41 {
        guard bytes.count == 5, index > acknowledged, index <= admitted,
          index == total || index % chunkBytes == 0 else { throw SessionFailure.state }
        acknowledged = index
      } else { throw SessionFailure.unsupportedProfile }
      changed()
    } catch { failed(error) }
  }
  func admit(_ end: Int) { admitted = end }
  func takeAck() -> Data? {
    guard let pendingAck else { return nil }
    self.pendingAck = nil
    return Data([0x41]) + SessionRecordCodec.integer(UInt64(pendingAck), bytes: 4)
  }
}

func benchmarkSelfCheck() async throws {
  let positive = LanBenchmarkState(total: 3074, window: 32)
  await positive.handle(Data([0x42, 0, 0, 0, 0]) + Data(repeating: 0, count: 3072))
  await positive.handle(Data([0x42, 0, 0, 12, 0, 1, 1]))
  guard try await positive.snapshot().1 == 3074,
    await positive.takeAck() == Data([0x41, 0, 0, 12, 2]) else { throw SessionFailure.state }
  await positive.admit(3074)
  await positive.handle(Data([0x41, 0, 0, 12, 2]))
  guard try await positive.snapshot().2 == 3074 else { throw SessionFailure.state }
  let invalid = [Data(), Data([0x42, 0, 0]), Data([0x42, 0, 0, 0, 1, 0, 0]),
    Data([0x42, 0, 0, 0, 0, 1, 1]), Data([0x42, 0, 0, 0, 0, 0]), Data([0x41, 0, 0, 0, 2])]
  guard invalid.count >= 6 else { throw SessionFailure.state }
  for bytes in invalid {
    let state = LanBenchmarkState(total: 2, window: 32)
    await state.handle(bytes)
    do { _ = try await state.snapshot(); throw SessionFailure.authentication }
    catch SessionFailure.malformed {} catch SessionFailure.state {}
  }
  await positive.handle(Data([0x41, 0, 0, 12, 2]))
  do { _ = try await positive.snapshot(); throw SessionFailure.authentication }
  catch SessionFailure.state {}
}

private actor BenchmarkWriter {
  let engine: SessionConnection
  let state: LanBenchmarkState
  private var busy = false
  private var waiter: CheckedContinuation<Void, Never>?
  init(engine: SessionConnection, state: LanBenchmarkState) { self.engine = engine; self.state = state }
  func send(_ bytes: Data) async throws {
    if busy {
      guard waiter == nil else { throw SessionFailure.state }
      await withCheckedContinuation { waiter = $0 }
    } else { busy = true }
    defer {
      if let waiter { self.waiter = nil; waiter.resume() } else { busy = false }
    }
    try Task.checkCancellation()
    while true {
      let previous = try await state.snapshot().0
      guard await engine.applicationAvailable else { await state.wait(previous); continue }
      do { try await engine.sendData(bytes); return }
      catch is SessionBackpressure { await state.wait(previous) }
    }
  }
}

private func benchmarkRun(engine: SessionConnection, tcp: InterchangeTcpPeer,
  state: LanBenchmarkState) async throws -> [String: Any] {
  let writer = BenchmarkWriter(engine: engine, state: state)
  let receiver = Task {
    do {
      while !Task.isCancelled {
        try await engine.receive(tcp.receive())
        if await engine.isClosed { await state.changed(); break }
      }
    } catch { await state.failed(error) }
  }
  let replies = Task {
    do {
      while !Task.isCancelled {
        let previous = try await state.snapshot().0
        if let ack = await state.takeAck() { try await writer.send(ack) }
        else { await state.wait(previous) }
      }
    } catch { await state.failed(error) }
  }
  defer { receiver.cancel(); replies.cancel(); Task { await state.changed() } }
  var before = rusage()
  getrusage(RUSAGE_SELF, &before)
  let receiveStart = ProcessInfo.processInfo.systemUptime
  while true {
    let (version, received, _) = try await state.snapshot()
    if received == state.total { break }
    await state.wait(version)
  }
  let receiveSeconds = ProcessInfo.processInfo.systemUptime - receiveStart
  FileHandle.standardError.write(Data("LAN benchmark: received \(state.total) bytes in \(receiveSeconds) seconds; starting send\n".utf8))
  let sendStart = ProcessInfo.processInfo.systemUptime
  let socketStart = await tcp.socketSendSeconds
  var submissionSeconds = 0.0
  var sent = 0
  while sent < state.total {
    let (version, _, acknowledged) = try await state.snapshot()
    if sent - acknowledged >= state.window * state.chunkBytes { await state.wait(version); continue }
    let count = min(state.chunkBytes, state.total - sent)
    let chunk = Data([0x42]) + SessionRecordCodec.integer(UInt64(sent), bytes: 4)
      + Data(repeating: UInt8((sent / state.chunkBytes) % 251), count: count)
    await state.admit(sent + count)
    let submissionStart = ProcessInfo.processInfo.systemUptime
    try await writer.send(chunk)
    submissionSeconds += ProcessInfo.processInfo.systemUptime - submissionStart
    sent += count
  }
  while true {
    let (version, _, acknowledged) = try await state.snapshot()
    if acknowledged == state.total { break }
    await state.wait(version)
  }
  let sendSeconds = ProcessInfo.processInfo.systemUptime - sendStart
  let socketSeconds = await tcp.socketSendSeconds - socketStart
  while !(await engine.isClosed) {
    let version = try await state.snapshot().0
    if await engine.isClosed { break }
    await state.wait(version)
  }
  var after = rusage()
  getrusage(RUSAGE_SELF, &after)
  let cpuSeconds = Double(after.ru_utime.tv_sec - before.ru_utime.tv_sec
    + after.ru_stime.tv_sec - before.ru_stime.tv_sec)
    + Double(after.ru_utime.tv_usec - before.ru_utime.tv_usec
      + after.ru_stime.tv_usec - before.ru_stime.tv_usec) / 1_000_000
  return ["bytes": state.total, "window": state.window,
    "macSocketSendSeconds": socketSeconds, "macSubmissionSeconds": submissionSeconds,
    "macCpuSeconds": cpuSeconds, "macMaxResidentBytes": after.ru_maxrss,
    "macReceiveMiBs": Double(state.total) / 1048576 / receiveSeconds,
    "macSendMiBs": Double(state.total) / 1048576 / sendSeconds]
}

@MainActor func tcpInterchange(identity: IdentityService) async throws {
  try await benchmarkSelfCheck()
  let profile: SessionProfile = CommandLine.arguments.contains("--bulk-probe") ? .bulkProbe : CommandLine.arguments.contains("--lan-transfer") ? .lanTransfer : .standard
  let server = InterchangeTcpServer(profile: profile)
  defer { server.close() }
  let port = try await server.listen()
  let local = try await identity.publicIdentity()
  try emit([
    "identity": JSONSerialization.jsonObject(with: JSONEncoder().encode(local)), "port": port,
    "cleanupNamespace": namespace,
  ])
  let bootstrap = try input()
  let peer = try DeviceIdentity.decode(
    JSONSerialization.data(withJSONObject: bootstrap["identity"] as Any))
  let tcp = try await server.accept()
  // Discovery waiting is outside the connected peer's thirty-second handshake deadline.
  let handshake = try SessionHandshakeEngine(
    local: local, responder: true, trusted: { [peer] },
    currentIdentity: { try await identity.publicIdentity() },
    signer: { try await identity.sign(message: $0) }, selectedPeer: peer)
  defer { Task { await tcp.close() } }
  let reply = InterchangeMailbox()
  let benchmarkMiB = bootstrap["benchmarkMiB"] as? Int ?? 0
  let window = bootstrap["window"] as? Int ?? 32
  guard (bootstrap["profile"] as? String ?? "standard") == (profile == .standard ? "standard" : profile == .lanTransfer ? "lan-transfer" : "bulk-probe") else { throw SessionFailure.unsupportedProfile }
  guard [0, 4, 16, 100, 1024].contains(benchmarkMiB), (profile == .standard ? [32, 64] : [4, 8]).contains(window) else { throw SessionFailure.malformed }
  let benchmark = LanBenchmarkState(total: benchmarkMiB * 1048576, window: window, chunkBytes: profile == .standard ? 3072 : profile == .lanTransfer ? 131072 : profile.maximumPlaintext - 5)
  let expected = Data((0..<4000).map { UInt8($0 % 128) })
  let engine = SessionConnection(
    handshake: handshake, responder: true,
    capacity: { await tcp.capacity($0) }, submit: { try await tcp.send($0) },
    data: { bytes in
      if bytes.count == 4000 { await reply.put(bytes) } else { await benchmark.handle(bytes) }
    }, secured: {}, controls: true,
    changed: { Task { await benchmark.changed() } }, profile: profile)
  try await engine.start()
  for _ in 0..<5 { try await engine.receive(tcp.receive()) }
  // Five incoming envelopes are message 1, message 3, ready, HELLO and application data.
  guard await reply.take() == expected, await engine.controlSupport == true else {
    throw SessionFailure.state
  }
  try await engine.sendData(Data(expected.reversed()))
  if benchmarkMiB != 0 {
    FileHandle.standardError.write(Data("LAN benchmark: authenticated conformance complete; starting DATA\n".utf8))
    let metrics = try await benchmarkRun(engine: engine, tcp: tcp, state: benchmark)
    try emit(["benchmark": metrics])
    while !(await engine.isClosed) { try await engine.receive(tcp.receive()) }
  } else { try await engine.receive(tcp.receive()) }
  guard await engine.closedByPeer, await engine.isClosed else { throw SessionFailure.state }
  await engine.close()
  guard try await identity.publicIdentity() == local else { throw SessionFailure.state }
}
