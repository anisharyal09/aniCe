// SPDX-License-Identifier: GPL-3.0-or-later
// Reads native telemetry and applies Desk Deck audio and lock controls.
import CoreAudio
import CoreGraphics
import Foundation
import IOKit
import IOKit.ps
import Darwin

struct InputMuteDevice {
  let id: AudioDeviceID
  let uid: String
  let muted: Bool
  var identity: String { "\(id):\(uid)" }
}

enum DeskDeckInputMute {
  private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
  }

  static func read() -> InputMuteDevice? {
    var defaultAddress = address(kAudioHardwarePropertyDefaultInputDevice)
    var id = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultAddress, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
    var uid = "" as CFString
    size = UInt32(MemoryLayout<CFString>.size)
    var uidAddress = address(kAudioDevicePropertyDeviceUID)
    let uidStatus = withUnsafeMutablePointer(to: &uid) { uidPointer in
      AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &size, uidPointer)
    }
    guard uidStatus == noErr else { return nil }
    var muteAddress = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput)
    var settable = DarwinBoolean(false), muted: UInt32 = 0
    size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectHasProperty(id, &muteAddress), AudioObjectIsPropertySettable(id, &muteAddress, &settable) == noErr, settable.boolValue,
      AudioObjectGetPropertyData(id, &muteAddress, 0, nil, &size, &muted) == noErr, muted <= 1 else { return nil }
    return InputMuteDevice(id: id, uid: uid as String, muted: muted == 1)
  }

  static func set(_ target: InputMuteDevice, muted: Bool) -> Int64 {
    guard let current = read() else { return 2 }
    guard current.identity == target.identity else { return 1 }
    var muteAddress = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput)
    var value: UInt32 = muted ? 1 : 0
    let result = AudioObjectSetPropertyData(target.id, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    return result == noErr ? 0 : 7
  }
}

struct DeskDeckNativeOutput {
  let device: AudioDeviceID
  let uid: String
  let name: String
}

enum DeskDeckOutputDevices {
  private static func address(_ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
  }

  static func available() -> [DeskDeckNativeOutput] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var devicesAddress = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &devicesAddress, 0, nil, &size) == noErr,
      size >= MemoryLayout<AudioDeviceID>.size else { return [] }
    var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    let status = devices.withUnsafeMutableBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return OSStatus(-1) }
      return AudioObjectGetPropertyData(system, &devicesAddress, 0, nil, &size, baseAddress)
    }
    guard status == noErr else { return [] }
    return devices.compactMap { device in
      var streamAddress = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
      var streamBytes: UInt32 = 0
      guard AudioObjectGetPropertyDataSize(device, &streamAddress, 0, nil, &streamBytes) == noErr, streamBytes > 0 else { return nil }
      var aliveAddress = address(kAudioDevicePropertyDeviceIsAlive)
      var alive: UInt32 = 0
      var aliveSize = UInt32(MemoryLayout<UInt32>.size)
      guard AudioObjectGetPropertyData(device, &aliveAddress, 0, nil, &aliveSize, &alive) == noErr, alive == 1 else { return nil }
      guard let uid = string(device, selector: kAudioDevicePropertyDeviceUID), !uid.isEmpty,
        let rawName = string(device, selector: kAudioObjectPropertyName) else { return nil }
      let name = safeName(rawName)
      return DeskDeckNativeOutput(device: device, uid: uid, name: name)
    }
  }

  static func defaultUID() -> String? {
    var defaultAddress = address(kAudioHardwarePropertyDefaultOutputDevice)
    var device = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultAddress, 0, nil, &size, &device) == noErr,
      device != 0 else { return nil }
    return string(device, selector: kAudioDevicePropertyDeviceUID)
  }

  static var canSelectDefault: Bool {
    var property = address(kAudioHardwarePropertyDefaultOutputDevice)
    var settable = DarwinBoolean(false)
    return AudioObjectIsPropertySettable(AudioObjectID(kAudioObjectSystemObject), &property, &settable) == noErr && settable.boolValue
  }

  static func selectDefault(uid: String) -> Int64 {
    guard canSelectDefault else { return 2 }
    guard let device = available().first(where: { $0.uid == uid }) else { return 5 }
    var property = address(kAudioHardwarePropertyDefaultOutputDevice)
    var selected = device.device
    guard AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil,
      UInt32(MemoryLayout<AudioDeviceID>.size), &selected) == noErr else { return 7 }
    return 0
  }

  private static func string(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
    var property = address(selector)
    var value = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let status = withUnsafeMutablePointer(to: &value) { pointer in
      AudioObjectGetPropertyData(object, &property, 0, nil, &size, pointer)
    }
    return status == noErr ? value as String : nil
  }

  private static func safeName(_ rawName: String) -> String {
    let cleaned = rawName.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
      .joined().trimmingCharacters(in: .whitespacesAndNewlines)
    var name = ""
    for character in cleaned {
      guard (name + String(character)).utf16.count <= 80 else { break }
      name.append(character)
    }
    return name.isEmpty ? "Audio output" : name
  }
}

final class DeskDeckOutputObservation: @unchecked Sendable {
  private let block: AudioObjectPropertyListenerBlock
  private var addresses: [AudioObjectPropertyAddress] = []

  init(changed: @escaping @Sendable () -> Void) {
    let system = AudioObjectID(kAudioObjectSystemObject)
    block = { _, _ in changed() }
    for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
      var property = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
      if AudioObjectHasProperty(system, &property), AudioObjectAddPropertyListenerBlock(system, &property, .main, block) == noErr {
        addresses.append(property)
      }
    }
  }

  deinit {
    let system = AudioObjectID(kAudioObjectSystemObject)
    for var property in addresses { AudioObjectRemovePropertyListenerBlock(system, &property, .main, block) }
  }
}

