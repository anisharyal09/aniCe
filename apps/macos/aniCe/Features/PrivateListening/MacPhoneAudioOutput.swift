// SPDX-License-Identifier: GPL-3.0-or-later
// Owns bounded native Mac playback for reverse audio; source PCM is never persisted.
import AVFoundation
import Foundation
import os

internal final class PhoneAudioPlaybackCounter: @unchecked Sendable {
  private struct State {
    var epoch = 0
    var pending = 0
    var scheduledPackets: Int64 = 0
    var playedBackCallbacks: Int64 = 0
    var emptyPendingTransitions: Int64 = 0
    var completionMaximumMicros: Int64?
    var underrun = false
  }

  private let lock = OSAllocatedUnfairLock(initialState: State())

  var epoch: Int { lock.withLock { $0.epoch } }
  var pending: Int { lock.withLock { $0.pending } }

  func resetAll() {
    lock.withLock { state in
      state.epoch &+= 1
      state.pending = 0
      state.scheduledPackets = 0
      state.playedBackCallbacks = 0
      state.emptyPendingTransitions = 0
      state.completionMaximumMicros = nil
      state.underrun = false
    }
  }

  func resetQueue() -> Int {
    lock.withLock { state in
      state.epoch &+= 1
      state.pending = 0
      state.underrun = false
      return state.epoch
    }
  }

  func consumeUnderrun() -> (underrun: Bool, pending: Int) {
    lock.withLock { state in
      let value = state.underrun
      state.underrun = false
      return (value, state.pending)
    }
  }

  func enqueue(recordDiagnostics: Bool) -> Int {
    lock.withLock { state in
      state.pending += 1
      if recordDiagnostics { state.scheduledPackets += 1 }
      return state.epoch
    }
  }

  func complete(epoch: Int, scheduledAt: UInt64?) {
    lock.withLock { state in
      guard state.epoch == epoch else { return }
      if let scheduledAt {
        state.playedBackCallbacks += 1
        if state.pending == 1 { state.emptyPendingTransitions += 1 }
        let duration = Int64((DispatchTime.now().uptimeNanoseconds - scheduledAt) / 1000)
        state.completionMaximumMicros = max(state.completionMaximumMicros ?? 0, duration)
      }
      state.pending = max(0, state.pending - 1)
      if state.pending == 0 { state.underrun = true }
    }
  }

  func snapshot(diagnosticsEnabled: Bool, unavailableDrops: Int, resyncs: Int) -> PhoneAudioOutputDiagnostics {
    lock.withLock { state in
      PhoneAudioOutputDiagnostics(
        queuedFrames: state.pending * 960,
        resyncs: resyncs,
        unavailableDrops: unavailableDrops,
        scheduledPackets: diagnosticsEnabled ? state.scheduledPackets : nil,
        playedBackCallbacks: diagnosticsEnabled ? state.playedBackCallbacks : nil,
        emptyPendingTransitions: diagnosticsEnabled ? state.emptyPendingTransitions : nil,
        completionMaximumMicros: state.completionMaximumMicros
      )
    }
  }
}

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
  private static let prefillPackets = 3
  private static let fadeFrames = 240
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let counter = PhoneAudioPlaybackCounter()
  private var configurationGeneration = 0
  private var priming = false
  private var needsFadeIn = false
  private var prefillTask: Task<Void, Never>?
  private var prepared = false
  private var attached = false
  private var observer: NSObjectProtocol?
  private(set) var resyncs = 0
  private(set) var unavailableDrops = 0
  private let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
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
      counter.resetAll()
      priming = true
      needsFadeIn = true
      prepared = true
      resyncs = 0
      unavailableDrops = 0
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

  /** A full native budget discards queued older PCM so playback resumes cleanly from a bounded prefill.
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
    let underrunState = counter.consumeUnderrun()
    if !priming && underrunState.underrun && underrunState.pending == 0 {
      player.stop()
      _ = counter.resetQueue()
      priming = true
      needsFadeIn = true
    } else if counter.pending >= Self.maximumPending {
      prefillTask?.cancel()
      prefillTask = nil
      player.stop()
      _ = counter.resetQueue()
      priming = true
      needsFadeIn = true
      resyncs += 1
    }
    buffer.frameLength = 960
    let fade = needsFadeIn
    needsFadeIn = false
    pcm.withUnsafeBytes { raw in
      let bytes = raw.bindMemory(to: UInt8.self)
      for frame in 0..<960 {
        let gain: Float = fade && frame < Self.fadeFrames ? Float(frame) / Float(Self.fadeFrames) : 1
        for channel in 0..<2 {
          let offset = frame * 4 + channel * 2
          let sample = Int16(bitPattern: UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8)
          channels[channel][frame] = (Float(sample) / 32768) * gain
        }
      }
    }
    let scheduledAt: UInt64?
    if let diagnosticStartedAt {
      let time = DispatchTime.now().uptimeNanoseconds
      if time - diagnosticStartedAt <= 600_000_000_000 {
        scheduledAt = time
      } else {
        self.diagnosticStartedAt = nil
        scheduledAt = nil
      }
    } else { scheduledAt = nil }
    let epoch = counter.enqueue(recordDiagnostics: scheduledAt != nil)
    let counter = self.counter
    player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
      counter.complete(epoch: epoch, scheduledAt: scheduledAt)
    }
    if priming {
      if counter.pending >= Self.prefillPackets {
        startPlayback(for: epoch)
      } else if prefillTask == nil {
        prefillTask = Task { [weak self] in
          do {
            try await Task.sleep(for: .milliseconds(80))
          } catch {
            return
          }
          await self?.flushPrefill(epoch: epoch)
        }
      }
    }
    return .accepted
  }

  private func startPlayback(for epoch: Int) {
    guard prepared, priming, counter.epoch == epoch, counter.pending > 0 else { return }
    prefillTask?.cancel()
    prefillTask = nil
    priming = false
    player.play()
  }

  private func flushPrefill(epoch: Int) {
    guard !Task.isCancelled, counter.epoch == epoch else { return }
    prefillTask = nil
    startPlayback(for: epoch)
  }

  /// Retained-channel renewal discards old output without acquiring a new device or permission.
  func discardPending() -> PhoneAudioOutputAdmission {
    guard prepared, engine.isRunning else { return .unavailable }
    prefillTask?.cancel()
    prefillTask = nil
    _ = counter.resetQueue()
    player.stop()
    priming = true
    needsFadeIn = true
    return .accepted
  }

  /// Device changes and routed-output loss stop playback until the owner explicitly prepares again.
  private func configurationChanged(_ epoch: Int) {
    guard prepared, epoch == configurationGeneration else { return }
    stop()
  }

  func stop() {
    prefillTask?.cancel()
    prefillTask = nil
    configurationGeneration += 1
    prepared = false
    priming = false
    needsFadeIn = false
    _ = counter.resetQueue()
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

  var queuedFrames: Int { counter.pending * 960 }
  var diagnostics: PhoneAudioOutputDiagnostics {
    counter.snapshot(diagnosticsEnabled: diagnosticsEnabled, unavailableDrops: unavailableDrops, resyncs: resyncs)
  }
}
