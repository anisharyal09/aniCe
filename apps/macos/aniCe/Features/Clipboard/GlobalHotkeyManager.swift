// SPDX-License-Identifier: GPL-3.0-or-later
// Registers system-wide paste-tray and floating-keyboard shortcuts with Carbon.
import AppKit
import Carbon
import SwiftUI
import Observation

enum GlobalShortcutAction: String, CaseIterable, Identifiable {
  case tray, floatingKey, floatingKeyInput
  var id: Self { self }
  var title: String {
    switch self {
    case .tray: "Clipboard tray"
    case .floatingKey: "Floating Key"
    case .floatingKeyInput: "Floating Key typing"
    }
  }
  var number: UInt32 {
    switch self {
    case .tray: 1
    case .floatingKey: 2
    case .floatingKeyInput: 3
    }
  }
  var defaultBinding: GlobalShortcut {
    switch self {
    case .tray: GlobalShortcut(keyCode: 9, shift: false)
    case .floatingKey: GlobalShortcut(keyCode: 40, shift: false)
    case .floatingKeyInput: GlobalShortcut(keyCode: 40, modifierFlags: [.control, .command])
    }
  }
}

struct GlobalShortcut: Equatable {
  let keyCode: UInt16
  let modifierFlags: NSEvent.ModifierFlags

  init(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
    self.keyCode = keyCode
    self.modifierFlags = modifierFlags
  }

  // Legacy saved bindings always used Command–Option, with an optional Shift.
  init(keyCode: UInt16, shift: Bool) {
    self.init(keyCode: keyCode, modifierFlags: shift ? [.command, .option, .shift] : [.command, .option])
  }

  static let supportedModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
  // Physical key positions match Carbon registration; native keyboard layout determines the typed character.
  static let keys: [UInt16: String] = [
    0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
    11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
    18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
    24: "=", 27: "-", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
    36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
    45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "Esc",
    65: "Keypad .", 67: "Keypad *", 69: "Keypad +", 71: "Clear", 75: "Keypad /", 76: "⌤",
    78: "Keypad -", 81: "Keypad =", 82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2",
    85: "Keypad 3", 86: "Keypad 4", 87: "Keypad 5", 88: "Keypad 6", 89: "Keypad 7",
    91: "Keypad 8", 92: "Keypad 9",
    64: "F17", 79: "F18", 80: "F19", 90: "F20", 96: "F5", 97: "F6", 98: "F7",
    99: "F3", 100: "F8", 101: "F9", 103: "F11", 105: "F13", 106: "F16", 107: "F14",
    109: "F10", 111: "F12", 113: "F15", 115: "Home", 116: "Page Up", 117: "⌦",
    118: "F4", 119: "End", 120: "F2", 121: "Page Down", 122: "F1",
    123: "←", 124: "→", 125: "↓", 126: "↑"
  ]
  private static let functionKeys: Set<UInt16> = [
    64, 79, 80, 90, 96, 97, 98, 99, 100, 101, 103, 105, 106, 107, 109, 111, 113, 118, 120, 122
  ]

  var valid: Bool {
    guard Self.keys[keyCode] != nil, modifierFlags.subtracting(Self.supportedModifiers).isEmpty else { return false }
    // Ordinary typing, Shift-selection and standard editing must stay with the focused app.
    if modifierFlags.intersection([.command, .control, .option]).isEmpty {
      return Self.functionKeys.contains(keyCode)
    }
    if modifierFlags == .command || modifierFlags == [.command, .shift] {
      if [0, 1, 3, 6, 7, 8, 9, 12, 13, 31, 35, 45, 46, 4, 51, 117].contains(keyCode) { return false }
    }
    if modifierFlags == .control && [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 14, 15, 17, 35, 40, 45, 11, 16].contains(keyCode) {
      return false
    }
    if modifierFlags == [.command, .option] && [4, 2, 46, 53].contains(keyCode) { return false }
    if modifierFlags == [.command, .option, .shift] && [9, 12].contains(keyCode) { return false }
    if modifierFlags == [.command, .control] && keyCode == 12 { return false }
    if modifierFlags == [.command, .shift] && keyCode == 53 { return false }
    if modifierFlags.contains(.command) && [48, 49].contains(keyCode) { return false }
    return true
  }

  var label: String {
    (modifierFlags.contains(.control) ? "⌃" : "") +
      (modifierFlags.contains(.option) ? "⌥" : "") +
      (modifierFlags.contains(.shift) ? "⇧" : "") +
      (modifierFlags.contains(.command) ? "⌘" : "") + keyLabel
  }

