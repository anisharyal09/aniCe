// SPDX-License-Identifier: GPL-3.0-or-later
// Registers system-wide paste-tray and floating-keyboard shortcuts with Carbon.
import AppKit
import Carbon
import SwiftUI
import Observation

enum GlobalShortcutAction: String, CaseIterable, Identifiable {
  case tray, floatingKey
  var id: Self { self }
  var title: String { self == .tray ? "Clipboard tray" : "Floating Key" }
  var number: UInt32 { self == .tray ? 1 : 2 }
  var defaultBinding: GlobalShortcut {
    GlobalShortcut(keyCode: self == .tray ? 9 : 40, shift: false)
  }
}

struct GlobalShortcut: Equatable {
  let keyCode: UInt16
  let shift: Bool
  // Physical key positions match Carbon registration; native keyboard layout determines the typed character.
  static let keys: [UInt16: String] = [
    0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
    11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
    18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
    31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M"
  ]
  // These system combinations control logout, Dock, hiding and minimization.
  var valid: Bool { Self.keys[keyCode] != nil && ![12, 4, 2, 46].contains(keyCode) }
  var label: String { (shift ? "⇧" : "") + "⌥⌘" + (Self.keys[keyCode] ?? "?") }
  var modifiers: UInt32 { UInt32(cmdKey | optionKey | (shift ? shiftKey : 0)) }

  static func captured(_ event: NSEvent) -> Self? {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      .subtracting([.capsLock, .numericPad, .function])
    guard flags == [.command, .option] || flags == [.command, .option, .shift] else { return nil }
    let result = Self(keyCode: event.keyCode, shift: flags.contains(.shift))
    return result.valid ? result : nil
  }
}

@Observable @MainActor final class GlobalShortcutPreferences {
  static let shared = GlobalShortcutPreferences()
  private let storage: UserDefaults
  private let install: @MainActor (GlobalShortcutAction, GlobalShortcut) -> Bool
  private(set) var bindings: [GlobalShortcutAction: GlobalShortcut] = [:]
  private(set) var errors: [GlobalShortcutAction: String] = [:]

  init(storage: UserDefaults = .standard,
    install: @escaping @MainActor (GlobalShortcutAction, GlobalShortcut) -> Bool = {
      GlobalHotkeyManager.current?.replace($0, with: $1) ?? false
    }) {
    self.storage = storage
    self.install = install
    for action in GlobalShortcutAction.allCases {
      let key = "ui.globalShortcut.\(action.rawValue)"
      if let row = storage.dictionary(forKey: key), let code = row["keyCode"] as? Int,
        let shift = row["shift"] as? Bool, let nativeCode = UInt16(exactly: code) {
        let binding = GlobalShortcut(keyCode: nativeCode, shift: shift)
        if binding.valid { bindings[action] = binding }
      }
      if bindings[action] == nil { bindings[action] = action.defaultBinding }
    }
    if binding(.tray) == binding(.floatingKey) {
      bindings = Dictionary(uniqueKeysWithValues: GlobalShortcutAction.allCases.map { ($0, $0.defaultBinding) })
      errors[.floatingKey] = "Saved shortcuts conflicted. Defaults restored for this session."
    }
  }

  func binding(_ action: GlobalShortcutAction) -> GlobalShortcut { bindings[action] ?? action.defaultBinding }
  func report(_ message: String?, for action: GlobalShortcutAction) { errors[action] = message }

  @discardableResult func set(_ value: GlobalShortcut, for action: GlobalShortcutAction) -> Bool {
    guard value.valid else { report("Use ⌥⌘ with a letter or number; Shift is optional.", for: action); return false }
    guard !GlobalShortcutAction.allCases.contains(where: { $0 != action && binding($0) == value }) else {
      report("That shortcut is already used by the other action.", for: action); return false
    }
    guard install(action, value) else {
      report("Shortcut unavailable. The previous binding is unchanged. Check other apps or preview copies.", for: action)
      return false
    }
    bindings[action] = value
    storage.set(["keyCode": Int(value.keyCode), "shift": value.shift], forKey: "ui.globalShortcut.\(action.rawValue)")
    errors[action] = nil
    return true
  }
}

struct GlobalShortcutSettingsView: View {
  private let preferences = GlobalShortcutPreferences.shared
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Global · while aniCe is running").font(.caption)
      Text("Click a shortcut, then press ⌥⌘ and a letter or number. Shift is optional; Escape cancels.")
        .font(.caption).foregroundStyle(.secondary)
      ForEach(GlobalShortcutAction.allCases) { action in
        LabeledContent(action.title) {
          ShortcutRecorder(label: preferences.binding(action).label) { binding in
            if let binding { _ = preferences.set(binding, for: action) }
            else { preferences.report("Use ⌥⌘ with a letter or number; Shift is optional.", for: action) }
          }.frame(width: 150, height: 32)
          Button("Reset") { _ = preferences.set(action.defaultBinding, for: action) }
            .buttonStyle(AniCeHoverButtonStyle())
        }
        if let error = preferences.errors[action] {
          Text(error).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }
    }.padding(.vertical, 12)
  }
}

