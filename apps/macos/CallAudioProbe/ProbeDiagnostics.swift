// SPDX-License-Identifier: GPL-3.0-or-later
// Diagnostic logging, CoreAudio enumeration and bounded input/output buffer checks
// for the Gate 1 Hands-Free audio-exposure probe.
import CoreAudio
import Foundation

// MARK: - Logging

/// Writes every diagnostic line to the terminal and, when requested, to a
/// transcript file. The transcript is the artifact a physical Gate 1 run
/// produces, so both sinks always receive the same bytes.
@MainActor
final class ProbeLog {
  // Native callbacks and commands enter the main actor before logging.
  private let handle: FileHandle?
  private let clock: ContinuousClock = .continuous
  private let origin = Date()

  init(path: URL?) {
    if let path {
      FileManager.default.createFile(atPath: path.path, contents: nil)
      handle = try? FileHandle(forWritingTo: path)
    } else {
      handle = nil
    }
  }

  deinit { try? handle?.close() }

  private func stamp() -> String { String(format: "%.3f", Date().timeIntervalSince(origin)) }

  func line(_ text: String) {
    let rendered = "[" + stamp() + "s] " + text + "\n"
    FileHandle.standardOutput.write(Data(rendered.utf8))
    if let handle, let data = rendered.data(using: .utf8) { try? handle.write(contentsOf: data) }
  }

  func heading(_ text: String) {
    line("")
    line("== " + text + " ==")
  }

  func step(_ text: String) { line(">> " + text) }
  func result(_ text: String) { line("   " + text) }
  func detail(_ key: String, _ value: String) { line("   " + key + ": " + value) }

  func data(_ label: String, _ bytes: Data) {
    let printable = String(decoding: bytes, as: UTF8.self)
      .replacingOccurrences(of: "\r", with: "\\r")
      .replacingOccurrences(of: "\n", with: "\\n")
      .replacingOccurrences(of: "\u{04}", with: "\\u0004")
    line("   <" + label + "> " + printable)
  }
}

// MARK: - Probe results

enum ProbeResultState: String {
  case pass
  case fail
  case unknown
  case skipped
}

/// One named Gate 1 step. Results are reported in order at exit so a failed
/// run names exactly which link in the chain did not hold.
@MainActor
final class ProbeResults {
  // Results share the orchestration executor.
  private var entries: [(String, ProbeResultState, String)] = []

  func record(_ name: String, _ state: ProbeResultState, _ detail: String = "") {
    entries.append((name, state, detail))
  }

  func print(to log: ProbeLog) {
    log.heading("Probe results")
    for (name, state, detail) in entries {
      let suffix = detail.isEmpty ? "" : " — " + detail
      log.line("[" + state.rawValue.uppercased() + "] " + name + suffix)
    }
  }

  var jsonEntries: [[String: String]] {
    entries.map { ["step": $0.0, "state": $0.1.rawValue, "detail": $0.2] }
  }

  func state(named name: String) -> ProbeResultState? {
    for entry in entries where entry.0 == name { return entry.1 }
    return nil
  }
}

// MARK: - CoreAudio constants

private func fourCC(_ text: String) -> OSType {
  precondition(text.utf8.count == 4, "four-character code must be four ASCII bytes")
  return text.utf8.reduce(0) { ($0 << 8) | OSType($1) }
}

private let transportBluetooth = fourCC("blue")
private let transportBluetoothLE = fourCC("blea")

func transportLabel(_ code: OSType) -> String {
  let first = UInt8((code >> 24) & 0xFF)
  let second = UInt8((code >> 16) & 0xFF)
  let third = UInt8((code >> 8) & 0xFF)
  let fourth = UInt8(code & 0xFF)
  let name = String(bytes: [first, second, third, fourth], encoding: .ascii) ?? "none"
  switch code {
  case transportBluetooth: return name + " (Bluetooth Classic)"
  case transportBluetoothLE: return name + " (Bluetooth LE)"
  case fourCC("buil"): return name + " (built-in)"
  case fourCC("usb "): return name + " (USB)"
  case fourCC("virt"): return name + " (virtual)"
  case fourCC("aggr"): return name + " (aggregate)"
  case fourCC("airp"): return name + " (AirPlay)"
  case 0: return "none"
  default: return name
  }
}

// MARK: - CoreAudio property helpers