struct DeskDeckMemory {
  let active: Int64
  let wired: Int64
  let compressed: Int64
  let total: Int64
  let app: Int64
  let cached: Int64
  let free: Int64
  let swap: Int64
  var used: Int64 { app < 0 ? 0 : total - free - cached }

  init(statistics: vm_statistics64, total: Int64, pageSize: Int64, swap: Int64) {
    func bytes(_ pages: natural_t) -> Int64 { Int64(pages) * pageSize }
    self.total = total
    active = bytes(statistics.active_count)
    wired = bytes(statistics.wire_count)
    compressed = bytes(statistics.compressor_page_count)
    // Active pages include file-backed data; app memory uses anonymous pages minus purgeable pages.
    app = bytes(statistics.internal_page_count > statistics.purgeable_count ? statistics.internal_page_count - statistics.purgeable_count : 0)
    cached = bytes(statistics.external_page_count) + bytes(statistics.purgeable_count)
    free = bytes(statistics.free_count)
    self.swap = swap
  }

  private init() {
    active = 0; wired = 0; compressed = 0; total = 0
    app = -1; cached = -1; free = -1; swap = -1
  }

  static func read() -> Self {
    var statistics = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &statistics) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return Self() }
    var swapUsage = xsw_usage()
    var swapSize = MemoryLayout<xsw_usage>.size
    let swapResult = sysctlbyname("vm.swapusage", &swapUsage, &swapSize, nil, 0)
    let reading = Self(statistics: statistics, total: Int64(ProcessInfo.processInfo.physicalMemory),
      pageSize: Int64(getpagesize()), swap: swapResult == 0 ? Int64(clamping: swapUsage.xsu_used) : -1)
    // Inconsistent native counters should be unavailable, never clamped into a plausible reading.
    guard reading.used >= 0, reading.used <= reading.total, reading.cached <= reading.total, reading.free <= reading.total,
      reading.app + reading.wired + reading.compressed <= reading.used else { return Self() }
    return reading
  }
}

struct DeskDeckCPU {
  static func percentage(previous: [UInt32], current: [UInt32]) -> Int64 {
    guard !current.isEmpty, current.count == previous.count, current.count.isMultiple(of: Int(CPU_STATE_MAX)) else { return -1 }
    var busy: UInt64 = 0, total: UInt64 = 0
    for index in current.indices {
      // Subtract at the native 32-bit width before widening, so counter rollover remains a small delta.
      let delta = UInt64(current[index] &- previous[index])
      total += delta
      if index % Int(CPU_STATE_MAX) != Int(CPU_STATE_IDLE) { busy += delta }
    }
    guard total > 0 else { return -1 }
    return Int64((Double(busy) * 100 / Double(total)).rounded()).clamped(to: 0...100)
  }
}

struct DeskDeckPower {
  let state: Int64 // 0 unavailable, 1 no battery, 2 battery, 3 charging, 4 charged, 5 plugged but not charging
  let percent: Int64
  let source: Int64 // 0 unavailable, 1 battery, 2 AC, 3 UPS

  static func read() -> Self {
    guard let unmanagedInfo = IOPSCopyPowerSourcesInfo() else { return Self(state: 0, percent: -1, source: 0) }
    let info = unmanagedInfo.takeRetainedValue()
    let sourceType = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
    let source: Int64
    if sourceType == (kIOPMBatteryPowerKey as String) { source = 1 }
    else if sourceType == (kIOPMACPowerKey as String) { source = 2 }
    else if sourceType == (kIOPMUPSPowerKey as String) { source = 3 }
    else { source = 0 }
    guard let unmanagedList = IOPSCopyPowerSourcesList(info) else { return Self(state: 0, percent: -1, source: source) }
    let list = unmanagedList.takeRetainedValue() as [CFTypeRef]
    guard !list.isEmpty else { return Self(state: 1, percent: -1, source: source) }
    let descriptions = list.compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
    guard let battery = descriptions.first(where: { $0[kIOPSCurrentCapacityKey] != nil }) else { return Self(state: 1, percent: -1, source: source) }
    let current = battery[kIOPSCurrentCapacityKey] as? Int
    let maximum = battery[kIOPSMaxCapacityKey] as? Int
    let percent = current.flatMap { current in maximum.flatMap { $0 > 0 ? Int64(current * 100 / $0) : nil } }.map { min(100, max(0, $0)) } ?? -1
    let powerState = battery[kIOPSPowerSourceStateKey] as? String
    let charging = battery[kIOPSIsChargingKey] as? Bool ?? false
    let external = powerState == kIOPSACPowerValue as String || source == 2 || source == 3
    return Self(state: chargeState(charging: charging, percent: percent, external: external), percent: percent, source: source)
  }

  static func chargeState(charging: Bool, percent: Int64, external: Bool) -> Int64 {
    if charging { return 3 }
    if external { return percent >= 100 ? 4 : 5 }
    return 2
  }
}

enum MacDeskDeckLock {
  static var hasEventPostingAccess: Bool { CGPreflightPostEventAccess() }

  static func request() -> Int64 {
    guard hasEventPostingAccess else { return 3 }
    guard let source = CGEventSource(stateID: .hidSystemState) else { return 7 }
    let q: CGKeyCode = 0x0C
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: q, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: q, keyDown: false) else { return 7 }
    down.flags = [.maskControl, .maskCommand]
    up.flags = [.maskControl, .maskCommand]
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    return 0
  }
}

private extension Int64 {
  func clamped(to range: ClosedRange<Int64>) -> Int64 { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}
