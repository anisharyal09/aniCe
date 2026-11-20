// SPDX-License-Identifier: GPL-3.0-or-later
// Owns private Core Audio tap resources and off-callback conversion without changing the system output device.
import AVFAudio
import CoreAudio
import Darwin
import Foundation
import OSLog

enum MacAudioTapError: Error, LocalizedError {
  case native(String, OSStatus)
  case unsupportedFormat
  case unavailable
  case invalidated

  var errorDescription: String? {
    switch self {
    case .native(let operation, let status): "System audio \(operation) failed (\(status))."
    case .unsupportedFormat: "This system audio format is not supported."
    case .unavailable: "System audio capture is not ready."
    case .invalidated: "The audio output or capture format changed. Start listening again."
    }
  }
}

struct MacAudioTapBatch: Sendable {
  let packets: [PrivateListeningCapturedPacket]
  let sourceFrames: Int64
  let queuedFrames: Int64
  let droppedFrames: UInt64
}

// Native listeners retain this allocation independently; the C IOProc borrows it until detachment.
private final class ListeningRingMemory: @unchecked Sendable {
  let pointer: OpaquePointer
  init(capacity: UInt32) throws {
    guard let pointer = AniceListeningRingCreate(capacity) else { throw MacAudioTapError.unavailable }
    self.pointer = pointer
  }
  deinit { AniceListeningRingDestroy(pointer) }
}

private final class ListeningTapResources {
  private struct Listener {
    let object: AudioObjectID
    let address: AudioObjectPropertyAddress
    let block: AudioObjectPropertyListenerBlock
  }
  var memory: ListeningRingMemory?
  var tap: AudioObjectID = kAudioObjectUnknown
  var aggregate: AudioObjectID = kAudioObjectUnknown
  var ioProc: AudioDeviceIOProcID?
  var running = false
  private var listeners = [Listener]()
  private let listenerQueue = DispatchQueue(label: "aniCe private audio changes")

  func observe(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws {
    guard let memory else { throw MacAudioTapError.unavailable }
    var address = Self.address(selector)
    let block: AudioObjectPropertyListenerBlock = { _, _ in
      AniceListeningRingInvalidate(memory.pointer)
    }
    try Self.check(AudioObjectAddPropertyListenerBlock(object, &address, listenerQueue, block), "observation")
    listeners.append(Listener(object: object, address: address, block: block))
  }

  func close() -> [MacAudioTapError] {
    var errors = [MacAudioTapError]()
    func record(_ status: OSStatus, _ operation: String) -> Bool {
      if status == noErr { return true }
      errors.append(.native(operation, status))
      return false
    }
    if running, let ioProc, aggregate != kAudioObjectUnknown {
      if record(AudioDeviceStop(aggregate, ioProc), "stop") { running = false }
    }
    if let ioProc, aggregate != kAudioObjectUnknown {
      if record(AudioDeviceDestroyIOProcID(aggregate, ioProc), "callback cleanup") {
        self.ioProc = nil
        running = false
      }
    }
    listeners = listeners.filter { listener in
      var address = listener.address
      return !record(AudioObjectRemovePropertyListenerBlock(listener.object, &address,
        listenerQueue, listener.block), "observation cleanup")
    }
    if aggregate != kAudioObjectUnknown {
      if record(AudioHardwareDestroyAggregateDevice(aggregate), "device cleanup") {
        aggregate = kAudioObjectUnknown
        ioProc = nil
        running = false
      }
    }
    if aggregate == kAudioObjectUnknown, tap != kAudioObjectUnknown {
      if record(AudioHardwareDestroyProcessTap(tap), "tap cleanup") { tap = kAudioObjectUnknown }
    }
    return errors
  }

  deinit {
    let errors = close()
    if ioProc != nil, let memory {
      // A failed native detachment must leak one bounded allocation rather than free a live callback's data.
      _ = Unmanaged.passRetained(memory)
    }
    if !errors.isEmpty {
      Logger(subsystem: "io.github.anisharyal09.anice", category: "Private Listening")
        .error("Native audio cleanup failed for \(errors.count) resources")
    }
  }

  static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    .init(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
  }

  static func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw MacAudioTapError.native(operation, status) }
  }
}

