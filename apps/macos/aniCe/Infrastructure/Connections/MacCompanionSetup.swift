// SPDX-License-Identifier: GPL-3.0-or-later
// Temporarily exposes generic BLE availability for a foreground, authenticated companion enrollment.
import Foundation

struct CompanionSetupMessage: Equatable {
  let kind: Int64
  var available = false
  var seconds: Int64 = 0
  static let tag = "aniCe companion setup"
  func encode() throws -> Data {
    let fields: [SessionCBOR]
    switch kind {
    case 1: fields = [.integer(1)]
    case 2:
      guard seconds == 0 || seconds == 60 else { throw SessionFailure.malformed }
      fields = [.integer(seconds)]
    case 3: fields = [.bool(available)]
    default: throw SessionFailure.malformed
    }
    return try SessionCbor.encode(.array([.text(Self.tag), .integer(1), .integer(kind), .array(fields)]),
      maximumBytes: 128)
  }
  static func decode(_ bytes: Data) throws -> Self? {
    guard bytes.count <= 128, case .array(let row) = try SessionCbor.decode(bytes),
      row.first == .text(tag) else { return nil }
    guard row.count == 4, row[1] == .integer(1), case .integer(let kind) = row[2],
      case .array(let fields) = row[3], fields.count == 1 else { throw SessionFailure.malformed }
    switch kind {
    case 1:
      guard fields == [.integer(1)] else { throw SessionFailure.malformed }
      return Self(kind: kind)
    case 2:
      guard case .integer(let seconds) = fields[0], seconds == 0 || seconds == 60 else {
        throw SessionFailure.malformed
      }
      return Self(kind: kind, seconds: seconds)
    case 3:
      guard case .bool(let available) = fields[0] else { throw SessionFailure.malformed }
      return Self(kind: kind, available: available)
    default: throw SessionFailure.malformed
    }
  }
}

@MainActor final class MacCompanionSetup: FeatureHandler {
  private final class Link {
    let channel: any SecuredChannel
    var sent = false
    var sending = false
    var capacityPending = false
    var capable = false
    init(_ channel: any SecuredChannel) { self.channel = channel }
  }
  private let advertising: (@MainActor (Bool) -> Bool)
  private let wait: @Sendable () async throws -> Void
  private var link: Link?
  private var expiry: Task<Void, Never>?
  private var window: String?
  init(advertising: @escaping @MainActor (Bool) -> Bool,
    wait: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(60)) }) {
    self.advertising = advertising
    self.wait = wait
  }
  func available(_ channel: any SecuredChannel) {
    guard channel.descriptor.transport == "ble" else { return }
    finishWindow()
    let next = Link(channel)
    link = next
    sendCapability(next)
  }
  func retired(_ descriptor: ChannelDescriptor) {
    guard link?.channel.descriptor.instance == descriptor.instance else { return }
    finishWindow()
    link = nil
  }
  func capacityAvailable(_ descriptor: ChannelDescriptor) {
    if let current = link, current.channel.descriptor.instance == descriptor.instance {
      if current.sending { current.capacityPending = true } else { sendCapability(current) }
    }
  }
  private func sendCapability(_ current: Link) {
    guard link === current, !current.sent, !current.sending else { return }
    current.sending = true
    current.capacityPending = false
    Task {
      var backpressured = false
      defer {
        current.sending = false
        if backpressured && current.capacityPending { sendCapability(current) }
      }
      do {
        try await current.channel.sendData(CompanionSetupMessage(kind: 1).encode())
        if link === current { current.sent = true }
      } catch is SessionBackpressure { backpressured = true }
      catch {}
    }
  }
  func handle(_ bytes: Data, on descriptor: ChannelDescriptor) async -> DataHandling {
    do {
      guard let message = try CompanionSetupMessage.decode(bytes) else { return .unrecognized }
      guard descriptor.transport == "ble", descriptor.peer.platform == "android",
        let current = link, current.channel.descriptor == descriptor else { return .discarded }
      if message.kind == 1 { current.capable = true; return .handled }
      guard message.kind == 2, current.capable else { return .discarded }
      let available: Bool
      if message.seconds == 0 {
        finishWindow()
        available = true
      } else if window == descriptor.instance { available = true }
      else {
        available = advertising(true)
        if available {
          window = descriptor.instance
          let wait = self.wait
          expiry = Task {
            do { try await wait() } catch { return }
            guard !Task.isCancelled, self.window == descriptor.instance else { return }
            self.finishWindow()
          }
        }
      }
      try await current.channel.sendData(CompanionSetupMessage(kind: 3, available: available).encode())
      return .handled
    } catch { return .discarded }
  }
  private func finishWindow() {
    expiry?.cancel()
    expiry = nil
    if window != nil { _ = advertising(false) }
    window = nil
  }
}
