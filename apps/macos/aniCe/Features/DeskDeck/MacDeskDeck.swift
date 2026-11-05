// SPDX-License-Identifier: GPL-3.0-or-later
// Serves foreground Android Desk Deck telemetry and native Mac controls over secured DATA.
import AppKit
import CoreAudio
import Foundation
import IOKit
import Observation
import Darwin

enum MacDeskDeckWireError: Error { case malformed }

struct MacDeskDeckMessage {
  let kind: Int64
  let fields: [SessionCBOR]

  func encode() throws -> Data {
    try validate()
    let data = try SessionCbor.encode(.array([.text("aniCe desk deck"), .integer(1), .integer(kind), .array(fields)]), maximumBytes: 512)
    guard data.count <= 512 else { throw MacDeskDeckWireError.malformed }
    return data
  }

  static func decode(_ data: Data) throws -> Self? {
    guard data.count <= 4000 else { throw MacDeskDeckWireError.malformed }
    guard case .array(let row) = try SessionCbor.decode(data), case .text("aniCe desk deck")? = row.first else { return nil }
    guard data.count <= 512, row.count == 4, row[1] == .integer(1), case .integer(let kind) = row[2], case .array(let fields) = row[3] else {
      throw MacDeskDeckWireError.malformed
    }
    let message = Self(kind: kind, fields: fields)
    try message.validate()
    return message
  }

  func number(_ index: Int) -> Int64 { if fields.indices.contains(index), case .integer(let value) = fields[index] { return value }; return -1 }
  func string(_ index: Int) -> String { if fields.indices.contains(index), case .text(let value) = fields[index] { return value }; return "" }
  func bool(_ index: Int) -> Bool { if fields.indices.contains(index), case .bool(let value) = fields[index] { return value }; return false }

  private func validate() throws {
    func text(_ i: Int) -> Bool { fields.indices.contains(i) && { if case .text = fields[i] { return true }; return false }() }
    func number(_ i: Int, _ range: ClosedRange<Int64>) -> Bool { fields.indices.contains(i) && { if case .integer(let n) = fields[i] { return range.contains(n) }; return false }() }
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
    case 2, 6: valid = fields.count == 1 && uuid(0)
    case 3:
      valid = fields.count == 19 && uuid(0) && number(1, 1...4294967295) && number(2, -1...100) &&
        validMemory &&
        number(5, 0...3) && number(6, 0...15) && bool(7) && text(8) && text(9) && number(10, -1...100) &&
        bool(11) && text(12) && text(13) && bool(14) && bool(15) && text(16) && text(17) && number(18, -1...100) &&
        validControl(self.bool(7), self.string(8), self.string(9), self.number(10)) && validIdentity(self.bool(11), self.string(12), self.string(13)) &&
        validControl(self.bool(15), self.string(16), self.string(17), self.number(18))
    case 4:
      guard fields.count == 6, uuid(0), number(1, 1...4294967295), number(2, 1...7), text(3), text(4), number(5, -1...100) else {
        throw MacDeskDeckWireError.malformed
      }
      let action = self.number(2), target = self.string(3), revision = self.string(4), value = self.number(5)
      switch action {
      case 1, 3, 4, 5: valid = target.isEmpty && revision.isEmpty && value == -1
      case 2: valid = !target.isEmpty && !revision.isEmpty && (0...1).contains(value)
      case 6, 7: valid = !target.isEmpty && !revision.isEmpty && (0...100).contains(value)
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

private struct DeskDeckMemory {
  let used: Int64
  let total: Int64

  static func read() -> Self {
    let total = Int64(ProcessInfo.processInfo.physicalMemory)
    var statistics = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &statistics) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return Self(used: 0, total: total) }
    let pages = UInt64(statistics.active_count) + UInt64(statistics.wire_count) + UInt64(statistics.compressor_page_count)
    return Self(used: Int64(min(pages * UInt64(getpagesize()), UInt64(total))), total: total)
  }
}

@Observable @MainActor final class MacDeskDeckModel: FeatureHandler {
  private struct Link {
    let channel: any SecuredChannel
    var subscription = ""
    var sequence: Int64 = 0
    var lastCommand: Int64 = 0
    var usedSubscriptions: [String] = []
    var capabilitySent = false
    var capabilitySending = false
  }