actor MacAudioTapEngine {
  private var resources: ListeningTapResources?
  private var sourceFormat: AVAudioFormat?
  private var converter: AVAudioConverter?
  private var packetizer = PrivateListeningPacketizer()
  private var rawSamples = [Float]()
  private var nextRawFrame: UInt64?
  private var nextConvertedFrame: Int64 = 0
  private var rawOrigin: UInt64 = 0
  private var forwarding = false
  private var sourceScratch: AVAudioPCMBuffer?
  private var convertedScratch: AVAudioPCMBuffer?

  /// The explicit preparation action can show system-audio consent, but never suppresses Mac output.
  func prepare() throws {
    try stop()
    let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
    description.name = "aniCe Private Listening"
    description.isPrivate = true
    description.muteBehavior = .unmuted
    let owner = ListeningTapResources()
    resources = owner
    do {
      try ListeningTapResources.check(AudioHardwareCreateProcessTap(description, &owner.tap), "tap creation")
      var pid = getpid(), process = AudioObjectID(kAudioObjectUnknown)
      var size = UInt32(MemoryLayout<AudioObjectID>.size)
      var processAddress = ListeningTapResources.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
      try ListeningTapResources.check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
        &processAddress, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process), "process lookup")
      guard process != kAudioObjectUnknown else { throw MacAudioTapError.unavailable }
      description.processes = [process]
      try setDescription(description, owner: owner)

      var format = AudioStreamBasicDescription()
      size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
      var formatAddress = ListeningTapResources.address(kAudioTapPropertyFormat)
      try ListeningTapResources.check(AudioObjectGetPropertyData(owner.tap, &formatAddress, 0, nil,
        &size, &format), "format lookup")
      guard format.mFormatID == kAudioFormatLinearPCM,
        format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
        format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
        format.mFormatFlags & kAudioFormatFlagIsPacked != 0,
        format.mBitsPerChannel == 32, (1...2).contains(format.mChannelsPerFrame),
        format.mBytesPerFrame == (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
          ? 4 : format.mChannelsPerFrame * 4),
        format.mSampleRate.isFinite, (8000...192000).contains(format.mSampleRate),
        let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.mSampleRate,
          channels: 2, interleaved: true),
        let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
          channels: 2, interleaved: true),
        let converter = AVAudioConverter(from: input, to: output) else {
        throw MacAudioTapError.unsupportedFormat
      }
      sourceFormat = input
      self.converter = converter
      let capacity = UInt32(ceil(format.mSampleRate * 0.2))
      let memory = try ListeningRingMemory(capacity: capacity)
      owner.memory = memory
      rawSamples = [Float](repeating: 0, count: Int(capacity) * 2)
      sourceScratch = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: capacity)
      convertedScratch = AVAudioPCMBuffer(pcmFormat: output,
        frameCapacity: UInt32(ceil(Double(capacity) * 48000 / format.mSampleRate)) + 512)
      guard sourceScratch != nil, convertedScratch != nil else { throw MacAudioTapError.unsupportedFormat }
      nextRawFrame = nil
      nextConvertedFrame = 0
      packetizer.reset()
      forwarding = false
      AniceListeningRingSetForwarding(memory.pointer, false)

      var uid = "" as CFString
      size = UInt32(MemoryLayout<CFString>.size)
      var uidAddress = ListeningTapResources.address(kAudioTapPropertyUID)
      try ListeningTapResources.check(withUnsafeMutablePointer(to: &uid) {
        AudioObjectGetPropertyData(owner.tap, &uidAddress, 0, nil, &size, $0)
      }, "tap identifier lookup")
      let aggregate: [String: Any] = [
        kAudioAggregateDeviceNameKey: "aniCe Private Listening",
        kAudioAggregateDeviceUIDKey: UUID().uuidString.lowercased(),
        kAudioAggregateDeviceIsPrivateKey: 1,
        kAudioAggregateDeviceTapAutoStartKey: 1,
        kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: uid, kAudioSubTapDriftCompensationKey: 1]],
      ]
      try ListeningTapResources.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary,
        &owner.aggregate), "device creation")
      try ListeningTapResources.check(AudioDeviceCreateIOProcID(owner.aggregate,
        AniceListeningCapture, UnsafeMutableRawPointer(memory.pointer), &owner.ioProc), "callback creation")
      try owner.observe(owner.tap, kAudioTapPropertyFormat)
      try owner.observe(owner.aggregate, kAudioDevicePropertyDeviceIsAlive)
      try owner.observe(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
      var defaultDevice = AudioObjectID(kAudioObjectUnknown)
      var defaultAddress = ListeningTapResources.address(kAudioHardwarePropertyDefaultOutputDevice)
      size = UInt32(MemoryLayout<AudioObjectID>.size)
      try ListeningTapResources.check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
        &defaultAddress, 0, nil, &size, &defaultDevice), "output lookup")
      guard defaultDevice != kAudioObjectUnknown else { throw MacAudioTapError.unavailable }
      try owner.observe(defaultDevice, kAudioDevicePropertyDeviceIsAlive)
      try owner.observe(defaultDevice, kAudioDevicePropertyNominalSampleRate)
      try ListeningTapResources.check(AudioDeviceStart(owner.aggregate, owner.ioProc), "capture start")
      owner.running = true
    } catch {
      _ = owner.close()
      resources = nil
      sourceFormat = nil
      converter = nil
      sourceScratch = nil; convertedScratch = nil
      throw error
    }
  }

  func activate(alsoPlayThroughMacSpeakers: Bool) throws {
    guard let owner = resources, let memory = owner.memory, owner.running else { throw MacAudioTapError.unavailable }
    guard !AniceListeningRingInvalidated(memory.pointer) else { throw MacAudioTapError.invalidated }
    try setMuting(!alsoPlayThroughMacSpeakers)
    // Forwarding was disabled in preparation; this discards only samples not yet owned by the worker.
    AniceListeningRingDiscard(memory.pointer)
    packetizer.reset()
    converter?.reset()
    nextRawFrame = nil
    nextConvertedFrame = 0
    rawOrigin = AniceListeningRingSourceFrames(memory.pointer)
    AniceListeningRingSetForwarding(memory.pointer, true)
    forwarding = true
  }

  func setMuting(_ muted: Bool) throws {
    guard let owner = resources else { throw MacAudioTapError.unavailable }
    var value: CATapDescription?
    var size = UInt32(MemoryLayout<CATapDescription?>.size)
    var address = ListeningTapResources.address(kAudioTapPropertyDescription)
    try ListeningTapResources.check(withUnsafeMutablePointer(to: &value) {
      AudioObjectGetPropertyData(owner.tap, &address, 0, nil, &size, $0)
    }, "mute description lookup")
    guard let value else { throw MacAudioTapError.unavailable }
    let behavior: CATapMuteBehavior = muted ? .mutedWhenTapped : .unmuted
    value.muteBehavior = behavior
    try setDescription(value, owner: owner)
    var verified: CATapDescription?
    try ListeningTapResources.check(withUnsafeMutablePointer(to: &verified) {
      AudioObjectGetPropertyData(owner.tap, &address, 0, nil, &size, $0)
    }, "mute description verification")
    guard verified?.muteBehavior == behavior, verified?.isPrivate == true else {
      throw MacAudioTapError.unavailable
    }
  }

  func setForwarding(_ enabled: Bool) throws {
    guard let owner = resources, let memory = owner.memory else { throw MacAudioTapError.unavailable }
    AniceListeningRingSetForwarding(memory.pointer, enabled)
    AniceListeningRingDiscard(memory.pointer)
    forwarding = enabled
    converter?.reset()
    nextRawFrame = nil
  }

  func read() throws -> MacAudioTapBatch {
    guard let owner = resources, let memory = owner.memory, let format = sourceFormat, let converter else {
      throw MacAudioTapError.unavailable
    }
    let ring = memory.pointer
    guard !AniceListeningRingInvalidated(ring) else { throw MacAudioTapError.invalidated }
    let rawFrame = AniceListeningRingSourceFrames(ring)
    let sourceFrame = try timelineFrame(rawFrame, rate: format.sampleRate)
    guard forwarding else {
      AniceListeningRingDiscard(ring)
      return MacAudioTapBatch(packets: [], sourceFrames: sourceFrame / 960 * 960,
        queuedFrames: 0, droppedFrames: AniceListeningRingDroppedFrames(ring))
    }
    // Capacity protects callback ownership; it is not a reason to replay 200 ms after a worker stall.
    if AniceListeningRingTrim(ring, UInt32(format.sampleRate * 0.06)) > 0 {
      nextRawFrame = nil
    }
    var rawOffset: UInt64 = 0
    let count = rawSamples.withUnsafeMutableBufferPointer {
      AniceListeningRingRead(ring, $0.baseAddress, UInt32($0.count / 2), &rawOffset)
    }
    var packets = [PrivateListeningCapturedPacket]()
    if count > 0 {
      // A callback may publish its source end before observing activation's forwarding switch.
      // That pre-activation block must not become negative stream time or audible replay.
      if rawOffset < rawOrigin {
        nextRawFrame = nil
        return MacAudioTapBatch(packets: [], sourceFrames: 0,
          queuedFrames: Int64(Double(AniceListeningRingQueuedFrames(ring)) * 48000 / format.sampleRate),
          droppedFrames: AniceListeningRingDroppedFrames(ring))
      }
      if nextRawFrame != rawOffset {
        converter.reset()
        nextConvertedFrame = try timelineFrame(rawOffset, rate: format.sampleRate)
        packetizer.reset(nextFrame: nextConvertedFrame)
      }
      nextRawFrame = rawOffset + UInt64(count)
      let output = try rawSamples.withUnsafeBufferPointer {
        try Self.convert($0, frames: count, using: converter,
          inputBuffer: sourceScratch, outputBuffer: convertedScratch)
      }
      if output.frameLength > 0, let data = output.audioBufferList.pointee.mBuffers.mData {
        let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self),
          count: Int(output.frameLength) * 2)
        packets = try packetizer.append(samples, sourceOffset: nextConvertedFrame)
        nextConvertedFrame += Int64(output.frameLength)
      }
    }
    return MacAudioTapBatch(packets: packets, sourceFrames: packetizer.completeSourceFrames,
      queuedFrames: Int64(Double(AniceListeningRingQueuedFrames(ring)) * 48000 / format.sampleRate),
      droppedFrames: AniceListeningRingDroppedFrames(ring))
  }

  func stop() throws {
    guard let owner = resources else { return }
    var restoreError: Error?
    // Restore tapped-process output before dismantling the reader/aggregate, not after a slow teardown.
    do { try setMuting(false) } catch { restoreError = error }
    if let memory = owner.memory { AniceListeningRingSetForwarding(memory.pointer, false) }
    let errors = owner.close()
    resources = nil
    sourceFormat = nil
    converter = nil
    sourceScratch = nil; convertedScratch = nil
    rawSamples.removeAll()
    forwarding = false
    nextRawFrame = nil
    packetizer.reset()
    if let error = errors.first { throw error }
    if let restoreError { throw restoreError }
  }

  private func setDescription(_ value: CATapDescription, owner: ListeningTapResources) throws {
    var address = ListeningTapResources.address(kAudioTapPropertyDescription)
    var description = value
    try ListeningTapResources.check(withUnsafePointer(to: &description) {
      AudioObjectSetPropertyData(owner.tap, &address, 0, nil,
        UInt32(MemoryLayout<CATapDescription>.size), $0)
    }, "tap configuration")
  }

  private func timelineFrame(_ raw: UInt64, rate: Double) throws -> Int64 {
    guard raw >= rawOrigin else { throw MacAudioTapError.invalidated }
    let frame = (Double(raw - rawOrigin) * 48000 / rate).rounded(.down)
    guard frame.isFinite, frame >= 0, frame < Double(Int64.max) else {
      throw PrivateListeningWireError.malformed
    }
    return Int64(frame)
  }

  // Conversion is synchronous on the engine worker; input pointers never cross a suspension.
  nonisolated static func convert(_ stereo: UnsafeBufferPointer<Float>, frames: UInt32,
    using converter: AVAudioConverter, inputBuffer: AVAudioPCMBuffer? = nil,
    outputBuffer: AVAudioPCMBuffer? = nil) throws -> AVAudioPCMBuffer {
    let format = converter.inputFormat
    guard frames > 0, Int(frames) <= stereo.count / 2, format.channelCount == 2,
      format.isInterleaved, format.commonFormat == .pcmFormatFloat32,
      let input = inputBuffer ?? AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
      let output = outputBuffer ?? AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
        frameCapacity: UInt32(ceil(Double(frames) * converter.outputFormat.sampleRate / format.sampleRate)) + 512),
      input.frameCapacity >= frames, input.format == format, output.format == converter.outputFormat,
      output.frameCapacity >= UInt32(ceil(Double(frames) * converter.outputFormat.sampleRate / format.sampleRate)),
      let inputData = input.mutableAudioBufferList.pointee.mBuffers.mData,
      let samples = stereo.baseAddress else { throw MacAudioTapError.unsupportedFormat }
    input.frameLength = frames
    output.frameLength = 0
    inputData.copyMemory(from: samples, byteCount: Int(frames) * 2 * MemoryLayout<Float>.size)
    var provided = false
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, inputStatus in
      if provided { inputStatus.pointee = .noDataNow; return nil }
      provided = true
      inputStatus.pointee = .haveData
      return input
    }
    if status == .error {
      if let error { throw error }
      throw MacAudioTapError.unsupportedFormat
    }
    return output
  }
}
