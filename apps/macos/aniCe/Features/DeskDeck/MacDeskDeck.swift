// SPDX-License-Identifier: GPL-3.0-or-later
// Owns Desk Deck subscriptions, approvals and authenticated command state.
import AppKit
import CoreAudio
import CoreGraphics
import Foundation
import IOKit.ps
import Observation
import Darwin
import UniformTypeIdentifiers
import os

private struct MacDeskDeckOutputRoute: Equatable {
  let id: String
  let uid: String
  let name: String
}

struct DeskDeckApprovedApp: Codable, Equatable, Identifiable {
  let id: String
  let bundleIdentifier: String
  let name: String
  let path: String
  let resourceIdentifier: String
  let executableResourceIdentifier: String?
}

private struct MacDeskDeckApprovedFocusShortcut: Codable {
  let identifier: String
  let name: String
}

private struct DeskDeckAppCatalog: Codable {
  var revision: String
  var apps: [DeskDeckApprovedApp]
}

@Observable @MainActor final class MacDeskDeckModel: FeatureHandler {
  private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "aniCe", category: "DeskDeck")
  private static let focusShortcutDefaultsKey = "desk-deck.focus-shortcut"
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
  private var approvedFocusShortcut: MacDeskDeckApprovedFocusShortcut?
  private var approvedFocusShortcutIsAvailable = false
  private(set) var availableFocusShortcuts: [MacDeskDeckSystemShortcut] = []
  private(set) var focusShortcutStatus = ""
  private(set) var isLoadingFocusShortcuts = false
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
  private struct PendingOutputCatalogPage {
    let descriptor: ChannelDescriptor
    let subscription: String
    let page: Int64
  }
  private struct PendingOutputCatalogUpdate: Equatable {
    let descriptor: ChannelDescriptor
    let subscription: String
    let revision: String
  }
  private var pendingCatalogPages: [String: [PendingCatalogPage]] = [:]
  private var pendingCatalogUpdates: [String: PendingCatalogUpdate] = [:]
  private var sendingCatalogUpdates = Set<String>()
  private var pendingOutputCatalogPages: [String: [PendingOutputCatalogPage]] = [:]
  private var pendingOutputCatalogUpdates: [String: PendingOutputCatalogUpdate] = [:]
  private var sendingOutputCatalogUpdates = Set<String>()
  private var outputObservation: DeskDeckOutputObservation?
  private var outputRouteIDs: [String: String] = [:]
  private var outputRoutes: [MacDeskDeckOutputRoute] = []
  private var outputCatalogRevision = UUID().uuidString.lowercased()
  private var previousCPUTicks: [UInt32]?
  private var lastCPUPercent: Int64 = -1
  private var inputIdentity = ""
  private var inputTarget = ""
  private var inputRevision = ""
  private var inputMuted: Bool?
  private(set) var catalogGeneration = 0

  init() {
    if let data = UserDefaults.standard.data(forKey: Self.focusShortcutDefaultsKey) {
      if let saved = try? JSONDecoder().decode(MacDeskDeckApprovedFocusShortcut.self, from: data),
        UUID(uuidString: saved.identifier) != nil, !saved.name.isEmpty, saved.name.utf16.count <= 80 {
        approvedFocusShortcut = saved
      } else {
        UserDefaults.standard.removeObject(forKey: Self.focusShortcutDefaultsKey)
      }
    }
    supportedActions = Self.actionMask(focusShortcutConfigured: false)
    activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
      object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.refreshCapabilities() } }
  }

  var approvedFocusShortcutName: String? { approvedFocusShortcut?.name }

  func refreshFocusShortcuts() async {
    guard !isLoadingFocusShortcuts else { return }
    isLoadingFocusShortcuts = true
    focusShortcutStatus = "Checking Shortcuts…"
    let result = await MacDeskDeckShortcutRunner.list()
    availableFocusShortcuts = result.shortcuts
    approvedFocusShortcutIsAvailable = result.available && approvedFocusShortcut.map { approved in
      result.shortcuts.contains { $0.identifier.caseInsensitiveCompare(approved.identifier) == .orderedSame }
    } == true
    focusShortcutStatus = if !result.available {
      "Shortcuts could not be read. Open Shortcuts on this Mac and try again."
    } else if approvedFocusShortcut != nil && !approvedFocusShortcutIsAvailable {
      "The saved Shortcut was not found. Choose a replacement or remove its selection."
    } else if result.shortcuts.isEmpty {
      "No Shortcuts found. Create the Mac-local DND toggle, then refresh."
    } else if approvedFocusShortcutIsAvailable {
      "Selected. Test that Focus changes; aniCe confirms only that the Shortcut ran."
    } else {
      "Choose the shortcut to use for Do Not Disturb."
    }
    isLoadingFocusShortcuts = false
    refreshCapabilities()
  }

  func approveFocusShortcut(_ shortcut: MacDeskDeckSystemShortcut) {
    guard availableFocusShortcuts.contains(shortcut), UUID(uuidString: shortcut.identifier) != nil,
      !shortcut.name.isEmpty, shortcut.name.utf16.count <= 80 else { return }
    approvedFocusShortcut = MacDeskDeckApprovedFocusShortcut(identifier: shortcut.identifier, name: shortcut.name)
    approvedFocusShortcutIsAvailable = true
    if let data = try? JSONEncoder().encode(approvedFocusShortcut) {
      defaults.set(data, forKey: Self.focusShortcutDefaultsKey)
    }
    focusShortcutStatus = "Selected. Test that Focus changes; aniCe confirms only that the Shortcut ran."
    refreshCapabilities()
  }

  func removeFocusShortcut() {
    approvedFocusShortcut = nil
    approvedFocusShortcutIsAvailable = false
    defaults.removeObject(forKey: Self.focusShortcutDefaultsKey)
    focusShortcutStatus = "No Do Not Disturb Shortcut selected."
    refreshCapabilities()
  }

  func shutdown() {
    if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    activationObserver = nil
    stopPowerObservation()
    outputObservation = nil
    tickerGeneration &+= 1
    ticker?.cancel(); ticker = nil
    for jobs in commandJobs.values { jobs.values.forEach { $0.task.cancel() } }
    commandJobs.removeAll()
    pendingSamples.removeAll()
    pendingCatalogPages.removeAll()
    pendingCatalogUpdates.removeAll()
    sendingCatalogUpdates.removeAll()
    pendingOutputCatalogPages.removeAll()
    pendingOutputCatalogUpdates.removeAll()
    sendingOutputCatalogUpdates.removeAll()
    outputVolume.stop()
    previousCPUTicks = nil
  }

  func available(_ channel: any SecuredChannel) {
    let descriptor = channel.descriptor
    pendingCatalogUpdates.removeValue(forKey: descriptor.transport)
    pendingOutputCatalogUpdates.removeValue(forKey: descriptor.transport)
    links[descriptor.transport] = Link(channel: channel)
    sendCapability(on: descriptor.transport)
  }

  private func sendCapability(on transport: String) {
    guard var link = links[transport], !link.capabilitySent, !link.capabilitySending else { return }
    link.capabilitySending = true
    links[transport] = link
    let currentActions = supportedActions
    let legacyActions = currentActions & 15
    let capabilityV5 = MacDeskDeckMessage(version: 5, kind: 1, fields: [.integer(currentActions)])
    let capabilityV4 = MacDeskDeckMessage(version: 4, kind: 1, fields: [.integer(currentActions & 31)])
    let capabilityV3 = MacDeskDeckMessage(version: 3, kind: 1, fields: [.integer(legacyActions)])
    let capabilityV2 = MacDeskDeckMessage(version: 2, kind: 1, fields: [.integer(legacyActions)])
    let capabilityV1 = MacDeskDeckMessage(kind: 1, fields: [.integer(legacyActions)])
    let descriptor = link.channel.descriptor
    Task { @MainActor [weak self] in
      var sent = true
      do { try await link.channel.sendData(capabilityV5.encode()) } catch { sent = false }
      do { try await link.channel.sendData(capabilityV4.encode()) } catch { sent = false }
      do { try await link.channel.sendData(capabilityV3.encode()) } catch { sent = false }
      do { try await link.channel.sendData(capabilityV2.encode()) } catch { sent = false }
      do { try await link.channel.sendData(capabilityV1.encode()) } catch { sent = false }
      guard let self, self.links[transport]?.channel.descriptor == descriptor else { return }
      var current = self.links[transport]!
      current.capabilitySending = false
      let actionsChanged = self.supportedActions != currentActions
      current.capabilitySent = sent && !actionsChanged
      self.links[transport] = current
      if actionsChanged {
        self.sendCapability(on: transport)
      } else if sent, !current.subscription.isEmpty {
        await self.publish(transport, descriptor: descriptor)
      }
    }
  }

  func retired(_ descriptor: ChannelDescriptor) {
    guard links[descriptor.transport]?.channel.descriptor == descriptor else { return }
    cancelCommands(on: descriptor.transport, descriptor: descriptor)
    links.removeValue(forKey: descriptor.transport)
    pendingSamples.removeValue(forKey: descriptor.transport)
    pendingCatalogUpdates.removeValue(forKey: descriptor.transport)
    pendingOutputCatalogUpdates.removeValue(forKey: descriptor.transport)
    pendingOutputCatalogPages.removeValue(forKey: descriptor.transport)
    sendingCatalogUpdates.remove("\(descriptor.transport):\(descriptor.instance)")
    sendingOutputCatalogUpdates.remove("\(descriptor.transport):\(descriptor.instance)")
    drainingSamples = drainingSamples.filter { !$0.hasPrefix("\(descriptor.transport):\(descriptor.instance):") }
    updateTicker()
    updatePowerObservation()
    updateOutputObservation()
  }

  func capacityAvailable(_ descriptor: ChannelDescriptor) {
    guard let link = links[descriptor.transport], link.channel.descriptor == descriptor else { return }
    if !link.capabilitySent { sendCapability(on: descriptor.transport) }
    else {
      drainPendingSamples(on: descriptor.transport, descriptor: descriptor)
      drainPendingCatalogUpdate(on: descriptor.transport, descriptor: descriptor)
      drainPendingCatalogPages(on: descriptor.transport, descriptor: descriptor)
      drainPendingOutputCatalogUpdate(on: descriptor.transport, descriptor: descriptor)
      drainPendingOutputCatalogPages(on: descriptor.transport, descriptor: descriptor)
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
      pendingOutputCatalogPages.removeValue(forKey: descriptor.transport)
      pendingOutputCatalogUpdates.removeValue(forKey: descriptor.transport)
      if link.protocolVersion >= 5 { refreshOutputCatalog(notify: false) }
      outputVolume.start()
      updateTicker()
      updatePowerObservation()
      updateOutputObservation()
      if approvedFocusShortcut != nil, !isLoadingFocusShortcuts {
        Task { @MainActor [weak self] in await self?.refreshFocusShortcuts() }
      }
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
    if message.kind == 11, link.protocolVersion >= 5 {
      let page = message.number(1)
      Task { @MainActor [weak self] in
        guard let self else { return }
        _ = await self.sendOutputCatalogPage(page, link: link, descriptor: descriptor)
      }
      return .handled
    }
    if message.kind == 6 {
      cancelCommands(on: descriptor.transport, subscription: message.string(0))
      link.subscription = ""
      links[descriptor.transport] = link
      pendingSamples.removeValue(forKey: descriptor.transport)
      pendingCatalogPages.removeValue(forKey: descriptor.transport)
      pendingOutputCatalogPages.removeValue(forKey: descriptor.transport)
      pendingOutputCatalogUpdates.removeValue(forKey: descriptor.transport)
      updateTicker()
      updatePowerObservation()
      updateOutputObservation()
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
    case 9:
      guard link.protocolVersion >= 4, supportedActions & 16 != 0, approvedFocusShortcutIsAvailable,
        let shortcut = approvedFocusShortcut else { return 5 }
      let result = await MacDeskDeckShortcutRunner.run(identifier: shortcut.identifier)
      if result == 0 {
        focusShortcutStatus = "Shortcut ran. Focus state was not checked."
      } else {
        focusShortcutStatus = "Shortcut failed or timed out. Check its actions and permissions, then retry."
      }
      return result
    case 10:
      guard link.protocolVersion >= 5, supportedActions & 32 != 0 else { return 2 }
      refreshOutputCatalog(notify: true)
      guard revision == outputCatalogRevision,
        let route = outputRoutes.first(where: { $0.id == target }) else { return 1 }
      let requested = DeskDeckOutputDevices.selectDefault(uid: route.uid)
      guard requested == 0 else { return requested }
      // Core Audio may apply a default-device change asynchronously; wait for its reported state before acknowledging it.
      for _ in 0..<10 {
        if DeskDeckOutputDevices.defaultUID() == route.uid { return 0 }
        if Task.isCancelled { return 6 }
        try? await Task.sleep(for: .milliseconds(100))
      }
      return DeskDeckOutputDevices.defaultUID() == route.uid ? 0 : 7
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
    let actionMask = link.protocolVersion >= 5 ? supportedActions : link.protocolVersion >= 4 ? supportedActions & 31 : supportedActions & 15
    let selectedOutputRoute = link.protocolVersion >= 5 ? DeskDeckOutputDevices.defaultUID().flatMap { uid in outputRoutes.first(where: { $0.uid == uid })?.id } ?? "" : ""
    let outputSupported = outputVolume.level != nil && !outputVolume.target.isEmpty && !outputVolume.revision.isEmpty
    var fields: [SessionCBOR]
    if link.protocolVersion == 1 {
      fields = [
        .text(subscription), .integer(link.sequence), .integer(cpuPercentValue ?? lastCPUPercent),
        .integer(memory.used), .integer(memory.total), .integer(thermal), .integer(actionMask),
        .bool(outputSupported), .text(outputSupported ? outputVolume.target : ""), .text(outputSupported ? outputVolume.revision : ""),
        .integer(outputSupported ? outputVolume.level! : -1),
        .bool(input != nil), .text(input == nil ? "" : inputTarget), .text(input == nil ? "" : inputRevision), .bool(input?.muted ?? false),
        .bool(false), .text(""), .text(""), .integer(-1),
      ]
    } else {
      fields = [
        .text(subscription), .integer(link.sequence), .integer(cpuPercentValue ?? lastCPUPercent),
        .integer(memory.active), .integer(memory.wired), .integer(memory.compressed), .integer(memory.total),
        .integer(thermal), .integer(actionMask),
        .bool(outputSupported), .text(outputSupported ? outputVolume.target : ""), .text(outputSupported ? outputVolume.revision : ""),
        .integer(outputSupported ? outputVolume.level! : -1),
        .bool(input != nil), .text(input == nil ? "" : inputTarget), .text(input == nil ? "" : inputRevision), .bool(input?.muted ?? false),
        .integer(power.state), .integer(power.percent), .integer(power.source),
      ]
    }
    if link.protocolVersion >= 3 {
      fields += [.integer(memory.app), .integer(memory.cached), .integer(memory.free), .integer(memory.swap)]
    }
    if link.protocolVersion >= 5 { fields.append(.text(selectedOutputRoute)) }
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

  private func refreshOutputCatalog(notify: Bool) {
    var ids: [String: String] = [:]
    let available = DeskDeckOutputDevices.available().sorted {
      let order = $0.name.localizedCaseInsensitiveCompare($1.name)
      return order == .orderedSame ? $0.uid < $1.uid : order == .orderedAscending
    }
    let defaultUID = DeskDeckOutputDevices.defaultUID()
    var boundedRoutes = Array(available.prefix(32))
    if let current = available.first(where: { $0.uid == defaultUID }),
      !boundedRoutes.contains(where: { $0.uid == current.uid }) {
      boundedRoutes[boundedRoutes.count - 1] = current
    }
    let next = boundedRoutes.sorted {
      let order = $0.name.localizedCaseInsensitiveCompare($1.name)
      return order == .orderedSame ? $0.uid < $1.uid : order == .orderedAscending
    }.map { native in
      // Keep Core Audio UIDs local; only random catalog IDs cross the trusted DATA channel.
      let id = outputRouteIDs[native.uid] ?? UUID().uuidString.lowercased()
      ids[native.uid] = id
      return MacDeskDeckOutputRoute(id: id, uid: native.uid, name: native.name)
    }
    guard next != outputRoutes else { return }
    outputRoutes = next
    outputRouteIDs = ids
    outputCatalogRevision = UUID().uuidString.lowercased()
    guard notify else { return }
    for (transport, link) in links where link.protocolVersion >= 5 && !link.subscription.isEmpty {
      pendingOutputCatalogPages.removeValue(forKey: transport)
      pendingOutputCatalogUpdates[transport] = PendingOutputCatalogUpdate(
        descriptor: link.channel.descriptor, subscription: link.subscription, revision: outputCatalogRevision)
      drainPendingOutputCatalogUpdate(on: transport, descriptor: link.channel.descriptor)
    }
  }

  private func updateOutputObservation() {
    let needed = links.values.contains { $0.protocolVersion >= 5 && !$0.subscription.isEmpty }
    if needed, outputObservation == nil {
      outputObservation = DeskDeckOutputObservation { [weak self] in
        Task { @MainActor [weak self] in
          guard let self, self.outputObservation != nil,
            self.links.values.contains(where: { $0.protocolVersion >= 5 && !$0.subscription.isEmpty }) else { return }
          self.refreshOutputCatalog(notify: true)
          for transport in Array(self.links.keys) {
            guard let link = self.links[transport], link.protocolVersion >= 5, !link.subscription.isEmpty else { continue }
            await self.publish(transport, descriptor: link.channel.descriptor)
          }
        }
      }
      refreshOutputCatalog(notify: false)
    } else if !needed {
      outputObservation = nil
    }
  }

  @discardableResult private func sendOutputCatalogPage(_ page: Int64, link: Link, descriptor: ChannelDescriptor) async -> Bool {
    guard page >= 0, link.protocolVersion >= 5, isCurrent(descriptor, subscription: link.subscription) else { return false }
    if page == 0 { refreshOutputCatalog(notify: true) }
    let pageCount = max(1, (outputRoutes.count + 7) / 8)
    guard page < pageCount else { return false }
    let entries: [SessionCBOR] = outputRoutes.dropFirst(Int(page) * 8).prefix(8).map {
      SessionCBOR.array([.text($0.id), .text($0.name)])
    }
    let message = MacDeskDeckMessage(version: 5, kind: 12, fields: [
      .text(link.subscription), .integer(page), .integer(Int64(pageCount)), .text(outputCatalogRevision), .array(entries),
    ])
    guard let bytes = try? message.encode() else { return false }
    do { try await link.channel.sendData(bytes); return true }
    catch {
      let pending = PendingOutputCatalogPage(descriptor: descriptor, subscription: link.subscription, page: page)
      if pendingOutputCatalogPages[descriptor.transport]?.contains(where: { $0.page == page && $0.subscription == link.subscription }) != true {
        pendingOutputCatalogPages[descriptor.transport, default: []].append(pending)
      }
      return false
    }
  }

  private func drainPendingOutputCatalogUpdate(on transport: String, descriptor: ChannelDescriptor) {
    let drainKey = "\(transport):\(descriptor.instance)"
    guard sendingOutputCatalogUpdates.insert(drainKey).inserted else { return }
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.sendingOutputCatalogUpdates.remove(drainKey) }
      while let update = self.pendingOutputCatalogUpdates[transport], update.descriptor == descriptor {
        guard self.isCurrent(descriptor, subscription: update.subscription) else {
          self.pendingOutputCatalogUpdates.removeValue(forKey: transport)
          return
        }
        let message = MacDeskDeckMessage(version: 5, kind: 13, fields: [
          .text(update.subscription), .text(update.revision),
        ])
        do { try await self.links[transport]?.channel.sendData(message.encode()) }
        catch { return }
        if self.pendingOutputCatalogUpdates[transport] == update {
          self.pendingOutputCatalogUpdates.removeValue(forKey: transport)
        }
      }
    }
  }

  private func drainPendingOutputCatalogPages(on transport: String, descriptor: ChannelDescriptor) {
    guard let pending = pendingOutputCatalogPages[transport]?.first, pending.descriptor == descriptor,
      let link = links[transport], link.subscription == pending.subscription else { return }
    pendingOutputCatalogPages[transport]?.removeFirst()
    Task { @MainActor [weak self] in
      guard let self else { return }
      if await self.sendOutputCatalogPage(pending.page, link: link, descriptor: descriptor) {
        self.drainPendingOutputCatalogPages(on: transport, descriptor: descriptor)
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
    let updated = Self.actionMask(focusShortcutConfigured: approvedFocusShortcutIsAvailable)
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
            self.pendingOutputCatalogPages.removeValue(forKey: transport)
            self.pendingOutputCatalogUpdates.removeValue(forKey: transport)
          }
          self.updatePowerObservation()
          self.updateOutputObservation()
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

  private static func actionMask(focusShortcutConfigured: Bool) -> Int64 {
    var mask: Int64 = 0
    if MacDeskDeckLock.hasEventPostingAccess { mask |= 1 }
    if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.blenderfoundation.blender") != nil { mask |= 2 }
    if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") != nil { mask |= 4 }
    if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.screenshot.launcher") != nil { mask |= 8 }
    if focusShortcutConfigured { mask |= 16 }
    if DeskDeckOutputDevices.canSelectDefault { mask |= 32 }
    return mask
  }

  private static func launch(_ bundleID: String) async -> Int64 {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return 5 }
    do { _ = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()); return 0 }
    catch { return 7 }
  }
}