  private let supportedActions: Int64
  private var links: [String: Link] = [:]
  private let outputVolume = MacOutputVolume()
  private var ticker: Task<Void, Never>?
  private var previousCPUTicks: [(UInt64, UInt64, UInt64, UInt64)]?
  private var inputIdentity = ""
  private var inputTarget = ""
  private var inputRevision = ""
  private var inputMuted: Bool?

  init() { supportedActions = Self.actionMask }

  func available(_ channel: any SecuredChannel) {
    let descriptor = channel.descriptor
    links[descriptor.transport] = Link(channel: channel)
    sendCapability(on: descriptor.transport)
  }

  private func sendCapability(on transport: String) {
    guard var link = links[transport], !link.capabilitySent, !link.capabilitySending else { return }
    link.capabilitySending = true
    links[transport] = link
    let capability = MacDeskDeckMessage(kind: 1, fields: [.integer(supportedActions)])
    let descriptor = link.channel.descriptor
    Task { @MainActor [weak self] in
      let sent: Bool
      do { try await link.channel.sendData(capability.encode()); sent = true }
      catch { sent = false }
      guard let self, self.links[transport]?.channel.descriptor == descriptor else { return }
      var current = self.links[transport]!
      current.capabilitySending = false
      current.capabilitySent = sent
      self.links[transport] = current
      if sent, !current.subscription.isEmpty { await self.publish(current, descriptor: descriptor) }
    }
  }

  func retired(_ descriptor: ChannelDescriptor) {
    guard links[descriptor.transport]?.channel.descriptor == descriptor else { return }
    links.removeValue(forKey: descriptor.transport)
    updateTicker()
  }

  func capacityAvailable(_ descriptor: ChannelDescriptor) {
    guard let link = links[descriptor.transport], link.channel.descriptor == descriptor else { return }
    if !link.capabilitySent { sendCapability(on: descriptor.transport) }
    else if !link.subscription.isEmpty { Task { await publish(link, descriptor: descriptor) } }
  }

  func handle(_ bytes: Data, on descriptor: ChannelDescriptor) async -> DataHandling {
    guard var link = links[descriptor.transport], link.channel.descriptor == descriptor else { return .discarded }
    let message: MacDeskDeckMessage
    do { guard let decoded = try MacDeskDeckMessage.decode(bytes) else { return .unrecognized }; message = decoded }
    catch { return .discarded }

    if message.kind == 2 {
      let subscription = message.string(0)
      if link.subscription == subscription {
        await publish(link, descriptor: descriptor)
        return .handled
      }
      guard !link.usedSubscriptions.contains(subscription) else { return .discarded }
      // Keep a bounded replay window without limiting how long this channel can serve the deck.
      if link.usedSubscriptions.count == 128 { link.usedSubscriptions.removeFirst() }
      link.usedSubscriptions.append(subscription)
      link.subscription = subscription
      link.sequence = 0
      link.lastCommand = 0
      links[descriptor.transport] = link
      outputVolume.start()
      updateTicker()
      await publish(link, descriptor: descriptor)
      return .handled
    }
    guard !link.subscription.isEmpty, link.subscription == message.string(0) else { return .discarded }
    if message.kind == 6 {
      link.subscription = ""
      links[descriptor.transport] = link
      updateTicker()
      return .handled
    }
    guard message.kind == 4 else { return .unrecognized }
    let commandID = message.number(1)
    guard commandID > link.lastCommand else { return .discarded }
    link.lastCommand = commandID
    links[descriptor.transport] = link
    let result = await perform(message, link: link)
    guard links[descriptor.transport]?.channel.descriptor == descriptor,
      links[descriptor.transport]?.subscription == message.string(0) else { return .discarded }
    let response = MacDeskDeckMessage(kind: 5, fields: [.text(message.string(0)), .integer(commandID), .integer(result)])
    try? await link.channel.sendData(response.encode())
    if result == 0, let current = links[descriptor.transport] { await publish(current, descriptor: descriptor) }
    return .handled
  }

  private func perform(_ message: MacDeskDeckMessage, link: Link) async -> Int64 {
    let action = message.number(2), target = message.string(3), revision = message.string(4), value = message.number(5)
    switch action {
    case 1:
      guard supportedActions & 1 != 0 else { return 2 }
      return Self.run(Self.lockPath, arguments: ["-suspend"])
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
      return Self.run("/usr/sbin/screencapture", arguments: ["-i"])
    case 6:
      guard outputVolume.target == target, outputVolume.revision == revision else { return 1 }
      return outputVolume.command(target: target, revision: revision, value: value)
    case 7:
      return 2
    default:
      return 2
    }
  }

