// SPDX-License-Identifier: GPL-3.0-or-later
// Applies phone-originated DND changes through locally selected Mac Shortcuts.
import AppKit
import Foundation
import Observation
import SwiftUI

struct DndSyncMessage: Equatable {
  var kind: Int64
  var sending = false
  var receiving = false
  var id = ""
  var enabled = false
  var result: Int64 = 0

  func encode() throws -> Data {
    let fields: [SessionCBOR]
    switch kind {
    case 1: fields = [.bool(sending), .bool(receiving)]
    case 2: fields = [.text(id), .bool(enabled)]
    case 3: fields = [.text(id), .integer(result)]
    default: throw MacDeskDeckWireError.malformed
    }
    let data = try SessionCbor.encode(.array([.text("aniCe dnd sync"), .integer(1), .integer(kind), .array(fields)]), maximumBytes: 128)
    guard try Self.decode(data) == self else { throw MacDeskDeckWireError.malformed }
    return data
  }

  static func decode(_ bytes: Data) throws -> Self? {
    guard case .array(let row) = try SessionCbor.decode(bytes), row.first == .text("aniCe dnd sync") else { return nil }
    guard bytes.count <= 128, row.count == 4, row[1] == .integer(1), case .integer(let kind) = row[2],
      case .array(let fields) = row[3], fields.count == 2 else { throw MacDeskDeckWireError.malformed }
    if kind == 1 {
      guard case .bool(let sending) = fields[0], case .bool(let receiving) = fields[1] else { throw MacDeskDeckWireError.malformed }
      return Self(kind: kind, sending: sending, receiving: receiving)
    }
    guard case .text(let id) = fields[0], id.count == 36, UUID(uuidString: id)?.uuidString.lowercased() == id else {
      throw MacDeskDeckWireError.malformed
    }
    if kind == 2, case .bool(let enabled) = fields[1] { return Self(kind: kind, id: id, enabled: enabled) }
    if kind == 3, case .integer(let result) = fields[1], (0...4).contains(result) { return Self(kind: kind, id: id, result: result) }
    throw MacDeskDeckWireError.malformed
  }
}

@Observable @MainActor final class MacDndSyncModel: FeatureHandler {
  private struct Approval: Codable { let identifier: String; let name: String }
  private final class Link {
    let channel: any SecuredChannel
    var peerCanSend = false
    var capabilitySent = false
    var capabilityTask: Task<Void, Never>?
    init(_ channel: any SecuredChannel) { self.channel = channel }
  }
  private struct Incoming { let link: Link; let message: DndSyncMessage }
  private var links: [String: Link] = [:]
  private var seen: [String: [String]] = [:]
  private var incoming: Incoming?
  private var applyingTask: Task<Void, Never>?
  private var applyingDescriptor: ChannelDescriptor?
  private let execute: (String) async -> Int64
  private let list: () async -> (shortcuts: [MacDeskDeckSystemShortcut], available: Bool)
  private let defaults: UserDefaults
  private var onShortcut: Approval?
  private var offShortcut: Approval?
  private var selectionsAvailable = false
  private(set) var shortcuts: [MacDeskDeckSystemShortcut] = []
  private(set) var loading = false
  private(set) var receiveStatus = "Choose On and Off Shortcuts to receive phone changes."
  var onName: String? { onShortcut?.name }
  var offName: String? { offShortcut?.name }
  private var receiving: Bool { selectionsAvailable && onShortcut != nil && offShortcut != nil }

