// SPDX-License-Identifier: GPL-3.0-or-later
// Owns bounded native Mac playback for reverse audio; source PCM is never persisted.
import AVFoundation
import Foundation
import os

internal final class PhoneAudioPlaybackCounter: @unchecked Sendable {
  private struct State {
    var epoch = 0
    var pending = 0
    var emptiedAt: UInt64?
    var scheduledPackets: Int64 = 0
    var renderedCallbacks: Int64 = 0
    var emptyPendingTransitions: Int64 = 0
    var completionMaximumMicros: Int64?
  }

  private let lock = OSAllocatedUnfairLock(initialState: State())

  var epoch: Int { lock.withLock { $0.epoch } }
  var pending: Int { lock.withLock { $0.pending } }

  func backlog(at now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> (pending: Int, shouldRebuffer: Bool) {
    lock.withLock { state in
      // A brief render-queue drain can refill without pausing for another prefill.
      let shouldRebuffer = state.emptiedAt.map { now >= $0 && now - $0 >= 40_000_000 } ?? false
      return (state.pending, shouldRebuffer)
    }
  }

  func resetAll() {
    lock.withLock { state in
      state = State(epoch: state.epoch &+ 1)
    }
  }

  func resetQueue() {
    lock.withLock { state in
      state.epoch &+= 1
      state.pending = 0
      state.emptiedAt = nil
    }
  }

  func enqueue(recordDiagnostics: Bool) -> Int {
    lock.withLock { state in
      state.pending += 1
      state.emptiedAt = nil
      if recordDiagnostics { state.scheduledPackets += 1 }
      return state.epoch
    }
  }

  func complete(epoch: Int, scheduledAt: UInt64?, renderedAt: UInt64 = DispatchTime.now().uptimeNanoseconds) {
    lock.withLock { state in
      guard state.epoch == epoch, state.pending > 0 else { return }
      state.pending -= 1
      if state.pending == 0 { state.emptiedAt = renderedAt }
      if let scheduledAt {
        state.renderedCallbacks += 1
        if state.pending == 0 { state.emptyPendingTransitions += 1 }
        let duration = Int64((renderedAt - scheduledAt) / 1000)
        state.completionMaximumMicros = max(state.completionMaximumMicros ?? 0, duration)
      }
    }
  }

  func snapshot(diagnosticsEnabled: Bool, unavailableDrops: Int, resyncs: Int) -> PhoneAudioOutputDiagnostics {
    lock.withLock { state in
      PhoneAudioOutputDiagnostics(
        queuedFrames: state.pending * 960,
        resyncs: resyncs,
        unavailableDrops: unavailableDrops,
        scheduledPackets: diagnosticsEnabled ? state.scheduledPackets : nil,
        renderedCallbacks: diagnosticsEnabled ? state.renderedCallbacks : nil,
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
  var renderedCallbacks: Int64? = nil
  var emptyPendingTransitions: Int64? = nil
  var completionMaximumMicros: Int64? = nil
}

protocol PhoneAudioOutput: Actor {
  func prepare() async throws
  func offer(_ pcm: Data, afterGap: Bool) async -> PhoneAudioOutputAdmission
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
  private static let maximumPending = 8
  private static let prefillPackets = 3
  private static let fadeFrames = 240
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let counter = PhoneAudioPlaybackCounter()
  private var configurationGeneration = 0
  private var priming = false
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

  /// A full player queue discards older PCM; output-device latency is outside this budget.
  func offer(_ pcm: Data, afterGap: Bool) -> PhoneAudioOutputAdmission {
    guard prepared, engine.isRunning else {
      unavailableDrops += 1
      stop()
      return .unavailable
    }
    guard pcm.count == AudioSharingMessage.pcmBytes,
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960),
      let channels = buffer.floatChannelData else {
      unavailableDrops += 1
      return .unavailable
    }
    let backlog = counter.backlog()
    var pending = backlog.pending
    if pending >= Self.maximumPending {
      resetPlaybackQueue()
      pending = 0
      resyncs += 1
    } else if !priming && backlog.shouldRebuffer {
      player.pause()
      priming = true
    }
    buffer.frameLength = 960
    let fade = afterGap || (priming && pending == 0)
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
    // Device playback latency must not count as queued audio or force resynchronization.
    player.scheduleBuffer(buffer, completionCallbackType: .dataRendered) { _ in
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
    guard prepared, engine.isRunning, priming, counter.epoch == epoch, counter.pending > 0 else { return }
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
    resetPlaybackQueue()
    return .accepted
  }

  private func resetPlaybackQueue() {
    prefillTask?.cancel()
    prefillTask = nil
    counter.resetQueue()
    player.stop()
    priming = true
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
    counter.resetQueue()
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
