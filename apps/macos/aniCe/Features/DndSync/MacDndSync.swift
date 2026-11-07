// SPDX-License-Identifier: GPL-3.0-or-later
// Sends native DND transitions only over an already connected secured channel.
import AppIntents
import AppKit
import Foundation
import Observation
import OSLog
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

// Briefly suppresses the native callback caused by applying a remote DND change.
struct DndEchoGuard {
  private var observed: Bool?
  private var expected: Bool?
  private var expires: TimeInterval = 0
  mutating func applying(_ value: Bool, now: TimeInterval) { expected = value; expires = now + 15 }
  mutating func changed(_ value: Bool, now: TimeInterval) -> Bool {
    let duplicate = observed == value
    observed = value
    let echo = expected == value && now <= expires
    if echo || !duplicate || now > expires { expected = nil }
    return !duplicate && !echo
  }
}

@Observable @MainActor final class MacDndSyncModel: FeatureHandler {
  static weak var shared: MacDndSyncModel?
  private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "aniCe", category: "DndSync")
  private struct Approval: Codable { let identifier: String; let name: String }
  private final class Link {
    let channel: any SecuredChannel
    var sending = false
    var receiving = false
    var capabilitySent = false
    var capabilityTask: Task<Void, Never>?
    var eventTask: Task<Bool, Never>?
    init(_ channel: any SecuredChannel) { self.channel = channel }
  }
  private struct Incoming { let link: Link; let message: DndSyncMessage }
  enum AutomationResult { case submitted, suppressed, syncDisabled, noReadyPhone, submissionFailed }
  private var links: [String: Link] = [:]
  private var seen: [String: [String]] = [:]
  private var selected: [String: ChannelDescriptor] = [:]
  private var awaiting: [String: (ChannelDescriptor, Task<Void, Never>)] = [:]
  private var incoming: Incoming?
  private var applyingTask: Task<Void, Never>?
  private var applyingDescriptor: ChannelDescriptor?
  private var echo = DndEchoGuard()
  private let execute: (String) async -> Int64
  private let list: () async -> (shortcuts: [MacDeskDeckSystemShortcut], available: Bool)
  private let defaults: UserDefaults
  private var onShortcut: Approval?
  private var offShortcut: Approval?
  private var selectionsAvailable = false
  private(set) var sending: Bool
  private(set) var shortcuts: [MacDeskDeckSystemShortcut] = []
  private(set) var loading = false
  private(set) var status = "Changes sync only while connected. No offline changes are replayed."
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
    sending = defaults.bool(forKey: "dnd-sync.sending")
    onShortcut = defaults.data(forKey: "dnd-sync.on").flatMap { try? JSONDecoder().decode(Approval.self, from: $0) }
    offShortcut = defaults.data(forKey: "dnd-sync.off").flatMap { try? JSONDecoder().decode(Approval.self, from: $0) }
  }
  func setSending(_ value: Bool) {
    sending = value; defaults.set(value, forKey: "dnd-sync.sending")
    if !value {
      for link in links.values { link.eventTask?.cancel() }
      awaiting.values.forEach { $0.1.cancel() }; awaiting.removeAll()
    }
    advertiseAll()
  }
  func choose(_ shortcut: MacDeskDeckSystemShortcut, enabled: Bool) {
    guard shortcuts.contains(shortcut), UUID(uuidString: shortcut.identifier) != nil,
      (enabled ? offShortcut?.identifier : onShortcut?.identifier) != shortcut.identifier else {
      status = "Choose two different shortcuts: one explicitly turns DND on, one turns it off. A toggle cannot receive phone changes."; return
    }
    let approval = Approval(identifier: shortcut.identifier, name: shortcut.name)
    if enabled { onShortcut = approval } else { offShortcut = approval }
    defaults.set(try? JSONEncoder().encode(approval), forKey: enabled ? "dnd-sync.on" : "dnd-sync.off")
    validateSelections()
    status = receiving ? "On and Off Shortcuts are selected. aniCe reports whether each run finishes; it does not read Focus state." :
      "Choose two different shortcuts: one explicitly turns DND on, one turns it off. A toggle cannot receive phone changes."
    advertiseAll()
  }
  func removeSelections() {
    onShortcut = nil; offShortcut = nil; selectionsAvailable = false
    defaults.removeObject(forKey: "dnd-sync.on"); defaults.removeObject(forKey: "dnd-sync.off")
    applyingTask?.cancel(); incoming = nil
    status = "Phone → Mac sync is disabled until On and Off Shortcuts are selected."; advertiseAll()
  }
  func refreshShortcuts() async {
    guard !loading else { return }
    loading = true
    let result = await list()
    shortcuts = result.shortcuts
    validateSelections()
    status = !result.available ? "Open Shortcuts on this Mac, then refresh." :
      receiving ? "On and Off Shortcuts are selected. aniCe reports whether each run finishes; it does not read Focus state." :
        "Choose two different shortcuts: one explicitly turns DND on, one turns it off. A toggle cannot receive phone changes."
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
    link.capabilityTask?.cancel(); link.eventTask?.cancel(); links.removeValue(forKey: descriptor.transport)
    if selected[descriptor.peer.fingerprint] == descriptor { selected[descriptor.peer.fingerprint] = nil }
    for id in Array(awaiting.keys) where awaiting[id]?.0 == descriptor { awaiting.removeValue(forKey: id)?.1.cancel() }
    if incoming?.link === link { incoming = nil }
    if applyingDescriptor == descriptor { applyingTask?.cancel() }
    if !links.values.contains(where: { $0.channel.descriptor.peer.fingerprint == descriptor.peer.fingerprint }) { seen[descriptor.peer.fingerprint] = nil }
    if links.isEmpty { echo = DndEchoGuard(); status = "Disconnected. DND changes are not queued." }
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
    let message = DndSyncMessage(kind: 1, sending: sending, receiving: receiving)
    link.capabilityTask = Task { @MainActor in
      defer {
        link.capabilityTask = nil
        if live(link), message != DndSyncMessage(kind: 1, sending: sending, receiving: receiving) { advertise(link) }
      }
      do {
        try await link.channel.sendData(message.encode())
        if live(link) { link.capabilitySent = message == DndSyncMessage(kind: 1, sending: sending, receiving: receiving) }
      } catch { if live(link) { status = "DND capability could not be sent." } }
    }
  }
  func nativeChanged(_ enabled: Bool) async -> AutomationResult {
    guard echo.changed(enabled, now: ProcessInfo.processInfo.systemUptime) else {
      Self.logger.debug("event=mac_dnd_suppressed enabled=\(enabled, privacy: .public)")
      return .suppressed
    }
    guard sending else {
      status = "Mac → phone sync is off. Enable Sync Do Not Disturb above."
      Self.logger.info("event=mac_dnd_not_sent reason=sync_disabled enabled=\(enabled, privacy: .public)")
      return .syncDisabled
    }
    let groups = Dictionary(grouping: links.values.filter { $0.receiving && $0.capabilitySent }, by: { $0.channel.descriptor.peer.fingerprint })
    guard !groups.isEmpty else {
      let reason = links.isEmpty ? "no_connection" : "no_ready_phone"
      status = links.isEmpty ? "No secured phone connection. DND changes are not queued." : "No connected phone is ready to receive DND changes."
      Self.logger.info("event=mac_dnd_not_sent reason=\(reason, privacy: .public) enabled=\(enabled, privacy: .public)")
      return .noReadyPhone
    }
    var submitted = false
    for candidates in groups.values {
      let peer = candidates[0].channel.descriptor.peer.fingerprint
      let link = candidates.first { $0.channel.descriptor == selected[peer] } ??
        candidates.first { $0.channel.descriptor.transport == "lan" } ?? candidates[0]
      selected[peer] = link.channel.descriptor
      link.eventTask?.cancel()
      for id in Array(awaiting.keys) where awaiting[id]?.0.peer.fingerprint == link.channel.descriptor.peer.fingerprint {
        awaiting.removeValue(forKey: id)?.1.cancel()
      }
      let message = DndSyncMessage(kind: 2, id: UUID().uuidString.lowercased(), enabled: enabled)
      let eventTask = Task { @MainActor in
        guard live(link), sending, link.receiving else {
          status = "Mac DND change was not sent because the connection or sync setting changed."
          return false
        }
        let timer = Task { @MainActor in
          do { try await Task.sleep(for: .seconds(8)) } catch { return }
          if awaiting.removeValue(forKey: message.id) != nil {
            link.eventTask?.cancel()
            status = "Phone DND change is unconfirmed. Check the phone."
          }
        }
        awaiting[message.id] = (link.channel.descriptor, timer)
        status = "Sending DND change to phone…"
        do {
          try await link.channel.sendData(message.encode())
          if live(link) {
            Self.logger.info("event=mac_dnd_submitted enabled=\(enabled, privacy: .public) transport=\(link.channel.descriptor.transport, privacy: .public)")
          }
          return true
        }
        catch is CancellationError { awaiting.removeValue(forKey: message.id)?.1.cancel(); return false }
        catch {
          awaiting.removeValue(forKey: message.id)?.1.cancel()
          if live(link) { status = "Phone DND submission is unconfirmed. No automatic retry." }
          Self.logger.error("event=mac_dnd_submit_failed enabled=\(enabled, privacy: .public) transport=\(link.channel.descriptor.transport, privacy: .public)")
          return false
        }
      }
      link.eventTask = eventTask
      submitted = await eventTask.value || submitted
    }
    return submitted ? .submitted : .submissionFailed
  }
  func handle(_ bytes: Data, on descriptor: ChannelDescriptor) async -> DataHandling {
    guard let link = links[descriptor.transport], link.channel.descriptor == descriptor else { return .discarded }
    let message: DndSyncMessage
    do { guard let decoded = try DndSyncMessage.decode(bytes) else { return .unrecognized }; message = decoded }
    catch { return .discarded }
    switch message.kind {
    case 1: link.sending = message.sending; link.receiving = message.receiving
    case 3:
      guard awaiting[message.id]?.0 == descriptor else { return .discarded }
      awaiting.removeValue(forKey: message.id)?.1.cancel()
      status = message.result == 0 ? "Phone DND request submitted. Other phone modes may remain active." : "Phone DND was not confirmed. Check its DND access and modes."
    case 2:
      guard link.sending else { return .discarded }
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
        status = "Phone DND change was not applied: select Mac On and Off Shortcuts."; await reply(event, result: 1); return
      }
      echo.applying(event.message.enabled, now: ProcessInfo.processInfo.systemUptime)
      let result = await execute(shortcut.identifier)
      guard !Task.isCancelled, live(event.link) else { return }
      status = result == 0 ? "Mac Shortcut run finished. Focus state was not checked." : "Mac DND is unconfirmed. Check Focus and the selected Shortcut."
      await reply(event, result: result == 0 ? 0 : 2)
    }
  }
  func shutdown() {
    applyingTask?.cancel(); incoming = nil
    for link in links.values { link.capabilityTask?.cancel(); link.eventTask?.cancel() }
    awaiting.values.forEach { $0.1.cancel() }; awaiting.removeAll(); links.removeAll(); seen.removeAll(); selected.removeAll()
  }
}

