// SPDX-License-Identifier: GPL-3.0-or-later
// Owns bounded native Mac playback for reverse audio; source PCM is never persisted.
import AVFoundation
import Foundation

enum MacPhoneAudioOutputError: Error, Equatable { case unavailable }

enum PhoneAudioOutputAdmission: Equatable { case accepted, unavailable }

struct PhoneAudioOutputDiagnostics: Equatable, Sendable {
  let queuedFrames: Int
  let resyncs: Int
  let unavailableDrops: Int
  var scheduledPackets: Int64? = nil
  var playedBackCallbacks: Int64? = nil
  var emptyPendingTransitions: Int64? = nil
  var completionMaximumMicros: Int64? = nil
}

protocol PhoneAudioOutput: Actor {
  func prepare() async throws
  func offer(_ pcm: Data) async -> PhoneAudioOutputAdmission
  func stop()
  func discardPending() -> PhoneAudioOutputAdmission
  var queuedFrames: Int { get }
  var diagnostics: PhoneAudioOutputDiagnostics { get }
}

extension PhoneAudioOutput {
  func discardPending() -> PhoneAudioOutputAdmission { .accepted }
  var diagnostics: PhoneAudioOutputDiagnostics {
    PhoneAudioOutputDiagnostics(queuedFrames: queuedFrames, resyncs: 0, unavailableDrops: 0)
  }
}

actor MacPhoneAudioOutput: PhoneAudioOutput {
  private let diagnosticsEnabled: Bool
  private static let maximumPending = 6
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private var generation = 0
  private var configurationGeneration = 0
  private var pending = 0
  private var prepared = false
  private var attached = false
  private var observer: NSObjectProtocol?
  private(set) var resyncs = 0
  private(set) var unavailableDrops = 0
  private let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
  private var scheduledPackets: Int64 = 0
  private var playedBackCallbacks: Int64 = 0
  private var emptyPendingTransitions: Int64 = 0
  private var completionMaximumMicros: Int64?
  private var diagnosticStartedAt: UInt64?

  init(diagnosticsEnabled: Bool = false) { self.diagnosticsEnabled = diagnosticsEnabled }

  func prepare() throws {
    stop()
    engine.attach(player)
    attached = true
    engine.connect(player, to: engine.mainMixerNode, format: format)
    do {
      try engine.start()
      guard engine.isRunning else { throw MacPhoneAudioOutputError.unavailable }
      player.play()
      prepared = true
      resyncs = 0
      unavailableDrops = 0
      scheduledPackets = 0
      playedBackCallbacks = 0
      emptyPendingTransitions = 0
      completionMaximumMicros = nil
      diagnosticStartedAt = diagnosticsEnabled ? DispatchTime.now().uptimeNanoseconds : nil
      let configurationEpoch = configurationGeneration
      observer = NotificationCenter.default.addObserver(
        forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
      ) { [weak self] _ in
        Task { await self?.configurationChanged(configurationEpoch) }
      }
    } catch {
      stop()
      throw MacPhoneAudioOutputError.unavailable
    }
  }

  /** A full native budget discards queued older PCM so playback resumes at the newest packet.
   * Completion means rendered-to-device accounting, not measured source-to-ear latency. */
  func offer(_ pcm: Data) -> PhoneAudioOutputAdmission {
    guard prepared, engine.isRunning else {
      unavailableDrops += 1
      stop()
      return .unavailable
    }
    guard pcm.count == PrivateListeningMessage.pcmBytes,
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960),
      let channels = buffer.floatChannelData else {
      unavailableDrops += 1
      return .unavailable
    }
    buffer.frameLength = 960
    pcm.withUnsafeBytes { raw in
      let bytes = raw.bindMemory(to: UInt8.self)
      for frame in 0..<960 {
        for channel in 0..<2 {
          let offset = frame * 4 + channel * 2
          let sample = Int16(bitPattern: UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8)
          channels[channel][frame] = Float(sample) / 32768
        }
      }
    }
    if pending >= Self.maximumPending {
      player.stop()
      pending = 0
      generation += 1
      player.play()
      resyncs += 1
    }
    let epoch = generation
    let scheduledAt: UInt64?
    if let diagnosticStartedAt {
      let time = DispatchTime.now().uptimeNanoseconds
      if time - diagnosticStartedAt <= 600_000_000_000 {
        scheduledAt = time
        scheduledPackets += 1
      } else {
        self.diagnosticStartedAt = nil
        scheduledAt = nil
      }
    } else { scheduledAt = nil }
    pending += 1
    player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
      Task { await self?.completed(epoch, scheduledAt: scheduledAt) }
    }
    return .accepted
  }

  private func completed(_ epoch: Int, scheduledAt: UInt64?) {
    guard epoch == generation else { return }
    if let scheduledAt {
      playedBackCallbacks += 1
      if pending == 1 { emptyPendingTransitions += 1 }
      let duration = Int64((DispatchTime.now().uptimeNanoseconds - scheduledAt) / 1000)
      completionMaximumMicros = max(completionMaximumMicros ?? 0, duration)
    }
    pending = max(0, pending - 1)
  }

  /// Retained-channel renewal discards old output without acquiring a new device or permission.
  func discardPending() -> PhoneAudioOutputAdmission {
    guard prepared, engine.isRunning else { return .unavailable }
    generation += 1
    pending = 0
    player.stop()
    player.play()
    return .accepted
  }

  /// Device changes and routed-output loss stop playback until the owner explicitly prepares again.
  private func configurationChanged(_ epoch: Int) {
    guard prepared, epoch == configurationGeneration else { return }
    stop()
  }

  func stop() {
    generation += 1
    configurationGeneration += 1
    prepared = false
    pending = 0
    if let observer {
      NotificationCenter.default.removeObserver(observer)
      self.observer = nil
    }
    player.stop()
    engine.stop()
    if attached {
      engine.detach(player)
      attached = false
    }
  }

  var queuedFrames: Int { pending * 960 }
  var diagnostics: PhoneAudioOutputDiagnostics {
    PhoneAudioOutputDiagnostics(queuedFrames: queuedFrames, resyncs: resyncs,
      unavailableDrops: unavailableDrops,
      scheduledPackets: diagnosticsEnabled ? scheduledPackets : nil,
      playedBackCallbacks: diagnosticsEnabled ? playedBackCallbacks : nil,
      emptyPendingTransitions: diagnosticsEnabled ? emptyPendingTransitions : nil,
      completionMaximumMicros: completionMaximumMicros)
  }
}
