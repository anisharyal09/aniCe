// SPDX-License-Identifier: GPL-3.0-or-later
// Exchanges native EDHOC and bounded encrypted records over an isolated real TCP listener.
import Foundation
@preconcurrency import Network

@MainActor final class InterchangeTcpServer {
  private var listener: NWListener?
  private var portReady: CheckedContinuation<UInt16, Error>?
  private var incoming: NWConnection?
  private var accepted: CheckedContinuation<NWConnection, Error>?
  func listen() async throws -> UInt16 {
    let server = try NWListener(using: LanTcpTransport.parameters(), on: .any)
    server.service = NWListener.Service(
      name: "aniCe-" + UUID().uuidString.lowercased(),
      type: "_anice._tcp", txtRecord: NWTXTRecord(["v": "1"]))
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
    let peer = InterchangeTcpPeer(connection)
    try await peer.start()
    return peer
  }
  func close() {
    listener?.cancel()
    incoming?.cancel()
    listener = nil
  }
}

@MainActor final class InterchangeTcpPeer {
  private let socket: NWConnection
  private var framing = LanFraming()
  private var buffered = [Data]()
  private var ready: CheckedContinuation<Void, Error>?
  init(_ socket: NWConnection) { self.socket = socket }
  func start() async throws {
    try await withCheckedThrowingContinuation { continuation in
      ready = continuation
      socket.stateUpdateHandler = { [weak self] state in
        Task { @MainActor in
          guard let self, let ready = self.ready else { return }
          switch state {
          case .ready:
            self.ready = nil
            ready.resume()
          case .failed(let error), .waiting(let error):
            self.ready = nil
            ready.resume(throwing: error)
          default: break
          }
        }
      }
      socket.start(queue: DispatchQueue(label: "aniCe isolated TCP peer"))
    }
  }
  func send(_ bytes: Data) async throws {
    let frame = try LanFraming.encode(bytes)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      socket.send(
        content: frame,
        completion: .contentProcessed { error in
          if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        })
    }
  }
  func receive() async throws -> Data {
    while buffered.isEmpty {
      let bytes: Data = try await withCheckedThrowingContinuation { continuation in
        socket.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
          data, _, complete, error in
          if let error {
            continuation.resume(throwing: error)
          } else if let data, !data.isEmpty {
            continuation.resume(returning: data)
          } else if complete {
            continuation.resume(throwing: SessionFailure.cancelled)
          } else {
            continuation.resume(returning: Data())
          }
        }
      }
      for byte in bytes {
        if let envelope = try framing.feed(byte) {
          guard buffered.count < 8 else { throw SessionFailure.state }
          buffered.append(envelope)
        }
      }
    }
    return buffered.removeFirst()
  }
  func close() { socket.cancel() }
}

@MainActor func tcpInterchange(identity: IdentityService) async throws {
  let server = InterchangeTcpServer()
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
  let handshake = try SessionHandshakeEngine(
    local: local, responder: true, trusted: { [peer] },
    currentIdentity: { try await identity.publicIdentity() },
    signer: { try await identity.sign(message: $0) }, selectedPeer: peer)
  let tcp = try await server.accept()
  defer { tcp.close() }
  let reply = InterchangeMailbox()
  let expected = Data((0..<4000).map { UInt8($0 % 128) })
  let engine = SessionConnection(
    handshake: handshake, responder: true,
    capacity: { _ in true }, submit: { try await tcp.send($0) },
    data: { await reply.put($0) }, secured: {}, controls: true)
  try await engine.start()
  for _ in 0..<5 { try await engine.receive(tcp.receive()) }
  // Five incoming envelopes are message 1, message 3, ready, HELLO and application data.
  guard await reply.take() == expected, await engine.controlSupport == true else {
    throw SessionFailure.state
  }
  try await engine.sendData(Data(expected.reversed()))
  try await engine.receive(tcp.receive())
  guard await engine.closedByPeer, await engine.isClosed else { throw SessionFailure.state }
  await engine.close()
  guard try await identity.publicIdentity() == local else { throw SessionFailure.state }
}