  private var keyLabel: String {
    guard keyCode <= 50, ![36, 48, 49].contains(keyCode),
      let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
      let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
      return Self.keys[keyCode] ?? "?"
    }
    let data = unsafeBitCast(property, to: CFData.self)
    guard let bytes = CFDataGetBytePtr(data) else { return Self.keys[keyCode] ?? "?" }
    let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
    var deadKey: UInt32 = 0
    var length = 0
    var characters = [UniChar](repeating: 0, count: 8)
    let result = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
      OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKey, characters.count, &length, &characters)
    guard result == noErr, length > 0, length <= characters.count else { return Self.keys[keyCode] ?? "?" }
    return String(utf16CodeUnits: characters, count: length).uppercased()
  }

  var modifiers: UInt32 {
    var result: UInt32 = 0
    if modifierFlags.contains(.command) { result |= UInt32(cmdKey) }
    if modifierFlags.contains(.control) { result |= UInt32(controlKey) }
    if modifierFlags.contains(.option) { result |= UInt32(optionKey) }
    if modifierFlags.contains(.shift) { result |= UInt32(shiftKey) }
    return result
  }

  static let recordingHint = "Use a key combination or function key. System and editing shortcuts stay reserved."

  static func captured(_ event: NSEvent) -> Self? {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      .subtracting([.capsLock, .numericPad, .function])
    let result = Self(keyCode: event.keyCode, modifierFlags: flags)
    return result.valid ? result : nil
  }

  static func matchesEnabledSystemHotkey(_ binding: Self, entries: [[String: Any]]) -> Bool {
    entries.contains { row in
      guard row[kHISymbolicHotKeyEnabled as String] as? Bool == true,
        let code = row[kHISymbolicHotKeyCode as String] as? Int,
        let modifiers = row[kHISymbolicHotKeyModifiers as String] as? Int,
        let nativeCode = UInt16(exactly: code), let nativeModifiers = UInt32(exactly: modifiers) else { return false }
      return nativeCode == binding.keyCode && nativeModifiers == binding.modifiers
    }
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
        let nativeCode = UInt16(exactly: code) {
        let binding: GlobalShortcut?
        if let raw = row["modifiers"] as? Int, let flags = UInt(exactly: raw) {
          binding = GlobalShortcut(keyCode: nativeCode, modifierFlags: NSEvent.ModifierFlags(rawValue: flags))
        } else if row["modifiers"] == nil, let shift = row["shift"] as? Bool {
          binding = GlobalShortcut(keyCode: nativeCode, shift: shift)
        } else { binding = nil }
        if let binding, binding.valid { bindings[action] = binding }
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
    guard value.valid else { report(GlobalShortcut.recordingHint, for: action); return false }
    guard !GlobalShortcutAction.allCases.contains(where: { $0 != action && binding($0) == value }) else {
      report("That shortcut is already used by the other action.", for: action); return false
    }
    guard install(action, value) else {
      report("Shortcut unavailable. The previous binding is unchanged. Check other apps or preview copies.", for: action)
      return false
    }
    bindings[action] = value
    storage.set(["keyCode": Int(value.keyCode), "modifiers": Int(value.modifierFlags.rawValue)],
      forKey: "ui.globalShortcut.\(action.rawValue)")
    errors[action] = nil
    return true
  }
}

struct GlobalShortcutSettingsView: View {
  private let preferences = GlobalShortcutPreferences.shared
  @AppStorage("ui.fontScale") private var fontScale = 1.0
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Global · while aniCe is running")
        .font(.system(size: 12 * fontScale))
      Text("Click a shortcut and press a key combination. Escape cancels.")
        .font(.system(size: 12 * fontScale)).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      ForEach(GlobalShortcutAction.allCases) { action in
        AniCePreferenceRow(action.title, fontScale: fontScale) {
          HStack(spacing: 8) {
            ShortcutRecorder(label: preferences.binding(action).label, fontScale: fontScale) { binding in
              if let binding { _ = preferences.set(binding, for: action) }
              else { preferences.report(GlobalShortcut.recordingHint, for: action) }
            }
            .frame(width: 132 * fontScale, height: 32)
            .aniCeControlFeedback()
            Button("Reset") { _ = preferences.set(action.defaultBinding, for: action) }
              .buttonStyle(AniCeButtonStyle(quiet: true, compact: true))
          }
        }
        if let error = preferences.errors[action] {
          Text(error).font(.system(size: 12 * fontScale))
            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }
    }.padding(.vertical, 12)
  }
}

private struct ShortcutRecorder: NSViewRepresentable {
  let label: String
  let fontScale: Double
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
    button.font = NSFont.systemFont(ofSize: 13 * fontScale)
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
    let modifiers = event.modifierFlags.intersection(GlobalShortcut.supportedModifiers)
    if event.keyCode == 53 && modifiers.isEmpty { recording = false; title = label; return }
    if event.keyCode == 48 && (modifiers.isEmpty || modifiers == .shift) { super.keyDown(with: event); return }
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
    guard recording, window?.isKeyWindow == true, window?.firstResponder === self else {
      return super.performKeyEquivalent(with: event)
    }
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
  var onToggleKeyboardInput: @MainActor () -> Void = {}

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
        case 3: manager.onToggleKeyboardInput()
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
    var systemHotkeys: Unmanaged<CFArray>?
    guard CopySymbolicHotKeys(&systemHotkeys) == noErr, let entries = systemHotkeys?.takeRetainedValue() else { return false }
    guard let systemEntries = entries as? [[String: Any]],
      !GlobalShortcut.matchesEnabledSystemHotkey(binding, entries: systemEntries) else { return false }
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
    if let previous = hotKeyRefs[action], UnregisterEventHotKey(previous) != noErr {
      UnregisterEventHotKey(reference)
      return false
    }
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