  init(defaults: UserDefaults = .standard,
    execute: @escaping (String) async -> Int64 = { identifier in
      await MacDeskDeckShortcutRunner.run(identifier: identifier)
    },
    list: @escaping () async -> (shortcuts: [MacDeskDeckSystemShortcut], available: Bool) = MacDeskDeckShortcutRunner.list
  ) {
    self.defaults = defaults
    self.execute = execute; self.list = list
    defaults.removeObject(forKey: "dnd-sync.sending")
    onShortcut = defaults.data(forKey: "dnd-sync.on").flatMap { try? JSONDecoder().decode(Approval.self, from: $0) }
    offShortcut = defaults.data(forKey: "dnd-sync.off").flatMap { try? JSONDecoder().decode(Approval.self, from: $0) }
  }
  func choose(_ shortcut: MacDeskDeckSystemShortcut, enabled: Bool) {
    guard shortcuts.contains(shortcut), UUID(uuidString: shortcut.identifier) != nil,
      (enabled ? offShortcut?.identifier : onShortcut?.identifier) != shortcut.identifier else {
      receiveStatus = "Choose separate On and Off Shortcuts."; return
    }
    let approval = Approval(identifier: shortcut.identifier, name: shortcut.name)
    if enabled { onShortcut = approval } else { offShortcut = approval }
    defaults.set(try? JSONEncoder().encode(approval), forKey: enabled ? "dnd-sync.on" : "dnd-sync.off")
    validateSelections()
    receiveStatus = receiving ? "Ready. aniCe confirms a Shortcut ran, not Focus state." : "Choose On and Off Shortcuts."
    advertiseAll()
  }
  func removeSelections() {
    onShortcut = nil; offShortcut = nil; selectionsAvailable = false
    defaults.removeObject(forKey: "dnd-sync.on"); defaults.removeObject(forKey: "dnd-sync.off")
    applyingTask?.cancel(); incoming = nil
    receiveStatus = "Choose On and Off Shortcuts."; advertiseAll()
  }
  func refreshShortcuts() async {
    guard !loading else { return }
    loading = true
    let result = await list()
    shortcuts = result.shortcuts
    validateSelections()
    receiveStatus = !result.available ? "Shortcuts unavailable. Open Shortcuts and refresh." :
      receiving ? "Ready. aniCe confirms a Shortcut ran, not Focus state." : "Choose On and Off Shortcuts."
    loading = false; advertiseAll()
  }
  private func validateSelections() {
    selectionsAvailable = [onShortcut, offShortcut].allSatisfy { approval in
      guard let approval else { return false }
      return shortcuts.contains { $0.identifier.caseInsensitiveCompare(approval.identifier) == .orderedSame }
    }
  }
  func available(_ channel: any SecuredChannel) {
    let link = Link(channel); links[channel.descriptor.transport] = link; advertise(link)
    if onShortcut != nil || offShortcut != nil { Task { await refreshShortcuts() } }
  }
  func retired(_ descriptor: ChannelDescriptor) {
    guard let link = links[descriptor.transport], link.channel.descriptor == descriptor else { return }
    link.capabilityTask?.cancel(); links.removeValue(forKey: descriptor.transport)
    if incoming?.link === link { incoming = nil }
    if applyingDescriptor == descriptor { applyingTask?.cancel() }
    if !links.values.contains(where: { $0.channel.descriptor.peer.fingerprint == descriptor.peer.fingerprint }) { seen[descriptor.peer.fingerprint] = nil }
    if links.isEmpty {
      receiveStatus = "Disconnected. Phone changes are not queued."
    }
  }
  func capacityAvailable(_ descriptor: ChannelDescriptor) {
    guard let link = links[descriptor.transport], link.channel.descriptor == descriptor else { return }; advertise(link)
  }
  private func live(_ link: Link) -> Bool { links[link.channel.descriptor.transport] === link }
  private func advertiseAll() {
    for link in links.values { link.capabilitySent = false; advertise(link) }
  }
  private func advertise(_ link: Link) {
    guard live(link), !link.capabilitySent, link.capabilityTask == nil else { return }
    let message = DndSyncMessage(kind: 1, sending: false, receiving: receiving)
    link.capabilityTask = Task { @MainActor in
      defer {
        link.capabilityTask = nil
        if live(link), message != DndSyncMessage(kind: 1, sending: false, receiving: receiving) { advertise(link) }
      }
      do {
        try await link.channel.sendData(message.encode())
        if live(link) { link.capabilitySent = message == DndSyncMessage(kind: 1, sending: false, receiving: receiving) }
      } catch {
        if live(link) { receiveStatus = "DND setup could not be sent. Reconnect and retry." }
      }
    }
  }
  func handle(_ bytes: Data, on descriptor: ChannelDescriptor) async -> DataHandling {
    guard let link = links[descriptor.transport], link.channel.descriptor == descriptor else { return .discarded }
    let message: DndSyncMessage
    do { guard let decoded = try DndSyncMessage.decode(bytes) else { return .unrecognized }; message = decoded }
    catch { return .discarded }
    switch message.kind {
    case 1: link.peerCanSend = message.sending
    case 3: return .discarded
    case 2:
      guard link.peerCanSend else { return .discarded }
      let peer = descriptor.peer.fingerprint
      guard !(seen[peer] ?? []).contains(message.id) else { return .discarded }
      seen[peer, default: []].append(message.id)
      if seen[peer]!.count > 128 { seen[peer]!.removeFirst() }
      if let previous = incoming { Task { await reply(previous, result: 4) } }
      incoming = Incoming(link: link, message: message)
      applyNext()
    default: return .discarded
    }
    return .handled
  }
  private func reply(_ event: Incoming, result: Int64) async {
    guard live(event.link) else { return }
    try? await event.link.channel.sendData(DndSyncMessage(kind: 3, id: event.message.id, result: result).encode())
  }
  private func applyNext() {
    guard applyingTask == nil, let event = incoming else { return }
    incoming = nil; applyingDescriptor = event.link.channel.descriptor
    applyingTask = Task { @MainActor in
      defer { applyingTask = nil; applyingDescriptor = nil; applyNext() }
      guard live(event.link), !Task.isCancelled else { return }
      guard receiving, let shortcut = event.message.enabled ? onShortcut : offShortcut else {
        receiveStatus = "Select On and Off Shortcuts to apply phone changes."; await reply(event, result: 1); return
      }
      let result = await execute(shortcut.identifier)
      guard !Task.isCancelled, live(event.link) else { return }
      receiveStatus = result == 0 ? "Shortcut ran. aniCe cannot verify Focus state." : "Shortcut failed. Check its actions and permissions."
      await reply(event, result: result == 0 ? 0 : 2)
    }
  }
  func shutdown() {
    applyingTask?.cancel(); incoming = nil
    for link in links.values { link.capabilityTask?.cancel() }
    links.removeAll(); seen.removeAll()
  }
}

