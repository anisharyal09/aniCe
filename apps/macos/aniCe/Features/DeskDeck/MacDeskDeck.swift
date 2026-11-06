// SPDX-License-Identifier: GPL-3.0-or-later
// Serves foreground Android Desk Deck telemetry and native Mac controls over secured DATA.
import AppKit
import CoreAudio
import CoreGraphics
import Foundation
import IOKit
import IOKit.ps
import Observation
import Darwin
import UniformTypeIdentifiers
import os

enum MacDeskDeckWireError: Error { case malformed }

struct MacDeskDeckShortcut: Equatable {
  let id: String
  let name: String
}

struct MacDeskDeckMessage {
  let version: Int64
  let kind: Int64
  let fields: [SessionCBOR]

  init(version: Int64 = 1, kind: Int64, fields: [SessionCBOR]) {
    self.version = version
    self.kind = kind
    self.fields = fields
  }

  func encode() throws -> Data {
    try validate()
    let limit = version == 1 ? 512 : 3800
    let data = try SessionCbor.encode(.array([.text("aniCe desk deck"), .integer(version), .integer(kind), .array(fields)]), maximumBytes: limit)
    guard data.count <= limit else { throw MacDeskDeckWireError.malformed }
    return data
  }

  static func decode(_ data: Data) throws -> Self? {
    guard data.count <= 4000 else { throw MacDeskDeckWireError.malformed }
    guard case .array(let row) = try SessionCbor.decode(data), case .text("aniCe desk deck")? = row.first else { return nil }
    guard row.count == 4, case .integer(let version) = row[1], (1...3).contains(version),
      data.count <= (version == 1 ? 512 : 3800), case .integer(let kind) = row[2], case .array(let fields) = row[3] else {
      throw MacDeskDeckWireError.malformed
    }
    let message = Self(version: version, kind: kind, fields: fields)
    try message.validate()
    return message
  }

  func number(_ index: Int) -> Int64 { if fields.indices.contains(index), case .integer(let value) = fields[index] { return value }; return -1 }
  func string(_ index: Int) -> String { if fields.indices.contains(index), case .text(let value) = fields[index] { return value }; return "" }
  func bool(_ index: Int) -> Bool { if fields.indices.contains(index), case .bool(let value) = fields[index] { return value }; return false }

  private func validate() throws {
    guard (1...3).contains(version) else { throw MacDeskDeckWireError.malformed }
    func text(_ i: Int) -> Bool { fields.indices.contains(i) && { if case .text = fields[i] { return true }; return false }() }
    func number(_ i: Int, _ range: ClosedRange<Int64>) -> Bool { fields.indices.contains(i) && { if case .integer(let n) = fields[i] { return range.contains(n) }; return false }() }
    func integer(_ i: Int) -> Int64 { self.number(i) }
    func bool(_ i: Int) -> Bool { fields.indices.contains(i) && { if case .bool = fields[i] { return true }; return false }() }
    func uuid(_ i: Int) -> Bool { guard text(i), let value = UUID(uuidString: string(i)) else { return false }; return value.uuidString.lowercased() == string(i) }
    func validIdentity(_ supported: Bool, _ target: String, _ revision: String) -> Bool {
      supported ? !target.isEmpty && !revision.isEmpty : target.isEmpty && revision.isEmpty
    }
    func validControl(_ supported: Bool, _ target: String, _ revision: String, _ level: Int64) -> Bool {
      supported ? !target.isEmpty && !revision.isEmpty && (0...100).contains(level) : target.isEmpty && revision.isEmpty && level == -1
    }
    let validMemory: Bool = {
      guard fields.indices.contains(3), fields.indices.contains(4), case .integer(let used) = fields[3], case .integer(let total) = fields[4] else { return false }
      return used >= 0 && total >= 0 && used <= total
    }()
    let valid: Bool
    switch kind {
    case 1: valid = fields.count == 1 && number(0, 0...15)
    case 2, 6, 7: valid = fields.count == 1 && uuid(0) && (kind != 7 || version >= 2)
    case 8: valid = version >= 2 && fields.count == 2 && uuid(0) && number(1, 0...3)
    case 10: valid = version >= 2 && fields.count == 2 && uuid(0) && uuid(1)
    case 9:
      guard version >= 2, fields.count == 5, uuid(0), number(1, 0...3), number(2, 1...4), integer(1) < integer(2), uuid(3),
        fields.indices.contains(4), case .array(let rows) = fields[4], rows.count <= 8 else { throw MacDeskDeckWireError.malformed }
      var ids = Set<String>()
      valid = rows.allSatisfy { item in
        guard case .array(let pair) = item, pair.count == 2, case .text(let id) = pair[0],
          let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id,
          case .text(let name) = pair[1], !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          name.utf16.count <= 80, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
          ids.insert(id).inserted else { return false }
        return true
      }
    case 3:
      if version == 1 {
        valid = fields.count == 19 && uuid(0) && number(1, 1...4294967295) && number(2, -1...100) &&
          validMemory && number(5, 0...3) && number(6, 0...15) && bool(7) && text(8) && text(9) && number(10, -1...100) &&
          bool(11) && text(12) && text(13) && bool(14) && bool(15) && text(16) && text(17) && number(18, -1...100) &&
          validControl(self.bool(7), self.string(8), self.string(9), self.number(10)) && validIdentity(self.bool(11), self.string(12), self.string(13)) &&
          validControl(self.bool(15), self.string(16), self.string(17), self.number(18))
      } else {
        guard fields.count == (version == 3 ? 24 : 20), uuid(0) else { throw MacDeskDeckWireError.malformed }
        let active = integer(3), wired = integer(4), compressed = integer(5), total = integer(6)
        let sumValid = active >= 0 && wired >= 0 && compressed >= 0 && total >= 0 && active <= total && wired <= total - active && compressed <= total - active - wired
        let detailValid: Bool
        if version == 3 {
          let app = integer(20), cached = integer(21), free = integer(22), swap = integer(23)
          detailValid = (20...23).allSatisfy { number($0, -1...Int64.max) } &&
            ((app == -1 && cached == -1 && free == -1 && swap == -1) ||
             (app >= 0 && app <= total && cached >= 0 && cached <= total && free >= 0 && free <= total &&
              cached <= total - free && app <= total - free - cached &&
              wired >= 0 && wired <= total - free - cached - app && compressed >= 0 && compressed <= total - free - cached - app - wired))
        } else { detailValid = true }
        valid = number(3, 0...Int64.max) && number(4, 0...Int64.max) && number(5, 0...Int64.max) && number(6, 0...Int64.max) &&
          number(1, 1...4294967295) && number(2, -1...100) && sumValid && detailValid && number(7, 0...3) && number(8, 0...15) &&
          bool(9) && text(10) && text(11) && number(12, -1...100) && bool(13) && text(14) && text(15) && bool(16) &&
          number(17, 0...5) && number(18, -1...100) && number(19, 0...3) &&
          (integer(17) >= 2 || integer(18) == -1) &&
          validControl(self.bool(9), self.string(10), self.string(11), self.number(12)) && validIdentity(self.bool(13), self.string(14), self.string(15))
      }
    case 4:
      guard fields.count == 6, uuid(0), number(1, 1...4294967295), number(2, 1...(version == 1 ? 7 : 8)), text(3), text(4), number(5, -1...100) else {
        throw MacDeskDeckWireError.malformed
      }
      let action = self.number(2), target = self.string(3), revision = self.string(4), value = self.number(5)
      switch action {
      case 1, 5: valid = target.isEmpty && revision.isEmpty && value == -1
      case 3, 4: valid = version == 1 && target.isEmpty && revision.isEmpty && value == -1
      case 2: valid = !target.isEmpty && !revision.isEmpty && (0...1).contains(value)
      case 6: valid = !target.isEmpty && !revision.isEmpty && (0...100).contains(value)
      case 7: valid = version == 1 && !target.isEmpty && !revision.isEmpty && (0...100).contains(value)
      case 8: valid = version >= 2 && uuid(3) && uuid(4) && value == -1
      default: valid = false
      }
    case 5: valid = fields.count == 3 && uuid(0) && number(1, 1...4294967295) && number(2, 0...7)
    default: valid = false
    }
    guard valid else { throw MacDeskDeckWireError.malformed }
  }
}