private struct ShortcutRecorder: NSViewRepresentable {
  let label: String
  let captured: (GlobalShortcut?) -> Void
  func makeNSView(context: Context) -> ShortcutRecorderButton {
    let button = ShortcutRecorderButton()
    button.bezelStyle = .rounded
    button.setAccessibilityLabel("Record global shortcut")
    button.captured = captured
    button.label = label
    return button
  }
  func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
    button.label = label; button.captured = captured
  }
}

final class ShortcutRecorderButton: NSButton {
  var label = "" { didSet { if !recording { title = label } } }
  var captured: (GlobalShortcut?) -> Void = { _ in }
  private var recording = false
  override var acceptsFirstResponder: Bool { true }
  override func mouseDown(with event: NSEvent) {
    guard window?.makeFirstResponder(self) == true else { return }
    recording = true; title = "Press shortcut…"
  }
  override func performClick(_ sender: Any?) {
    guard window?.makeFirstResponder(self) == true else { return }
    recording = true; title = "Press shortcut…"
  }
  override func keyDown(with event: NSEvent) {
    guard recording else { super.keyDown(with: event); return }
    if event.keyCode == 53 { recording = false; title = label; return }
    if event.keyCode == 48 { super.keyDown(with: event); return }
    accept(GlobalShortcut.captured(event))
  }
  @discardableResult func acceptRegistered(_ binding: GlobalShortcut) -> Bool {
    guard recording, window?.isKeyWindow == true, window?.firstResponder === self else { return false }
    accept(binding)
    return true
  }
  private func accept(_ binding: GlobalShortcut?) {
    recording = false; title = label; captured(binding)
  }
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard recording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
    keyDown(with: event); return true
  }
  override func resignFirstResponder() -> Bool {
    recording = false; title = label
    return super.resignFirstResponder()
  }
}

final class GlobalHotkeyManager: @unchecked Sendable {
  @MainActor static weak var current: GlobalHotkeyManager?
  private var hotKeyRefs: [GlobalShortcutAction: EventHotKeyRef] = [:]
  private var registeredBindings: [GlobalShortcutAction: GlobalShortcut] = [:]
  private var eventHandler: EventHandlerRef?
  var onPasteTray: @MainActor () -> Void = {}
  var onToggleKeyboard: @MainActor () -> Void = {}

  @MainActor
  init() {
    Self.current = self
    register()
  }

  deinit {
    unregister()
  }

  @MainActor
  private func register() {
    // Prevent capturing user hotkeys or intercepting keystrokes during automated/hosted test execution.
    guard !IdentityView.isTesting else { return }

    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: OSType(kEventHotKeyPressed)
    )

    // Bridge Carbon C event callback back to MainActor serial presentation context.
    let handler: EventHandlerUPP = { _, event, userData in
      guard let event, let userData else { return noErr }
      let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
      var identifier = EventHotKeyID(signature: 0, id: 0)
      var actualSize = 0
      let result = GetEventParameter(
        event,
        UInt32(kEventParamDirectObject),
        UInt32(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        &actualSize,
        &identifier
      )
      guard result == noErr else { return result }
      guard identifier.signature == OSType(0x414E4943) else { return noErr }
      let hotKeyNumber = identifier.id
      DispatchQueue.main.async {
        if let action = GlobalShortcutAction.allCases.first(where: { $0.number == hotKeyNumber }),
          let binding = manager.registeredBindings[action],
          let recorder = NSApp.keyWindow?.firstResponder as? ShortcutRecorderButton,
          recorder.acceptRegistered(binding) { return }
        switch hotKeyNumber {
        case 1: manager.onPasteTray()
        case 2: manager.onToggleKeyboard()
        default: break
        }
      }
      return noErr
    }

    let ptr = Unmanaged.passUnretained(self).toOpaque()
    let status = InstallEventHandler(
      GetApplicationEventTarget(),
      handler,
      1,
      &eventType,
      ptr,
      &eventHandler
    )

    let preferences = GlobalShortcutPreferences.shared
    for action in GlobalShortcutAction.allCases {
      if status != noErr || !replace(action, with: preferences.binding(action)) {
        preferences.report("Shortcut unavailable. Check other apps or preview copies, then record or reset it.", for: action)
      }
    }
  }

  @MainActor
  @discardableResult func replace(_ action: GlobalShortcutAction, with binding: GlobalShortcut) -> Bool {
    guard binding.valid, eventHandler != nil else { return false }
    if hotKeyRefs[action] != nil && registeredBindings[action] == binding { return true }
    var reference: EventHotKeyRef?
    let status = RegisterEventHotKey(
      UInt32(binding.keyCode),
      binding.modifiers,
      EventHotKeyID(signature: OSType(0x414E4943), id: action.number),
      GetApplicationEventTarget(),
      0,
      &reference
    )
    guard status == noErr, let reference else { return false }
    // Register first: a conflicting replacement cannot remove the working shortcut.
    if let previous = hotKeyRefs[action] { UnregisterEventHotKey(previous) }
    hotKeyRefs[action] = reference
    registeredBindings[action] = binding
    return true
  }

  // Carbon unregistration is thread-safe C API; callable synchronously from nonisolated deinit.
  func unregister() {
    for reference in hotKeyRefs.values { UnregisterEventHotKey(reference) }
    hotKeyRefs.removeAll()
    registeredBindings.removeAll()
    if let eventHandler {
      RemoveEventHandler(eventHandler)
      self.eventHandler = nil
    }
  }
}