struct DndSyncSettingsView: View {
  @Bindable var model: MacDndSyncModel
  @Bindable var deskDeck: MacDeskDeckModel
  @State private var copiedPrompt: String?

  private static let togglePrompt = """
    Create a macOS shortcut named “Toggle Do Not Disturb” using built-in Shortcuts actions. Get Current Focus. If the current Focus is Do Not Disturb, use Set Focus to turn it off. Otherwise, use Set Focus to turn it on until turned off. Ask for no input, show no menus or notifications, and change no other Focus. Do not use AppleScript, shell commands, or URLs.
    """
  private static let onShortcutPrompt = """
    Create a macOS shortcut named “Turn Do Not Disturb On” using built-in Shortcuts actions. Use Set Focus to turn Do Not Disturb on until it is turned off. Do not toggle or turn it back off. Ask for no input, show no menus or notifications, and change no other Focus. Do not use AppleScript, shell commands, or URLs.
    """
  private static let offShortcutPrompt = """
    Create a macOS shortcut named “Turn Do Not Disturb Off” using built-in Shortcuts actions. Use Set Focus to turn Do Not Disturb off. Do not turn it back on or toggle it. Ask for no input, show no menus or notifications, and change no other Focus. Do not use AppleScript, shell commands, or URLs.
    """

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Phone → Mac").font(.headline)
      Text("Apply the phone’s DND changes on this Mac while it is connected.")
        .font(.caption).foregroundStyle(.secondary)
      HStack(alignment: .top, spacing: 12) {
        receiveShortcutPicker(enabled: true).frame(maxWidth: .infinity, alignment: .leading)
        receiveShortcutPicker(enabled: false).frame(maxWidth: .infinity, alignment: .leading)
      }
      Button(model.loading ? "Checking…" : "Refresh Shortcuts") { Task { await model.refreshShortcuts() } }
        .disabled(model.loading)
      Text(model.receiveStatus).font(.caption).foregroundStyle(.secondary)