struct ReportMacDndIntent: AppIntent {
  private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "aniCe", category: "DndSyncIntent")
  static let title: LocalizedStringResource = "Report Mac Do Not Disturb"
  static let description = IntentDescription("Use in native Do Not Disturb On and Off automations to send exact Mac changes to connected trusted phones.")
  static let openAppWhenRun = false
  @Parameter(title: "Do Not Disturb is on") var enabled: Bool
  static var parameterSummary: some ParameterSummary { Summary("Report Mac Do Not Disturb \(\.$enabled)") }
  @MainActor func perform() async throws -> some IntentResult {
    guard let model = MacDndSyncModel.shared else { throw DndAutomationError.notRunning }
    Self.logger.info("event=mac_dnd_intent_invoked enabled=\(enabled, privacy: .public)")
    switch await model.nativeChanged(enabled) {
    case .submitted, .suppressed:
      return .result()
    case .syncDisabled:
      throw DndAutomationError.syncDisabled
    case .noReadyPhone:
      throw DndAutomationError.noReadyPhone
    case .submissionFailed:
      throw DndAutomationError.submissionFailed
    }
  }
}
private enum DndAutomationError: LocalizedError {
  case notRunning, syncDisabled, noReadyPhone, submissionFailed
  var errorDescription: String? {
    switch self {
    case .notRunning: "aniCe must be running to send Mac DND changes."
    case .syncDisabled: "Enable Sync Do Not Disturb in aniCe Settings."
    case .noReadyPhone: "Connect a trusted phone with DND reception enabled, then try again."
    case .submissionFailed: "aniCe could not submit the DND change. Reconnect the phone and try again."
    }
  }
}
struct DndSyncShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(intent: ReportMacDndIntent(), phrases: ["Report Do Not Disturb in \(.applicationName)"], shortTitle: "Report Mac DND", systemImageName: "moon")
  }
}

