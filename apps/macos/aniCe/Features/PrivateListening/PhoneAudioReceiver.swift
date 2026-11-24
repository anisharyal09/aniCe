// SPDX-License-Identifier: GPL-3.0-or-later
// Fences reverse PCM against stream retirement, credential changes and unavailable Mac output.
import Foundation

@MainActor final class PhoneAudioReceiver {
  enum Reception: Equatable {
    case accepted, duplicate, unbound, staleStream, outputUnavailable
  }

  private let output: any PhoneAudioOutput
  private(set) var stream: String?
  private var descriptor: ChannelDescriptor?
  private var generation = 0
  private var prepared = false
  private var preparation: Task<Void, Error>?
  private var cleanup: Task<Void, Never>?
  private var lastSequence: Int64 = 0
  private(set) var acceptedPackets = 0
  private(set) var gapPackets = 0
  private(set) var unavailablePackets = 0

  init(output: any PhoneAudioOutput = MacPhoneAudioOutput()) {
    self.output = output
  }

  /// Reverse Start binds exactly one live stream to the full channel credential.
  /// A duplicate Start for the same operation is idempotent; a different stream is rejected.
  func bind(_ message: PrivateListeningMessage, on descriptor: ChannelDescriptor) async throws -> Bool {
    try Task.checkCancellation()
    guard message.kind == 1 else { return false }
    guard cleanup == nil else { return false }
    if let stream {
      return prepared && stream == message.text(0) && matches(descriptor)
    }
    generation += 1
    let token = generation
    stream = message.text(0)
    self.descriptor = descriptor
    prepared = false
    let output = output
    let work = Task { try await output.prepare() }
    preparation = work
    do { try await work.value }
    catch {
      if token == generation { preparation = nil; invalidate() }
      throw error
    }
    guard token == generation, stream == message.text(0), matches(descriptor),
      !Task.isCancelled else {
      if token == generation { invalidate() }
      return false
    }
    preparation = nil
    prepared = true
    lastSequence = 0
    acceptedPackets = 0
    gapPackets = 0
    unavailablePackets = 0
    return true
  }

  func receive(_ message: PrivateListeningMessage, on descriptor: ChannelDescriptor) async -> Reception {
    guard prepared, let stream, matches(descriptor) else { return .unbound }
    guard message.kind == 3, message.text(0) == stream else { return .staleStream }
    let sequence = message.number(1)
    guard sequence > lastSequence else { return .duplicate }
    if lastSequence > 0, sequence != lastSequence + 1 { gapPackets += 1 }
    lastSequence = sequence
    let token = generation
    let admission = await output.offer(message.bytes(3))
    guard token == generation, self.stream == stream, matches(descriptor) else { return .unbound }
    guard admission == .accepted else {
      unavailablePackets += 1
      await stop()
      return .outputUnavailable
    }
    acceptedPackets += 1
    return .accepted
  }

  func stop() async {
    invalidate()
    await cleanup?.value
  }

  /// Synchronous admission retirement precedes any asynchronous native teardown.
  func invalidate() {
    generation += 1
    stream = nil
    descriptor = nil
    prepared = false
    lastSequence = 0
    guard cleanup == nil else { return }
    let pending = preparation
    preparation = nil
    pending?.cancel()
    let output = output
    cleanup = Task { [weak self] in
      _ = await pending?.result
      await output.stop()
      self?.cleanup = nil
    }
  }

  func resumeCurrentAudio() async -> Bool {
    guard prepared, stream != nil else { return false }
    let token = generation
    let admission = await output.discardPending()
    return token == generation && prepared && admission == .accepted
  }

  func diagnostics() async -> PhoneAudioOutputDiagnostics { await output.diagnostics }

  private func matches(_ other: ChannelDescriptor) -> Bool {
    guard let descriptor else { return false }
    return descriptor == other && descriptor.peer.publicKey == other.peer.publicKey &&
      descriptor.peer.algorithm == other.peer.algorithm &&
      descriptor.peer.identitySchemaVersion == other.peer.identitySchemaVersion &&
      descriptor.peer.platform == other.peer.platform
  }
}