      DisclosureGroup("Set up once") {
        VStack(alignment: .leading, spacing: 8) {
          Text("Create two Shortcuts with Set Focus: one turns Do Not Disturb on until turned off; the other turns it off. Copy each prompt, open Shortcuts, click +, then paste into Describe a Shortcut (Apple Intelligence) if available. Otherwise add Set Focus manually and test each Shortcut.")
            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
          HStack {
            copyPromptButton("On", prompt: Self.onShortcutPrompt)
            copyPromptButton("Off", prompt: Self.offShortcutPrompt)
            Button("Open Shortcuts", action: openShortcuts).controlSize(.small)
          }
          if model.onName != nil || model.offName != nil {
            Button("Clear On/Off selections") { model.removeSelections() }.controlSize(.small)
          }
        }.padding(.top, 6)
      }

      Divider()
      DisclosureGroup("Desk Deck button · Mac only") {
        VStack(alignment: .leading, spacing: 8) {
          Text("Runs a local Do Not Disturb toggle on the Mac. It does not sync to the phone.")
            .font(.caption).foregroundStyle(.secondary)
          Text("Create a Shortcut with Get Current Focus → If → Set Focus, or copy this prompt and paste it into Describe a Shortcut.")
            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
          HStack {
            Button(copiedPrompt == "toggle" ? "Copied prompt" : "Copy prompt") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(Self.togglePrompt, forType: .string)
              copiedPrompt = "toggle"
            }.controlSize(.small)
            Button("Open Shortcuts", action: openShortcuts).controlSize(.small)
          }
          HStack {
            Menu(deskDeck.approvedFocusShortcutName.map { "Selected · \($0)" } ?? "Choose toggle Shortcut") {
              ForEach(deskDeck.availableFocusShortcuts) { shortcut in
                Button(shortcut.name) { deskDeck.approveFocusShortcut(shortcut) }
              }
            }.disabled(deskDeck.isLoadingFocusShortcuts || deskDeck.availableFocusShortcuts.isEmpty)
            Button(deskDeck.isLoadingFocusShortcuts ? "Checking…" : "Refresh") {
              Task { await deskDeck.refreshFocusShortcuts() }
            }.disabled(deskDeck.isLoadingFocusShortcuts)
            if deskDeck.approvedFocusShortcutName != nil {
              Button("Clear") { deskDeck.removeFocusShortcut() }
            }
          }
          if !deskDeck.focusShortcutStatus.isEmpty {
            Text(deskDeck.focusShortcutStatus).font(.caption).foregroundStyle(.secondary)
          }
        }.padding(.top, 6)
      }
    }
    .task {
      async let receive: Void = model.refreshShortcuts()
      async let quickDeck: Void = deskDeck.refreshFocusShortcuts()
      _ = await (receive, quickDeck)
    }
  }

  private func copyPromptButton(_ label: String, prompt: String) -> some View {
    Button(copiedPrompt == label ? "Copied \(label) prompt" : "Copy \(label) prompt") {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(prompt, forType: .string)
      copiedPrompt = label
    }.controlSize(.small)
  }

  private func openShortcuts() {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") else { return }
    Task { _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) }
  }

  @ViewBuilder private func receiveShortcutPicker(enabled: Bool) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(enabled ? "When phone DND turns on" : "When phone DND turns off").font(.callout)
      Menu((enabled ? model.onName : model.offName) ?? "Choose Shortcut") {
        ForEach(model.shortcuts) { shortcut in
          Button(shortcut.name) { model.choose(shortcut, enabled: enabled) }
        }
      }.disabled(model.loading || model.shortcuts.isEmpty)
    }
  }
}