private func propertyAddress(
  _ selector: AudioObjectPropertySelector,
  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
  element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) -> AudioObjectPropertyAddress {
  AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

private func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
  var address = propertyAddress(selector)
  // CFString property reads return an unretained string the system owns;
  // reading into raw storage avoids handing the system a Swift Optional slot.
  var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
  var raw: Unmanaged<CFString>?
  let status = withUnsafeMutableBytes(of: &raw) { buffer in
    AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer.baseAddress!)
  }
  guard status == noErr, let raw else { return nil }
  return raw.takeUnretainedValue() as String
}

private func uint32Property(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
  var address = propertyAddress(selector)
  var size = UInt32(MemoryLayout<UInt32>.size)
  var value: UInt32 = 0
  guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
  return value
}

private func objectList(
  _ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope
) -> [AudioObjectID] {
  var address = propertyAddress(selector, scope: scope)
  var size: UInt32 = 0
  guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr,
    size >= UInt32(MemoryLayout<AudioObjectID>.size)
  else { return [] }
  var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
  guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &values) == noErr else { return [] }
  return values
}

private func streamFormat(_ stream: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
  var address = propertyAddress(selector)
  var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
  var format = AudioStreamBasicDescription()
  guard AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &format) == noErr else { return nil }
  let sampleRate = format.mSampleRate
  let rate = sampleRate.rounded() == sampleRate
    ? String(Int(sampleRate)) : String(format: "%.1f", sampleRate)
  return "\(rate) Hz, \(format.mChannelsPerFrame) ch, "
    + "\(format.mBitsPerChannel)-bit, flags 0x" + String(format: "%08x", format.mFormatFlags)
}

private func streamDescription(_ stream: AudioObjectID, direction: String) -> ProbeStream {
  var entry = ProbeStream(
    identifier: stream, direction: direction, name: stringProperty(stream, kAudioObjectPropertyName),
    virtualFormat: nil, physicalFormat: nil, terminalType: nil)
  entry.virtualFormat = streamFormat(stream, kAudioStreamPropertyVirtualFormat)
  entry.physicalFormat = streamFormat(stream, kAudioStreamPropertyPhysicalFormat)
  entry.terminalType = uint32Property(stream, kAudioStreamPropertyTerminalType)
  return entry
}

