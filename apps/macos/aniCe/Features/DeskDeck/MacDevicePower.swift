// SPDX-License-Identifier: GPL-3.0-or-later
// Exchanges peer power reports on existing authenticated channels.
import Foundation
import IOKit.ps
import Observation

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

  var shortSummary: String {
    guard percent >= 0 else {
      switch state {
      case 3: return "Charging"
      case 4: return "Full"
      case 5: return "Plugged in"
      default: return ""
      }
    }
    switch state {
    case 3: return "\(percent)% (Charging)"
    case 4: return "\(percent)% (Full)"
    case 5: return "\(percent)% (Plugged in)"
    case 2: return "\(percent)%"
    default: return "\(percent)%"
    }
  }
}

@Observable @MainActor final class MacPhonePowerModel: FeatureHandler {
  private final class Link {
    let channel: any SecuredChannel
    var capabilitySent = false
    var sending = false
    var pendingReport: Data?
    init(_ channel: any SecuredChannel) { self.channel = channel }
  }
  private static let powerChangeCallback: IOPowerSourceCallbackType = { context in
    guard let context else { return }
    let model = Unmanaged<MacPhonePowerModel>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { model.powerChanged() }
  }
  private var links: [String: Link] = [:]
  @ObservationIgnored private var powerSource: CFRunLoopSource?
  private var lastPowerReport: Data?
  private var capableTransports = Set<String>()
  private(set) var readings: [String: MacPhonePowerReading] = [:]

  func available(_ channel: any SecuredChannel) {
    let transport = channel.descriptor.transport
    let link = Link(channel)
    links[transport] = link
    capableTransports.remove(transport)
    if powerSource == nil {
      let context = Unmanaged.passUnretained(self).toOpaque()
      if let source = IOPSNotificationCreateRunLoopSource(Self.powerChangeCallback, context)?.takeRetainedValue() {
        powerSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
      }
    }
    let report = powerReport()
    if report != lastPowerReport {
      lastPowerReport = report
      for current in links.values { current.pendingReport = report; drain(current) }
    } else {
      link.pendingReport = report
      drain(link)
    }
  }

  func retired(_ descriptor: ChannelDescriptor) {
    guard links[descriptor.transport]?.channel.descriptor == descriptor else { return }
    links.removeValue(forKey: descriptor.transport)
    capableTransports.remove(descriptor.transport)
    if !links.values.contains(where: { $0.channel.descriptor.peer.fingerprint == descriptor.peer.fingerprint }) {
      readings.removeValue(forKey: descriptor.peer.fingerprint)
    }
    if links.isEmpty { stopPowerObservation(); lastPowerReport = nil }
  }

  func capacityAvailable(_ descriptor: ChannelDescriptor) {
    guard let link = links[descriptor.transport], link.channel.descriptor == descriptor else { return }
    drain(link)
  }

  func handle(_ bytes: Data, on descriptor: ChannelDescriptor) async -> DataHandling {
    guard links[descriptor.transport]?.channel.descriptor == descriptor else { return .discarded }
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

  func shortSummary(for peer: DeviceIdentity?) -> String? {
    guard let peer, let reading = readings[peer.fingerprint] else { return nil }
    let short = reading.shortSummary
    return short.isEmpty ? nil : short
  }

  func shutdown() { stopPowerObservation() }

  private func stopPowerObservation() {
    guard let powerSource else { return }
    CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes)
    CFRunLoopSourceInvalidate(powerSource)
    self.powerSource = nil
  }

  private func powerReport() -> Data? {
    let power = DeskDeckPower.read()
    // Device Power v1 source 3 means USB, whereas Desk Deck uses it for UPS.
    let source: Int64 = power.source == 3 ? 0 : power.source
    return try? MacDevicePowerMessage(kind: 2, state: power.state, percent: power.percent, source: source).encode()
  }

  private func powerChanged() {
    let report = powerReport()
    guard report != lastPowerReport else { return }
    lastPowerReport = report
    for link in links.values { link.pendingReport = report; drain(link) }
  }

  private func drain(_ link: Link) {
    let transport = link.channel.descriptor.transport
    guard !link.sending, links[transport] === link else { return }
    link.sending = true
    Task { [weak self, weak link] in
      guard let self, let link else { return }
      defer { link.sending = false }
      while self.links[transport] === link {
        let capability = !link.capabilitySent
        let bytes = capability ? try? MacDevicePowerMessage(kind: 1, state: 0, percent: -1, source: 0).encode() : link.pendingReport
        guard let bytes else { return }
        if !capability { link.pendingReport = nil }
        do { try await link.channel.sendData(bytes) }
        catch {
          if !capability, link.pendingReport == nil { link.pendingReport = bytes }
          return
        }
        guard self.links[transport] === link else { return }
        if capability { link.capabilitySent = true }
      }
    }
  }
}