private struct InputMuteDevice {
  let id: AudioDeviceID
  let uid: String
  let muted: Bool
  var identity: String { "\(id):\(uid)" }
}

private enum DeskDeckInputMute {
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

private struct DeskDeckPower {
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
    if charging { return Self(state: 3, percent: percent, source: source) }
    if percent >= 100 { return Self(state: 4, percent: percent, source: source) }
    if powerState == kIOPSACPowerValue as String { return Self(state: 5, percent: percent, source: source) }
    return Self(state: 2, percent: percent, source: source)
  }
}

struct DeskDeckApprovedApp: Codable, Equatable, Identifiable {
  let id: String
  let bundleIdentifier: String
  let name: String
  let path: String
  let resourceIdentifier: String
  let executableResourceIdentifier: String?
}

private struct DeskDeckAppCatalog: Codable {
  var revision: String
  var apps: [DeskDeckApprovedApp]
}

struct MacDevicePowerMessage {
  let kind: Int64
  let state: Int64
  let percent: Int64
  let source: Int64

  func encode() throws -> Data {
    let fields: [SessionCBOR]
    if kind == 1 { fields = [.integer(1)] }
    else if kind == 2 { fields = [.integer(state), .integer(percent), .integer(source)] }
    else { throw MacDeskDeckWireError.malformed }
    let data = try SessionCbor.encode(.array([.text("aniCe device power"), .integer(1), .integer(kind), .array(fields)]), maximumBytes: 128)
    guard try Self.decode(data)?.kind == kind else { throw MacDeskDeckWireError.malformed }
    return data
  }

  static func decode(_ data: Data) throws -> Self? {
    guard data.count <= 128 else { throw MacDeskDeckWireError.malformed }
    guard case .array(let row) = try SessionCbor.decode(data), case .text("aniCe device power")? = row.first else { return nil }
    guard row.count == 4, row[1] == .integer(1), case .integer(let kind) = row[2], case .array(let fields) = row[3] else {
      throw MacDeskDeckWireError.malformed
    }
    func number(_ index: Int) -> Int64? { guard fields.indices.contains(index), case .integer(let value) = fields[index] else { return nil }; return value }
    if kind == 1 {
      guard fields.count == 1, number(0) == 1 else { throw MacDeskDeckWireError.malformed }
      return Self(kind: kind, state: 0, percent: -1, source: 0)
    }
    guard kind == 2, fields.count == 3, let state = number(0), let percent = number(1), let source = number(2),
      (0...5).contains(state), (-1...100).contains(percent), (0...5).contains(source), state >= 2 || percent == -1 else {
      throw MacDeskDeckWireError.malformed
    }
    return Self(kind: kind, state: state, percent: percent, source: source)
  }
}

struct MacPhonePowerReading: Equatable {
  let state: Int64
  let percent: Int64
  let source: Int64