  private func publish(_ previous: Link, descriptor: ChannelDescriptor) async {
    var link = previous
    guard !link.subscription.isEmpty, links[descriptor.transport]?.channel.descriptor == descriptor,
      links[descriptor.transport]?.subscription == link.subscription else { return }
    link.sequence = link.sequence >= 4294967295 ? 1 : link.sequence + 1
    links[descriptor.transport] = link
    outputVolume.refresh()
    let input = refreshedInput()
    let memory = DeskDeckMemory.read()
    let thermal = Int64(ProcessInfo.processInfo.thermalState.rawValue)
    let outputSupported = outputVolume.level != nil && !outputVolume.target.isEmpty && !outputVolume.revision.isEmpty
    let fields: [SessionCBOR] = [
      .text(link.subscription), .integer(link.sequence), .integer(cpuPercent()),
      .integer(memory.used), .integer(memory.total), .integer(thermal), .integer(supportedActions),
      .bool(outputSupported), .text(outputSupported ? outputVolume.target : ""), .text(outputSupported ? outputVolume.revision : ""),
      .integer(outputSupported ? outputVolume.level! : -1),
      .bool(input != nil), .text(input == nil ? "" : inputTarget), .text(input == nil ? "" : inputRevision), .bool(input?.muted ?? false),
      .bool(false), .text(""), .text(""), .integer(-1),
    ]
    let sample = MacDeskDeckMessage(kind: 3, fields: fields)
    try? await link.channel.sendData(sample.encode())
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
    let stride = Int(CPU_STATE_MAX)
    var current: [(UInt64, UInt64, UInt64, UInt64)] = []
    for cpu in 0..<Int(processorCount) {
      let offset = cpu * stride
      func ticks(_ state: Int) -> UInt64 { UInt64(UInt32(bitPattern: info[offset + state])) }
      current.append((ticks(Int(CPU_STATE_USER)), ticks(Int(CPU_STATE_SYSTEM)), ticks(Int(CPU_STATE_NICE)), ticks(Int(CPU_STATE_IDLE))))
    }
    defer { previousCPUTicks = current }
    guard let previousCPUTicks, previousCPUTicks.count == current.count else { return -1 }
    var busy: UInt64 = 0, total: UInt64 = 0
    for index in current.indices {
      let now = current[index], before = previousCPUTicks[index]
      // Mach exposes 32-bit cumulative counters, so compute deltas with wrapping arithmetic.
      let user = now.0 &- before.0, system = now.1 &- before.1, nice = now.2 &- before.2, idle = now.3 &- before.3
      busy &+= user &+ system &+ nice
      total &+= user &+ system &+ nice &+ idle
    }
    guard total > 0 else { return -1 }
    return Int64((Double(busy) * 100 / Double(total)).rounded()).clamped(to: 0...100)
  }

  private func updateTicker() {
    let active = links.values.contains { !$0.subscription.isEmpty }
    if active, ticker == nil {
      ticker = Task { @MainActor [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(1))
          guard !Task.isCancelled, let self else { break }
          for link in Array(self.links.values) where !link.subscription.isEmpty {
            await self.publish(link, descriptor: link.channel.descriptor)
          }
        }
        guard let self else { return }
        self.ticker = nil
        if self.links.values.contains(where: { !$0.subscription.isEmpty }) { self.updateTicker() }
      }
    } else if !active {
      ticker?.cancel(); ticker = nil
      outputVolume.stop()
      previousCPUTicks = nil
    }
  }

  private static let lockPath = "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"
  private static var actionMask: Int64 {
    var mask: Int64 = 0
    if FileManager.default.isExecutableFile(atPath: lockPath) { mask |= 1 }
    if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.blenderfoundation.blender") != nil { mask |= 2 }
    if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") != nil { mask |= 4 }
    if FileManager.default.isExecutableFile(atPath: "/usr/sbin/screencapture") { mask |= 8 }
    return mask
  }

  private static func run(_ path: String, arguments: [String]) -> Int64 {
    guard FileManager.default.isExecutableFile(atPath: path) else { return 5 }
    let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
    do { try process.run(); return 0 } catch { return 7 }
  }

  private static func launch(_ bundleID: String) async -> Int64 {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return 5 }
    do { _ = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()); return 0 }
    catch { return 7 }
  }
}

private extension Int64 {
  func clamped(to range: ClosedRange<Int64>) -> Int64 { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}
