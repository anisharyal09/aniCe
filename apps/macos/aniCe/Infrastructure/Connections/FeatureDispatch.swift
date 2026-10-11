// SPDX-License-Identifier: GPL-3.0-or-later
// Dispatches application DATA on live authenticated channel instances without owning transport queues.
import Foundation

enum DataHandling { case handled, discarded, unrecognized }
struct ChannelDescriptor: Equatable {
  let instance: String
  let transport: String
  let peer: DeviceIdentity
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.instance == rhs.instance && lhs.transport == rhs.transport && lhs.peer.deviceId == rhs.peer.deviceId && lhs.peer.fingerprint == rhs.peer.fingerprint
  }
}
@MainActor protocol SecuredChannel: AnyObject {
  var descriptor: ChannelDescriptor { get }
  func sendData(_ bytes: Data) async throws
}
@MainActor protocol FeatureHandler: AnyObject {
  func available(_ channel: any SecuredChannel)
  func retired(_ descriptor: ChannelDescriptor)
  func capacityAvailable(_ descriptor: ChannelDescriptor)
  func handle(_ bytes: Data, on descriptor: ChannelDescriptor) -> DataHandling
}
@MainActor final class FeatureDispatch {
  private final class Channel: SecuredChannel {
    let descriptor: ChannelDescriptor
    weak var owner: FeatureDispatch?
    let submit: @MainActor (Data) async throws -> Void
    init(_ descriptor: ChannelDescriptor, owner: FeatureDispatch, submit: @escaping @MainActor (Data) async throws -> Void) { self.descriptor=descriptor; self.owner=owner; self.submit=submit }
    func sendData(_ bytes: Data) async throws {
      guard owner?.channels[descriptor.transport] === self else { throw SessionFailure.cancelled }
      guard bytes.count <= 4000 else { throw SessionFailure.malformed }
      try await submit(bytes)
      guard owner?.channels[descriptor.transport] === self else { throw SessionFailure.cancelled }
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
  func handle(_ bytes: Data, transport: String, instance: String?) -> DataHandling {
    guard let descriptor=channels[transport]?.descriptor, descriptor.instance==instance else { return .discarded }
    for handler in handlers { let result=handler.handle(bytes,on:descriptor); if result != .unrecognized { return result } }
    return .unrecognized
  }
}