  var summary: String {
    let stateText: String = switch state {
    case 1: "No battery"
    case 2: "On battery"
    case 3: "Charging"
    case 4: "Fully charged"
    case 5: "Plugged in · not charging"
    default: "Power unavailable"
    }
    let sourceText: String = switch source {
    case 1: "Battery"
    case 2: "AC power"
    case 3: "USB power"
    case 4: "Wireless power"
    case 5: "Dock power"
    default: ""
    }
    let percentText = percent >= 0 ? " · \(percent)%" : ""
    let sourceSuffix = sourceText.isEmpty ? "" : " · \(sourceText)"
    return stateText + percentText + sourceSuffix
  }
}

@Observable @MainActor final class MacPhonePowerModel: FeatureHandler {
  private var links: [String: any SecuredChannel] = [:]
  private var capableTransports = Set<String>()
  private(set) var readings: [String: MacPhonePowerReading] = [:]

  func available(_ channel: any SecuredChannel) {
    let transport = channel.descriptor.transport
    links[transport] = channel
    capableTransports.remove(transport)
  }

  func retired(_ descriptor: ChannelDescriptor) {
    guard links[descriptor.transport]?.descriptor == descriptor else { return }
    links.removeValue(forKey: descriptor.transport)
    capableTransports.remove(descriptor.transport)
    if !links.values.contains(where: { $0.descriptor.peer.fingerprint == descriptor.peer.fingerprint }) {
      readings.removeValue(forKey: descriptor.peer.fingerprint)
    }
  }

  func capacityAvailable(_ descriptor: ChannelDescriptor) {}

  func handle(_ bytes: Data, on descriptor: ChannelDescriptor) async -> DataHandling {
    guard links[descriptor.transport]?.descriptor == descriptor else { return .discarded }
    let message: MacDevicePowerMessage
    do { guard let decoded = try MacDevicePowerMessage.decode(bytes) else { return .unrecognized }; message = decoded }
    catch { return .discarded }
    let fingerprint = descriptor.peer.fingerprint
    if message.kind == 1 {
      capableTransports.insert(descriptor.transport)
      return .handled
    }
    guard message.kind == 2, capableTransports.contains(descriptor.transport) else { return .discarded }
    readings[fingerprint] = MacPhonePowerReading(state: message.state, percent: message.percent, source: message.source)
    return .handled
  }

  func summary(for peer: DeviceIdentity?) -> String {
    guard let peer else { return "Phone power unavailable" }
    return readings[peer.fingerprint]?.summary ?? "Phone power unavailable"
  }
}

