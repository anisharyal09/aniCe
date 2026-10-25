// SPDX-License-Identifier: GPL-3.0-or-later
// Dispatches application DATA on live authenticated channel instances without owning transport queues.
import Foundation

enum DataHandling { case handled, queued, discarded, unrecognized }
struct ChannelDescriptor: Equatable {
  let instance: String
  let transport: String
  let peer: DeviceIdentity
  var maximumDataBytes: Int = 4000
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.maximumDataBytes == rhs.maximumDataBytes && lhs.instance == rhs.instance && lhs.transport == rhs.transport && lhs.peer.deviceId == rhs.peer.deviceId && lhs.peer.fingerprint == rhs.peer.fingerprint
  }
}
@MainActor protocol SecuredChannel: AnyObject {
  var descriptor: ChannelDescriptor { get }
  func sendData(_ bytes: Data) async throws
  // Deferred handlers report activity only after successful handling, never on queue admission.
  func received(_ bytes: Data)
}
extension SecuredChannel { func received(_ bytes: Data) {} }
@MainActor protocol FeatureHandler: AnyObject {
  func available(_ channel: any SecuredChannel)
  func retired(_ descriptor: ChannelDescriptor)
  func capacityAvailable(_ descriptor: ChannelDescriptor)
  func handle(_ bytes: Data, on descriptor: ChannelDescriptor) async -> DataHandling
  func ingest(_ bytes: Data, on descriptor: ChannelDescriptor) async -> DataHandling
  func drain(_ descriptor: ChannelDescriptor) async
}
extension FeatureHandler {
  func ingest(_ bytes: Data, on descriptor: ChannelDescriptor) async -> DataHandling { await handle(bytes, on: descriptor) }
  func drain(_ descriptor: ChannelDescriptor) async {}
}
@MainActor final class FeatureDispatch {
  var applicationActivity: (ChannelDescriptor, Data) -> Void = { _, _ in }
  private final class Channel: SecuredChannel {
    let descriptor: ChannelDescriptor
    weak var owner: FeatureDispatch?
    let submit: @MainActor (Data) async throws -> Void
    init(_ descriptor: ChannelDescriptor, owner: FeatureDispatch, submit: @escaping @MainActor (Data) async throws -> Void) { self.descriptor=descriptor; self.owner=owner; self.submit=submit }
    func received(_ bytes: Data) {
      guard owner?.channels[descriptor.transport] === self else { return }
      owner?.applicationActivity(descriptor, bytes)
    }
    func sendData(_ bytes: Data) async throws {
      guard owner?.channels[descriptor.transport] === self else { throw SessionFailure.cancelled }
      guard bytes.count <= descriptor.maximumDataBytes else { throw SessionFailure.malformed }
      try await submit(bytes)
      guard owner?.channels[descriptor.transport] === self else { throw SessionFailure.cancelled }
      owner?.applicationActivity(descriptor, bytes)
    }
  }
  private var channels: [String:Channel] = [:]
  private var handlers: [any FeatureHandler] = []
  func register(_ handler: any FeatureHandler) { precondition(channels.isEmpty); precondition(!handlers.contains { $0 === handler }); handlers.append(handler) }
  func available(_ descriptor: ChannelDescriptor, send: @escaping @MainActor (Data) async throws -> Void) {
    guard channels[descriptor.transport]?.descriptor != descriptor else { return }
    retired(descriptor.transport)
    let channel=Channel(descriptor,owner:self,submit:send); channels[descriptor.transport]=channel
    for handler in handlers { handler.available(channel) }
  }
  func retired(_ transport: String) { if let old=channels.removeValue(forKey:transport) { for handler in handlers { handler.retired(old.descriptor) } } }
  func capacityAvailable(_ transport: String) { if let channel=channels[transport] { for handler in handlers { handler.capacityAvailable(channel.descriptor) } } }
  func drain(_ transport: String, instance: String?) async {
    guard let descriptor = channels[transport]?.descriptor, descriptor.instance == instance else { return }
    for handler in handlers {
      guard channels[transport]?.descriptor == descriptor else { return }
      await handler.drain(descriptor)
    }
  }
  func handle(_ bytes: Data, transport: String, instance: String?) async -> DataHandling {
    guard let descriptor=channels[transport]?.descriptor, descriptor.instance==instance else { return .discarded }
    for handler in handlers { let result=await handler.ingest(bytes,on:descriptor); guard channels[transport]?.descriptor == descriptor else { return .discarded }; if result == .handled { applicationActivity(descriptor, bytes) }; if result != .unrecognized { return result } }
    return .unrecognized
  }
}