private func deviceDescription(_ device: AudioObjectID) -> ProbeDevice {
  var entry = ProbeDevice(
    identifier: device, name: stringProperty(device, kAudioObjectPropertyName) ?? "(unnamed)",
    uid: stringProperty(device, kAudioDevicePropertyDeviceUID), transport: nil,
    transportName: nil, isRunning: nil, alive: true, streams: [])
  let transport = uint32Property(device, kAudioDevicePropertyTransportType) ?? 0
  entry.transport = transport
  entry.transportName = transportLabel(transport)
  entry.isRunning = uint32Property(device, kAudioDevicePropertyDeviceIsRunning) == 1
  // Direction is taken from the device's own scope membership, which is
  // authoritative: a stream in the input scope is an input stream.
  let inputs = objectList(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
  let outputs = objectList(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
  entry.streams = inputs.map { streamDescription($0, direction: "input") }
    + outputs.map { streamDescription($0, direction: "output") }
  return entry
}

/// A complete, ordered view of CoreAudio. Snapshots are compared by device UID
/// because AudioObjectIDs are not stable across hardware changes.
struct CoreAudioSnapshot {
  let devices: [ProbeDevice]
  let hostVersion: String

  var bluetoothDevices: [ProbeDevice] {
    devices.filter { $0.transport == transportBluetooth }
  }

  var bluetoothLEDevices: [ProbeDevice] {
    devices.filter { $0.transport == transportBluetoothLE }
  }

  func device(uid: String) -> ProbeDevice? { devices.first { $0.uid == uid } }
}

func takeCoreAudioSnapshot() -> CoreAudioSnapshot {
  let system = AudioObjectID(kAudioObjectSystemObject)
  var address = propertyAddress(kAudioHardwarePropertyDevices)
  var size: UInt32 = 0
  let identifiers: [AudioObjectID]
  if AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
    size >= UInt32(MemoryLayout<AudioObjectID>.size)
  {
    var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    if AudioObjectGetPropertyData(system, &address, 0, nil, &size, &values) == noErr {
      identifiers = values
    } else {
      identifiers = []
    }
  } else {
    identifiers = []
  }
  var devices = identifiers.map(deviceDescription)
  devices.sort { ($0.uid ?? "") < ($1.uid ?? "") }
  let version = ProcessInfo.processInfo.operatingSystemVersion
  return CoreAudioSnapshot(
    devices: devices,
    hostVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")
}

func encodeSnapshot(_ snapshot: CoreAudioSnapshot) -> String {
  var lines: [String] = []
  lines.append("CoreAudio device count: \(snapshot.devices.count) (macOS \(snapshot.hostVersion))")
  for device in snapshot.devices {
    let running = device.isRunning == true ? "running" : "stopped"
    lines.append(
      "  [\(device.identifier)] \(device.name) | transport=\(device.transportName ?? "?") | "
        + "uid=\(device.uid ?? "(none)") | \(running)")
    if device.streams.isEmpty {
      lines.append("      no streams")
    }
    for stream in device.streams {
      lines.append(
        "      \(stream.direction) stream \(stream.identifier): virtual=\(stream.virtualFormat ?? "n/a"); "
          + "physical=\(stream.physicalFormat ?? "n/a")")
    }
  }
  let bluetooth = snapshot.bluetoothDevices
  lines.append(
    "Bluetooth Classic transports: "
      + (bluetooth.isEmpty ? "none" : bluetooth.map { $0.name }.joined(separator: ", ")))
  let bluetoothLE = snapshot.bluetoothLEDevices
  if !bluetoothLE.isEmpty {
    lines.append(
      "Bluetooth LE transports (not the required Classic SCO path): "
        + bluetoothLE.map { $0.name }.joined(separator: ", "))
  }
  return lines.joined(separator: "\n")
}

/// Changes between two snapshots, keyed by UID so the report survives
/// AudioObjectID churn. Stream counts and formats are summarized per device.
func compareSnapshots(before: CoreAudioSnapshot, after: CoreAudioSnapshot) -> [String] {
  var lines: [String] = []
  let beforeByUID = Dictionary(before.devices.compactMap { device in device.uid.map { ($0, device) } },
    uniquingKeysWith: { first, _ in first })
  let afterByUID = Dictionary(after.devices.compactMap { device in device.uid.map { ($0, device) } },
    uniquingKeysWith: { first, _ in first })
  let added = afterByUID.keys.filter { beforeByUID[$0] == nil }.sorted()
  let removed = beforeByUID.keys.filter { afterByUID[$0] == nil }.sorted()
  for uid in added {
    guard let device = afterByUID[uid] else { continue }
    lines.append(
      "added: \(device.name) [\(device.transportName ?? "?")] with \(device.streams.count) stream(s)")
  }
  for uid in removed {
    guard let device = beforeByUID[uid] else { continue }
    lines.append(
      "removed: \(device.name) [\(device.transportName ?? "?")]")
  }
  for uid in afterByUID.keys.sorted() {
    guard let previous = beforeByUID[uid], let current = afterByUID[uid] else { continue }
    let oldInputs = previous.streams.filter { $0.direction == "input" }.count
    let newInputs = current.streams.filter { $0.direction == "input" }.count
    let oldOutputs = previous.streams.filter { $0.direction == "output" }.count
    let newOutputs = current.streams.filter { $0.direction == "output" }.count
    if oldInputs != newInputs || oldOutputs != newOutputs {
      lines.append(
        "streams changed: \(current.name) input \(oldInputs)→\(newInputs), output \(oldOutputs)→\(newOutputs)")
    } else if previous.streams.map(\.virtualFormat) != current.streams.map(\.virtualFormat) {
      lines.append("format changed: \(current.name)")
    } else if previous.isRunning != current.isRunning {
      lines.append("running changed: \(current.name) → \(current.isRunning == true ? "running" : "stopped")")
    }
  }
  return lines
}

// MARK: - Bounded input/output buffer check

enum AudioProbeOutcome {
  case usable(callbacks: Int, seconds: Double, firstCallbackLatency: Double)
  case failed(String)
}

/// Counts actual non-empty input and initialized output buffers, not just callbacks.
/// The serial callback queue owns statistics; the snapshot uses queue.sync.
private final class AudioBufferStatistics: @unchecked Sendable {
  var callbacks = 0
  var inputBytes = 0
  var outputBytes = 0
  var firstCallback: ContinuousClock.Instant?
}

func validAudioBytes(_ buffers: UnsafePointer<AudioBufferList>) -> Int {
  UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffers)).reduce(0) { count, buffer in
    count + (buffer.mData != nil && buffer.mNumberChannels > 0 ? Int(buffer.mDataByteSize) : 0)
  }
}

func silenceOutput(_ buffers: UnsafeMutablePointer<AudioBufferList>) -> Int {
  var bytes = 0
  for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
    if let data = buffer.mData, buffer.mDataByteSize > 0 {
      memset(data, 0, Int(buffer.mDataByteSize))
      if buffer.mNumberChannels > 0 { bytes += Int(buffer.mDataByteSize) }
    }
  }
  return bytes
}