@Observable @MainActor final class MacDeskDeckModel: FeatureHandler {
  private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "aniCe", category: "DeskDeck")
  private static let powerChangeCallback: IOPowerSourceCallbackType = { context in
    guard let context else { return }
    let model = Unmanaged<MacDeskDeckModel>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { model.powerSourceDidChange() }
  }
  private struct Link {
    let channel: any SecuredChannel
    var protocolVersion: Int64 = 1
    var subscription = ""
    var sequence: Int64 = 0
    var lastCommand: Int64 = 0
    var lastRenewal: TimeInterval = 0
    var usedSubscriptions: [String] = []
    var capabilitySent = false
    var capabilitySending = false
  }

  private var supportedActions: Int64
  private var links: [String: Link] = [:]
  private let outputVolume = MacOutputVolume()
  private var ticker: Task<Void, Never>?
  private var tickerGeneration: UInt64 = 0
  private struct PendingSample {
    let descriptor: ChannelDescriptor
    let subscription: String
    let bytes: Data
    let queuedAt: TimeInterval
  }
  private struct PendingCommandJob {
    let descriptor: ChannelDescriptor
    let subscription: String
    let task: Task<Void, Never>
  }
  private var pendingSamples: [String: PendingSample] = [:]
  private var drainingSamples = Set<String>()
  private var commandJobs: [String: [Int64: PendingCommandJob]] = [:]
  private var powerSource: CFRunLoopSource?
  private var activationObserver: NSObjectProtocol?
  private let defaults = UserDefaults.standard
  private struct PendingCatalogPage {
    let descriptor: ChannelDescriptor
    let subscription: String
    let page: Int64
  }
  private struct PendingCatalogUpdate: Equatable {
    let descriptor: ChannelDescriptor
    let subscription: String
    let revision: String
  }
  private var pendingCatalogPages: [String: [PendingCatalogPage]] = [:]
  private var pendingCatalogUpdates: [String: PendingCatalogUpdate] = [:]
  private var sendingCatalogUpdates = Set<String>()
  private var previousCPUTicks: [UInt32]?
  private var lastCPUPercent: Int64 = -1
  private var inputIdentity = ""
  private var inputTarget = ""
  private var inputRevision = ""
  private var inputMuted: Bool?
  private(set) var catalogGeneration = 0

  init() {
    supportedActions = Self.actionMask
    activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
      object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.refreshCapabilities() } }
  }

  func shutdown() {
    if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    activationObserver = nil
    stopPowerObservation()
    tickerGeneration &+= 1
    ticker?.cancel(); ticker = nil
    for jobs in commandJobs.values { jobs.values.forEach { $0.task.cancel() } }
    commandJobs.removeAll()
    pendingSamples.removeAll()
    pendingCatalogPages.removeAll()
    pendingCatalogUpdates.removeAll()
    sendingCatalogUpdates.removeAll()
    outputVolume.stop()
    previousCPUTicks = nil
  }

  func available(_ channel: any SecuredChannel) {
    let descriptor = channel.descriptor
    pendingCatalogUpdates.removeValue(forKey: descriptor.transport)
    links[descriptor.transport] = Link(channel: channel)
    sendCapability(on: descriptor.transport)
  }

  private func sendCapability(on transport: String) {
    guard var link = links[transport], !link.capabilitySent, !link.capabilitySending else { return }
    link.capabilitySending = true
    links[transport] = link
    let capabilityV3 = MacDeskDeckMessage(version: 3, kind: 1, fields: [.integer(supportedActions)])
    let capabilityV2 = MacDeskDeckMessage(version: 2, kind: 1, fields: [.integer(supportedActions)])
    let capabilityV1 = MacDeskDeckMessage(kind: 1, fields: [.integer(supportedActions)])
    let descriptor = link.channel.descriptor
    Task { @MainActor [weak self] in
      var sent = true
      do { try await link.channel.sendData(capabilityV3.encode()) } catch { sent = false }
      do { try await link.channel.sendData(capabilityV2.encode()) } catch { sent = false }
      do { try await link.channel.sendData(capabilityV1.encode()) } catch { sent = false }
      guard let self, self.links[transport]?.channel.descriptor == descriptor else { return }
      var current = self.links[transport]!
      current.capabilitySending = false
      current.capabilitySent = sent
      self.links[transport] = current
      if sent, !current.subscription.isEmpty { await self.publish(transport, descriptor: descriptor) }
    }
  }

  func retired(_ descriptor: ChannelDescriptor) {
    guard links[descriptor.transport]?.channel.descriptor == descriptor else { return }
    cancelCommands(on: descriptor.transport, descriptor: descriptor)
    links.removeValue(forKey: descriptor.transport)
    pendingSamples.removeValue(forKey: descriptor.transport)
    pendingCatalogUpdates.removeValue(forKey: descriptor.transport)
    sendingCatalogUpdates.remove("\(descriptor.transport):\(descriptor.instance)")
    drainingSamples = drainingSamples.filter { !$0.hasPrefix("\(descriptor.transport):\(descriptor.instance):") }
    updateTicker()
    updatePowerObservation()
  }

  func capacityAvailable(_ descriptor: ChannelDescriptor) {
    guard let link = links[descriptor.transport], link.channel.descriptor == descriptor else { return }
    if !link.capabilitySent { sendCapability(on: descriptor.transport) }
    else {
      drainPendingSamples(on: descriptor.transport, descriptor: descriptor)
      drainPendingCatalogUpdate(on: descriptor.transport, descriptor: descriptor)
      drainPendingCatalogPages(on: descriptor.transport, descriptor: descriptor)
    }
  }

  func handle(_ bytes: Data, on descriptor: ChannelDescriptor) async -> DataHandling {
    guard var link = links[descriptor.transport], link.channel.descriptor == descriptor else { return .discarded }
    let message: MacDeskDeckMessage
    do { guard let decoded = try MacDeskDeckMessage.decode(bytes) else { return .unrecognized }; message = decoded }
    catch { return .discarded }

    if message.kind == 2 {
      let handlingStarted = ProcessInfo.processInfo.systemUptime
      let subscription = message.string(0)
      if link.subscription == subscription, link.protocolVersion == message.version {
        if link.protocolVersion >= 2 { link.lastRenewal = ProcessInfo.processInfo.systemUptime; links[descriptor.transport] = link }
        await publish(descriptor.transport, descriptor: descriptor)
        return .handled
      }
      guard !link.usedSubscriptions.contains(subscription) else { return .discarded }
      cancelCommands(on: descriptor.transport, descriptor: descriptor)
      // Keep a bounded replay window without limiting how long this channel can serve the deck.
      if link.usedSubscriptions.count == 128 { link.usedSubscriptions.removeFirst() }
      link.usedSubscriptions.append(subscription)
      link.subscription = subscription
      link.protocolVersion = message.version
      link.sequence = 0
      link.lastCommand = 0
      link.lastRenewal = ProcessInfo.processInfo.systemUptime
      ensureDefaultApps(for: descriptor.peer)
      links[descriptor.transport] = link
      pendingSamples.removeValue(forKey: descriptor.transport)
      pendingCatalogPages.removeValue(forKey: descriptor.transport)
      pendingCatalogUpdates.removeValue(forKey: descriptor.transport)
      outputVolume.start()
      updateTicker()
      updatePowerObservation()
      await publish(descriptor.transport, descriptor: descriptor)
      Self.logger.info("event=subscription_handled protocol=\(message.version) duration_ms=\(Int((ProcessInfo.processInfo.systemUptime - handlingStarted) * 1000))")
      return .handled
    }
    guard !link.subscription.isEmpty, link.subscription == message.string(0), link.protocolVersion == message.version else { return .discarded }
    if message.kind == 7 {
      link.lastRenewal = ProcessInfo.processInfo.systemUptime
      links[descriptor.transport] = link
      return .handled
    }
    if message.kind == 8, link.protocolVersion >= 2 {
      let page = message.number(1)
      Task { @MainActor [weak self] in
        guard let self else { return }
        _ = await self.sendCatalogPage(page, link: link, descriptor: descriptor)
      }
      return .handled
    }
    if message.kind == 6 {
      cancelCommands(on: descriptor.transport, subscription: message.string(0))
      link.subscription = ""
      links[descriptor.transport] = link
      pendingSamples.removeValue(forKey: descriptor.transport)
      pendingCatalogPages.removeValue(forKey: descriptor.transport)
      updateTicker()
      updatePowerObservation()
      return .handled
    }
    guard message.kind == 4 else { return .unrecognized }
    let commandID = message.number(1)
    guard commandID > link.lastCommand else { return .discarded }
    link.lastCommand = commandID
    links[descriptor.transport] = link
    let subscription = message.string(0)
    let commandTask = Task { @MainActor [weak self] in
      guard let self, !Task.isCancelled, self.isCurrent(descriptor, subscription: subscription) else { return }
      defer { self.forgetCommand(on: descriptor.transport, commandID: commandID, descriptor: descriptor, subscription: subscription) }
      let commandStarted = ProcessInfo.processInfo.systemUptime
      let result = await self.perform(message, link: link)
      guard !Task.isCancelled, self.isCurrent(descriptor, subscription: subscription) else { return }
      let response = MacDeskDeckMessage(version: link.protocolVersion, kind: 5,
        fields: [.text(subscription), .integer(commandID), .integer(result)])
      do { try await link.channel.sendData(response.encode()) } catch { return }
      Self.logger.info("event=command_ack_submitted action=\(message.number(2)) result=\(result) total_ms=\(Int((ProcessInfo.processInfo.systemUptime - commandStarted) * 1000))")
      if result == 0 { await self.publish(descriptor.transport, descriptor: descriptor) }
    }
    commandJobs[descriptor.transport, default: [:]][commandID] = PendingCommandJob(
      descriptor: descriptor, subscription: subscription, task: commandTask)
    return .handled
  }

  private func perform(_ message: MacDeskDeckMessage, link: Link) async -> Int64 {
    let action = message.number(2), target = message.string(3), revision = message.string(4), value = message.number(5)
    switch action {
    case 1:
      guard supportedActions & 1 != 0 else { return 2 }
      return MacDeskDeckLock.request()
    case 2:
      let input = refreshedInput()
      guard input != nil, target == inputTarget, revision == inputRevision else { return input == nil ? 2 : 1 }
      return DeskDeckInputMute.set(input!, muted: value == 1)
    case 3:
      guard supportedActions & 2 != 0 else { return 5 }
      return await Self.launch("org.blenderfoundation.blender")
    case 4:
      guard supportedActions & 4 != 0 else { return 5 }
      return await Self.launch("com.apple.Terminal")
    case 5:
      guard supportedActions & 8 != 0 else { return 5 }
      return await Self.launch("com.apple.screenshot.launcher")
    case 6:
      guard outputVolume.target == target, outputVolume.revision == revision else { return 1 }
      return outputVolume.command(target: target, revision: revision, value: value)
    case 7:
      return 2
    case 8:
      return await launchApprovedApp(id: target, revision: revision, peer: link.channel.descriptor.peer)
    default:
      return 2
    }
  }

  private func publish(_ transport: String, descriptor: ChannelDescriptor, cpuPercentValue: Int64? = nil) async {
    guard var link = links[transport], !link.subscription.isEmpty,
      link.channel.descriptor == descriptor else { return }
    let subscription = link.subscription
    link.sequence = link.sequence >= 4294967295 ? 1 : link.sequence + 1
    links[transport] = link
    outputVolume.refresh()
    let input = refreshedInput()
    let memory = DeskDeckMemory.read()
    let power = DeskDeckPower.read()
    let thermal = Int64(ProcessInfo.processInfo.thermalState.rawValue)
    let outputSupported = outputVolume.level != nil && !outputVolume.target.isEmpty && !outputVolume.revision.isEmpty
    var fields: [SessionCBOR]
    if link.protocolVersion == 1 {
      fields = [
        .text(subscription), .integer(link.sequence), .integer(cpuPercentValue ?? lastCPUPercent),
        .integer(memory.used), .integer(memory.total), .integer(thermal), .integer(supportedActions),
        .bool(outputSupported), .text(outputSupported ? outputVolume.target : ""), .text(outputSupported ? outputVolume.revision : ""),
        .integer(outputSupported ? outputVolume.level! : -1),
        .bool(input != nil), .text(input == nil ? "" : inputTarget), .text(input == nil ? "" : inputRevision), .bool(input?.muted ?? false),
        .bool(false), .text(""), .text(""), .integer(-1),
      ]
    } else {
      fields = [
        .text(subscription), .integer(link.sequence), .integer(cpuPercentValue ?? lastCPUPercent),
        .integer(memory.active), .integer(memory.wired), .integer(memory.compressed), .integer(memory.total),
        .integer(thermal), .integer(supportedActions),
        .bool(outputSupported), .text(outputSupported ? outputVolume.target : ""), .text(outputSupported ? outputVolume.revision : ""),
        .integer(outputSupported ? outputVolume.level! : -1),
        .bool(input != nil), .text(input == nil ? "" : inputTarget), .text(input == nil ? "" : inputRevision), .bool(input?.muted ?? false),
        .integer(power.state), .integer(power.percent), .integer(power.source),
      ]
    }
    if link.protocolVersion == 3 {
      fields += [.integer(memory.app), .integer(memory.cached), .integer(memory.free), .integer(memory.swap)]
    }
    let sample = MacDeskDeckMessage(version: link.protocolVersion, kind: 3, fields: fields)
    guard let bytes = try? sample.encode(), isCurrent(descriptor, subscription: subscription) else { return }
    pendingSamples[transport] = PendingSample(descriptor: descriptor, subscription: subscription, bytes: bytes,
      queuedAt: ProcessInfo.processInfo.systemUptime)
    drainPendingSamples(on: transport, descriptor: descriptor)
  }

  private func drainPendingSamples(on transport: String, descriptor: ChannelDescriptor) {
    guard let pending = pendingSamples[transport],
      pending.descriptor == descriptor else { return }
    let drainKey = "\(transport):\(descriptor.instance):\(pending.subscription)"
    guard drainingSamples.insert(drainKey).inserted else { return }
    Task { @MainActor [weak self] in
      guard let self else { return }
      while let next = self.pendingSamples[transport], next.descriptor == descriptor,
        next.subscription == pending.subscription, self.isCurrent(descriptor, subscription: pending.subscription) {
        self.pendingSamples[transport] = nil
        guard let channel = self.links[transport]?.channel else { break }
        do {
          try await channel.sendData(next.bytes)
          Self.logger.info("event=sample_submitted duration_ms=\(Int((ProcessInfo.processInfo.systemUptime - next.queuedAt) * 1000))")
        }
        catch {
          if self.pendingSamples[transport] == nil, self.isCurrent(descriptor, subscription: next.subscription) {
            self.pendingSamples[transport] = next
          }
          break
        }
      }
      self.drainingSamples.remove(drainKey)
      if let latest = self.pendingSamples[transport], latest.descriptor == descriptor,
        latest.subscription != pending.subscription {
        self.drainPendingSamples(on: transport, descriptor: descriptor)
      }
    }
  }

  private func isCurrent(_ descriptor: ChannelDescriptor, subscription: String) -> Bool {
    links[descriptor.transport]?.channel.descriptor == descriptor &&
      links[descriptor.transport]?.subscription == subscription && !subscription.isEmpty
  }

  private func cancelCommands(on transport: String, descriptor: ChannelDescriptor? = nil, subscription: String? = nil) {
    guard var jobs = commandJobs[transport] else { return }
    let obsoleteIDs = jobs.compactMap { id, job in
      (descriptor == nil || descriptor == job.descriptor) &&
        (subscription == nil || subscription == job.subscription) ? id : nil
    }
    for id in obsoleteIDs {
      jobs[id]?.task.cancel()
      jobs.removeValue(forKey: id)
    }
    commandJobs[transport] = jobs.isEmpty ? nil : jobs
  }

  private func forgetCommand(on transport: String, commandID: Int64, descriptor: ChannelDescriptor, subscription: String) {
    guard var jobs = commandJobs[transport], jobs[commandID]?.descriptor == descriptor,
      jobs[commandID]?.subscription == subscription else { return }
    jobs.removeValue(forKey: commandID)
    commandJobs[transport] = jobs.isEmpty ? nil : jobs
  }

  func approvedApps(for peer: DeviceIdentity) -> [DeskDeckApprovedApp] {
    ensureDefaultApps(for: peer)
    return readCatalog(for: peer).apps
  }

  func availableApprovalCount(for peer: DeviceIdentity) -> Int { validApps(for: peer).count }

  func applicationIsAvailable(_ app: DeskDeckApprovedApp) -> Bool { resolve(app) != nil }

  @discardableResult func addApprovedApp(at url: URL, for peer: DeviceIdentity) -> Bool {
    ensureDefaultApps(for: peer)
    guard let app = makeApproval(at: url) else { return false }
    var catalog = readCatalog(for: peer)
    // A reinstalled app may keep its path and bundle ID while its executable changes.
    catalog.apps.removeAll { resolve($0) == nil }
    guard catalog.apps.count < 32, !catalog.apps.contains(where: { $0.bundleIdentifier == app.bundleIdentifier && $0.path == app.path }) else { return false }
    catalog.apps.append(app)
    catalog.apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    catalog.revision = UUID().uuidString.lowercased()
    writeCatalog(catalog, for: peer)
    refreshAppCatalog(for: peer)
    return true
  }

  func removeApprovedApp(id: String, for peer: DeviceIdentity) {
    var catalog = readCatalog(for: peer)
    guard catalog.apps.contains(where: { $0.id == id }) else { return }
    catalog.apps.removeAll { $0.id == id }
    catalog.revision = UUID().uuidString.lowercased()
    writeCatalog(catalog, for: peer)
    refreshAppCatalog(for: peer)
  }

  func pruneApprovals(keeping peers: [DeviceIdentity]) {
    let trusted = Set(peers.map(\.fingerprint))
    let prefix = "desk-deck.apps."
    var removed = false
    for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
      if !trusted.contains(String(key.dropFirst(prefix.count))) {
        defaults.removeObject(forKey: key)
        removed = true
      }
    }
    if removed { catalogGeneration &+= 1 }
  }

  func clearApprovals() {
    pruneApprovals(keeping: [])
  }

  func refreshAppCatalog(for peer: DeviceIdentity) {
    ensureDefaultApps(for: peer)
    let revision = readCatalog(for: peer).revision
    for (transport, link) in links where link.channel.descriptor.peer == peer && link.protocolVersion >= 2 && !link.subscription.isEmpty {
      pendingCatalogPages.removeValue(forKey: transport)
      pendingCatalogUpdates[transport] = PendingCatalogUpdate(
        descriptor: link.channel.descriptor, subscription: link.subscription, revision: revision)
      drainPendingCatalogUpdate(on: transport, descriptor: link.channel.descriptor)
    }
  }

  private func drainPendingCatalogUpdate(on transport: String, descriptor: ChannelDescriptor) {
    let drainKey = "\(transport):\(descriptor.instance)"
    guard sendingCatalogUpdates.insert(drainKey).inserted else { return }
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.sendingCatalogUpdates.remove(drainKey) }
      while let update = self.pendingCatalogUpdates[transport], update.descriptor == descriptor {
        guard self.isCurrent(descriptor, subscription: update.subscription) else {
          self.pendingCatalogUpdates.removeValue(forKey: transport)
          return
        }
        let message = MacDeskDeckMessage(version: self.links[transport]?.protocolVersion ?? 2, kind: 10, fields: [
          .text(update.subscription), .text(update.revision),
        ])
        do { try await self.links[transport]?.channel.sendData(message.encode()) }
        catch { return }
        if self.pendingCatalogUpdates[transport] == update {
          self.pendingCatalogUpdates.removeValue(forKey: transport)
        }
      }
    }
  }

  @discardableResult private func sendCatalogPage(_ page: Int64, link: Link, descriptor: ChannelDescriptor) async -> Bool {
    guard page >= 0, link.protocolVersion >= 2, isCurrent(descriptor, subscription: link.subscription) else { return false }
    let apps = validApps(for: descriptor.peer)
    let pageCount = max(1, (apps.count + 7) / 8)
    guard page < pageCount else { return false }
    let entries: [SessionCBOR] = apps.dropFirst(Int(page) * 8).prefix(8).map {
      SessionCBOR.array([SessionCBOR.text($0.id), SessionCBOR.text($0.name)])
    }
    let catalog = readCatalog(for: descriptor.peer)
    let message = MacDeskDeckMessage(version: link.protocolVersion, kind: 9, fields: [
      .text(link.subscription), .integer(page), .integer(Int64(pageCount)), .text(catalog.revision), .array(entries),
    ])
    guard let bytes = try? message.encode() else { return false }
    do { try await link.channel.sendData(bytes); return true }
    catch {
      let pending = PendingCatalogPage(descriptor: descriptor, subscription: link.subscription, page: page)
      if pendingCatalogPages[descriptor.transport]?.contains(where: { $0.page == page && $0.subscription == link.subscription }) != true {
        pendingCatalogPages[descriptor.transport, default: []].append(pending)
      }
      return false
    }
  }

  private func drainPendingCatalogPages(on transport: String, descriptor: ChannelDescriptor) {
    guard let pending = pendingCatalogPages[transport]?.first, pending.descriptor == descriptor,
      let link = links[transport], link.subscription == pending.subscription else { return }
    pendingCatalogPages[transport]?.removeFirst()
    Task { @MainActor [weak self] in
      guard let self else { return }
      if await self.sendCatalogPage(pending.page, link: link, descriptor: descriptor) {
        self.drainPendingCatalogPages(on: transport, descriptor: descriptor)
      }
    }
  }

  private func ensureDefaultApps(for peer: DeviceIdentity) {
    guard defaults.data(forKey: catalogKey(peer)) == nil else { return }
    let defaultsToOffer = ["com.apple.Terminal", "org.blenderfoundation.blender"].compactMap { bundleID -> DeskDeckApprovedApp? in
      guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
      return makeApproval(at: url)
    }
    writeCatalog(DeskDeckAppCatalog(revision: UUID().uuidString.lowercased(), apps: defaultsToOffer), for: peer)
  }

  private func makeApproval(at url: URL) -> DeskDeckApprovedApp? {
    guard let bundle = Bundle(url: url), let bundleIdentifier = bundle.bundleIdentifier,
      let resourceIdentifier = resourceID(at: url), let executableURL = bundle.executableURL,
      let executableResourceIdentifier = resourceID(at: executableURL) else { return nil }
    let rawName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
      ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
      ?? url.deletingPathExtension().lastPathComponent
    let safeName = rawName.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
      .trimmingCharacters(in: .whitespacesAndNewlines)
    var name = ""
    for character in safeName {
      guard (name + String(character)).utf16.count <= 80 else { break }
      name.append(character)
    }
    guard !name.isEmpty else { return nil }
    return DeskDeckApprovedApp(id: UUID().uuidString.lowercased(), bundleIdentifier: bundleIdentifier,
      name: name, path: url.standardizedFileURL.path, resourceIdentifier: resourceIdentifier,
      executableResourceIdentifier: executableResourceIdentifier)
  }

  private func resolve(_ app: DeskDeckApprovedApp) -> URL? {
    let url = URL(fileURLWithPath: app.path).standardizedFileURL
    guard FileManager.default.fileExists(atPath: url.path), resourceID(at: url) == app.resourceIdentifier,
      let bundle = Bundle(url: url), bundle.bundleIdentifier == app.bundleIdentifier,
      let executableURL = bundle.executableURL,
      resourceID(at: executableURL) == app.executableResourceIdentifier else { return nil }
    return url
  }

  private func resourceID(at url: URL) -> String? {
    guard let identifier = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier else { return nil }
    return String(describing: identifier)
  }

  private func launchApprovedApp(id: String, revision: String, peer: DeviceIdentity) async -> Int64 {
    let catalog = readCatalog(for: peer)
    guard catalog.revision == revision, let app = catalog.apps.first(where: { $0.id == id }) else { return 1 }
    guard let url = resolve(app) else { return 5 }
    do { _ = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()); return 0 }
    catch { return 7 }
  }

  private func validApps(for peer: DeviceIdentity) -> [DeskDeckApprovedApp] {
    readCatalog(for: peer).apps.filter { resolve($0) != nil }.prefix(32).map { $0 }
  }

  private func catalogKey(_ peer: DeviceIdentity) -> String { "desk-deck.apps.\(peer.fingerprint)" }

  private func readCatalog(for peer: DeviceIdentity) -> DeskDeckAppCatalog {
    if let data = defaults.data(forKey: catalogKey(peer)), let catalog = try? JSONDecoder().decode(DeskDeckAppCatalog.self, from: data) { return catalog }
    return DeskDeckAppCatalog(revision: UUID().uuidString.lowercased(), apps: [])
  }

  private func writeCatalog(_ catalog: DeskDeckAppCatalog, for peer: DeviceIdentity) {
    guard let data = try? JSONEncoder().encode(catalog) else { return }
    defaults.set(data, forKey: catalogKey(peer))
    catalogGeneration &+= 1
  }

  private func updatePowerObservation() {
    let needsPower = links.values.contains { $0.protocolVersion >= 2 && !$0.subscription.isEmpty }
    if needsPower, powerSource == nil {
      let context = Unmanaged.passUnretained(self).toOpaque()
      if let source = IOPSNotificationCreateRunLoopSource(Self.powerChangeCallback, context)?.takeRetainedValue() {
        powerSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
      }
    } else if !needsPower { stopPowerObservation() }
  }

  private func stopPowerObservation() {
    guard let powerSource else { return }
    CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes)
    CFRunLoopSourceInvalidate(powerSource)
    self.powerSource = nil
  }

  private func powerSourceDidChange() {
    for link in links.values where link.protocolVersion >= 2 && !link.subscription.isEmpty {
      Task { await publish(link.channel.descriptor.transport, descriptor: link.channel.descriptor) }
    }
  }

  private func refreshCapabilities() {
    let updated = Self.actionMask
    guard updated != supportedActions else { return }
    supportedActions = updated
    for transport in Array(links.keys) {
      guard var link = links[transport] else { continue }
      link.capabilitySent = false
      links[transport] = link
      let descriptor = link.channel.descriptor
      let hasSubscription = !link.subscription.isEmpty
      sendCapability(on: transport)
      if hasSubscription { Task { await publish(transport, descriptor: descriptor) } }
    }
  }

  private func refreshedInput() -> InputMuteDevice? {
    let input = DeskDeckInputMute.read()
    guard let input else {
      inputIdentity = ""; inputTarget = ""; inputRevision = ""; inputMuted = nil
      return nil
    }
    if input.identity != inputIdentity {
      inputIdentity = input.identity
      inputTarget = UUID().uuidString.lowercased()
      inputRevision = UUID().uuidString.lowercased()
      inputMuted = input.muted
    } else if inputMuted != input.muted {
      inputRevision = UUID().uuidString.lowercased()
      inputMuted = input.muted
    }
    return input
  }

  private func cpuPercent() -> Int64 {
    var processorCount: natural_t = 0
    var info: processor_info_array_t?
    var infoCount: mach_msg_type_number_t = 0
    let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &processorCount, &info, &infoCount)
    guard result == KERN_SUCCESS, let info else { return -1 }
    defer {
      _ = vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))
    }
    let current = (0..<Int(processorCount) * Int(CPU_STATE_MAX)).map { UInt32(bitPattern: info[$0]) }
    defer { previousCPUTicks = current }
    guard let previousCPUTicks else { return -1 }
    return DeskDeckCPU.percentage(previous: previousCPUTicks, current: current)
  }

  private func updateTicker() {
    let active = links.values.contains { !$0.subscription.isEmpty }
    if active, ticker == nil {
      // All visible subscriptions share one ticker; its generation fences obsolete task cleanup.
      tickerGeneration &+= 1
      let generation = tickerGeneration
      // Only the ticker advances the CPU baseline; commands and power changes reuse its last interval.
      lastCPUPercent = cpuPercent()
      ticker = Task { @MainActor [weak self] in
        while !Task.isCancelled {
          do { try await Task.sleep(for: .seconds(1)) } catch { break }
          guard !Task.isCancelled, let self, self.tickerGeneration == generation else { break }
          let now = ProcessInfo.processInfo.systemUptime
          for transport in Array(self.links.keys) {
            guard var link = self.links[transport], link.protocolVersion >= 2,
              !link.subscription.isEmpty, now - link.lastRenewal >= 15 else { continue }
            link.subscription = ""
            self.links[transport] = link
            self.pendingSamples.removeValue(forKey: transport)
            self.pendingCatalogPages.removeValue(forKey: transport)
          }
          self.updatePowerObservation()
          if !self.links.values.contains(where: { !$0.subscription.isEmpty }) {
            self.updateTicker()
            break
          }
          let cpu = self.cpuPercent()
          self.lastCPUPercent = cpu
          for link in Array(self.links.values) where !link.subscription.isEmpty {
            await self.publish(link.channel.descriptor.transport, descriptor: link.channel.descriptor, cpuPercentValue: cpu)
          }
        }
        guard let self else { return }
        guard self.tickerGeneration == generation else { return }
        self.ticker = nil
        if self.links.values.contains(where: { !$0.subscription.isEmpty }) { self.updateTicker() }
      }
    } else if !active {
      tickerGeneration &+= 1
      ticker?.cancel(); ticker = nil
      pendingSamples.removeAll()
      outputVolume.stop()
      previousCPUTicks = nil
      lastCPUPercent = -1
    }
  }

  private static var actionMask: Int64 {
    var mask: Int64 = 0
    if MacDeskDeckLock.hasEventPostingAccess { mask |= 1 }
    if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.blenderfoundation.blender") != nil { mask |= 2 }
    if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") != nil { mask |= 4 }
    if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.screenshot.launcher") != nil { mask |= 8 }
    return mask
  }

  private static func launch(_ bundleID: String) async -> Int64 {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return 5 }
    do { _ = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()); return 0 }
    catch { return 7 }
  }
}

private enum MacDeskDeckLock {
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