struct DndSyncSettingsView: View {
  @Bindable var model: MacDndSyncModel
  @Bindable var deskDeck: MacDeskDeckModel
  @State private var didCopyMacAutomationSteps = false
  @State private var didCopyTogglePrompt = false
  @State private var didCopyOnPrompt = false
  @State private var didCopyOffPrompt = false
  private static let togglePrompt = """
    Create a macOS shortcut named “Toggle Do Not Disturb” using built-in Shortcuts actions. Get Current Focus. If the current Focus is Do Not Disturb, use Set Focus to turn Do Not Disturb off. Otherwise, use Set Focus to turn Do Not Disturb on until it is turned off. Run immediately without asking for input, showing menus or notifications, or changing any other Focus. Do not use AppleScript, shell commands, or URLs.
    """
  private static let onShortcutPrompt = """
    Create a macOS shortcut named “Turn Do Not Disturb On” using built-in Shortcuts actions. Use Set Focus to turn Do Not Disturb on until it is turned off. Do not toggle or turn it back off. Ask for no input, show no menus or notifications, and change no other Focus. Do not use AppleScript, shell commands, or URLs.
    """
  private static let offShortcutPrompt = """
    Create a macOS shortcut named “Turn Do Not Disturb Off” using built-in Shortcuts actions. Use Set Focus to turn Do Not Disturb off. Do not turn it back on or toggle it. Ask for no input, show no menus or notifications, and change no other Focus. Do not use AppleScript, shell commands, or URLs.
    """
  private static let setupSteps = """
    Desk Deck Do Not Disturb button
    Prompt for Shortcuts' natural-language shortcut creation:
    Create a macOS shortcut named “Toggle Do Not Disturb” using built-in Shortcuts actions. Get Current Focus. If the current Focus is Do Not Disturb, use Set Focus to turn Do Not Disturb off. Otherwise, use Set Focus to turn Do Not Disturb on until it is turned off. Run immediately without asking for input, showing menus or notifications, or changing any other Focus. Do not use AppleScript, shell commands, or URLs.
    Review the generated actions, run the Shortcut manually, confirm it toggles Focus both ways, then select it in aniCe Settings → Do Not Disturb → Desk Deck button. If shortcut generation is unavailable, add the same Get Current Focus, If, and Set Focus actions manually. An empty shortcut can finish without doing anything.

    Phone → Mac receiving
    Create two other, distinct Shortcuts; do not reuse the Desk Deck toggle.
    On prompt: Create a macOS shortcut named “Turn Do Not Disturb On” using built-in Shortcuts actions. Use Set Focus to turn Do Not Disturb on until it is turned off. Do not toggle or turn it back off. Ask for no input, show no menus or notifications, and change no other Focus. Do not use AppleScript, shell commands, or URLs.
    Off prompt: Create a macOS shortcut named “Turn Do Not Disturb Off” using built-in Shortcuts actions. Use Set Focus to turn Do Not Disturb off. Do not turn it back on or toggle it. Ask for no input, show no menus or notifications, and change no other Focus. Do not use AppleScript, shell commands, or URLs.
    Review and run each once, then select the matching shortcut in the On and Off rows.

    Mac → phone Do Not Disturb sync
    1. In Shortcuts → Automation, create Do Not Disturb Turned On and Turned Off automations.
    2. Set each to run immediately.
    3. Add aniCe → Report Mac Do Not Disturb to both; use On for the first and Off for the second.
    4. Enable Sync Do Not Disturb in aniCe Settings → Do Not Disturb.
    """
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Toggle("Sync Do Not Disturb", isOn: Binding(get: { model.sending }, set: model.setSending)).toggleStyle(.checkbox)
      Text("This switch enables Mac → phone sending. Control Center changes need the two native automations below; aniCe does not watch Focus in the background.").font(.caption).foregroundStyle(.secondary)
      DisclosureGroup("Required for Mac → phone sync") {
      Text("In Shortcuts → Automation, create Do Not Disturb Turned On and Turned Off automations. Set each to run immediately. Add aniCe’s Report Mac Do Not Disturb action: On in the first, Off in the second. No timer or polling is needed. macOS requires this one-time Shortcuts setup; aniCe cannot install it silently.")
          .font(.caption).textSelection(.enabled)
        Button(didCopyMacAutomationSteps ? "Copied setup guide" : "Copy setup guide") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(Self.setupSteps, forType: .string)
          didCopyMacAutomationSteps = true
        }.controlSize(.small)
      }
      Divider()
      Text("Desk Deck button").font(.callout)
      Text("Choose your Do Not Disturb toggle Shortcut. This picker selects an existing Shortcut; it cannot create or install one. The Shortcut must contain a working Focus action: an empty Shortcut can finish successfully without changing anything. aniCe does not read back the resulting Focus state.")
        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      Text("When Apple Intelligence shortcut creation is available, paste this prompt into a new shortcut’s description. Review and test its actions yourself before selecting it. Otherwise, add the same actions manually.")
        .font(.caption).foregroundStyle(.secondary)
      Button(didCopyTogglePrompt ? "Copied toggle prompt" : "Copy toggle prompt") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.togglePrompt, forType: .string)
        didCopyTogglePrompt = true
      }.controlSize(.small)
      HStack {
        Menu(deskDeck.approvedFocusShortcutName.map { "Selected · \($0)" } ?? "Choose Shortcut") {
          ForEach(deskDeck.availableFocusShortcuts) { shortcut in
            Button(shortcut.name) { deskDeck.approveFocusShortcut(shortcut) }
          }
        }
        .disabled(deskDeck.isLoadingFocusShortcuts || deskDeck.availableFocusShortcuts.isEmpty)
        Button(deskDeck.isLoadingFocusShortcuts ? "Checking…" : "Refresh Shortcuts") {
          Task { await deskDeck.refreshFocusShortcuts() }
        }
        .disabled(deskDeck.isLoadingFocusShortcuts)
        if deskDeck.approvedFocusShortcutName != nil {
          Button("Remove selection") { deskDeck.removeFocusShortcut() }
        }
      }
      if !deskDeck.focusShortcutStatus.isEmpty {
        Text(deskDeck.focusShortcutStatus).font(.caption).foregroundStyle(.secondary)
      }
      Text("The Shortcut runs with permissions granted to Shortcuts. Focus may sync to other Apple devices when Share Across Devices is enabled.")
        .font(.caption).foregroundStyle(.secondary)
      Divider()
      Text("Receive phone changes").font(.callout)
      Text("Phone → Mac needs two different, dedicated Set Focus Shortcuts: one turns Do Not Disturb On until turned off, the other turns it Off. Do not use the Desk Deck toggle here. Review and test each Shortcut, then select it in the matching row. Neither may toggle or ask for input. aniCe reports whether the command finished; it does not verify Focus state. Selecting both allows incoming changes even with this Mac’s sync switch off.")
        .font(.caption).foregroundStyle(.secondary)
      HStack {
        Button(didCopyOnPrompt ? "Copied On prompt" : "Copy On prompt") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(Self.onShortcutPrompt, forType: .string)
          didCopyOnPrompt = true
        }.controlSize(.small)
        Button(didCopyOffPrompt ? "Copied Off prompt" : "Copy Off prompt") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(Self.offShortcutPrompt, forType: .string)
          didCopyOffPrompt = true
        }.controlSize(.small)
      }
      ForEach([true, false], id: \.self) { enabled in
        Menu((enabled ? "On · " : "Off · ") + ((enabled ? model.onName : model.offName) ?? "Choose Shortcut")) {
          ForEach(model.shortcuts) { shortcut in Button(shortcut.name) { model.choose(shortcut, enabled: enabled) } }
        }.disabled(model.loading || model.shortcuts.isEmpty)
      }
      HStack {
        Button(model.loading ? "Checking…" : "Refresh receive shortcuts") {
          Task { await model.refreshShortcuts(); await deskDeck.refreshFocusShortcuts() }
        }.disabled(model.loading || deskDeck.isLoadingFocusShortcuts)
        if model.onName != nil || model.offName != nil { Button("Remove selections") { model.removeSelections() } }
      }
      Text(model.status).font(.caption).foregroundStyle(.secondary)
      Text("Enable Sync Do Not Disturb on the phone too for two-way changes. Only new changes while connected are sent. Focus may also sync to your Apple devices through Apple’s Share Across Devices setting.").font(.caption).foregroundStyle(.secondary)
    }
    .task {
      async let receive: Void = model.refreshShortcuts()
      async let quickDeck: Void = deskDeck.refreshFocusShortcuts()
      _ = await (receive, quickDeck)
    }
  }
}