@MainActor
func runAudioBufferCheck(on device: ProbeDevice, duration: Double = 0.5) async -> AudioProbeOutcome {
  guard device.inputCount > 0 && device.outputCount > 0 else { return .failed("both stream directions required") }
  guard MicrophoneAccess.isGranted else { return .failed("microphone permission missing") }
  var address = propertyAddress(kAudioDevicePropertyDeviceIsAlive)
  var alive: UInt32 = 0
  var size = UInt32(MemoryLayout<UInt32>.size)
  guard AudioObjectGetPropertyData(device.identifier, &address, 0, nil, &size, &alive) == noErr, alive == 1
  else { return .failed("device is not alive") }

  let started = ContinuousClock.now
  let queue = DispatchQueue(label: "anice.callprobe.audio-buffers")
  let statistics = AudioBufferStatistics()
  var procID: AudioDeviceIOProcID?
  let creation = AudioDeviceCreateIOProcIDWithBlock(&procID, device.identifier, queue) { _, input, _, output, _ in
    statistics.callbacks += 1
    if statistics.firstCallback == nil { statistics.firstCallback = .now }
    statistics.inputBytes += validAudioBytes(input)
    statistics.outputBytes += silenceOutput(output)
  }
  guard creation == noErr, let procID else {
    return .failed("AudioDeviceCreateIOProcIDWithBlock failed (\(creation.fourCCDescription))")
  }
  defer { AudioDeviceDestroyIOProcID(device.identifier, procID) }
  let start = AudioDeviceStart(device.identifier, procID)
  guard start == noErr else { return .failed("AudioDeviceStart failed (\(start.fourCCDescription))") }
  try? await Task.sleep(for: .seconds(duration))
  let stop = AudioDeviceStop(device.identifier, procID)
  guard stop == noErr else { return .failed("AudioDeviceStop failed (\(stop.fourCCDescription))") }
  return queue.sync {
    guard statistics.inputBytes > 0 && statistics.outputBytes > 0 else {
      return .failed("\(statistics.callbacks) callbacks; valid input=\(statistics.inputBytes) bytes, initialized output=\(statistics.outputBytes) bytes")
    }
    func seconds(_ interval: Duration) -> Double {
      Double(interval.components.seconds) + Double(interval.components.attoseconds) / 1e18
    }
    return .usable(callbacks: statistics.callbacks, seconds: seconds(started.duration(to: .now)),
      firstCallbackLatency: seconds(started.duration(to: statistics.firstCallback ?? started)))
  }
}

extension OSStatus {
  /// Four-character CoreAudio error codes that occur on this path, with the
  /// meaning Apple documents for them.
  private static let knownFourCC: [String: String] = [
    "!obj": "bad object",
    "nope": "unsupported",
    "!dat": "bad data",
    "!siz": "bad size",
    "!pri": "bad priority",
    "per?": "no permission",
    "!run": "cannot run",
    "!sta": "cannot start",
    "!sto": "cannot stop",
    "bad ": "bad value",
    "stop": "already stopped",
    "run ": "already running",
  ]

  /// Renders the usual CoreAudio error code as text where one is known.
  var fourCCDescription: String {
    if self == kAudioHardwareUnsupportedOperationError || self == -536870201 {
      return "unsupported function (status \(self))"
    }
    let code = OSType(bitPattern: self)
    let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
                 UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
    let text = String(bytes: bytes, encoding: .ascii) ?? ""
    if !text.isEmpty, text.allSatisfy({ $0.isASCII && !$0.isNewline }) {
      if let description = Self.knownFourCC[text] { return "'" + text + "' (" + description + ")" }
      if text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "!" || $0 == "?" || $0 == " " }) {
        return "'" + text + "'"
      }
    }
    return "status \(self)"
  }
}
