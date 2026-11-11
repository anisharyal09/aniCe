// SPDX-License-Identifier: GPL-3.0-or-later
// Registers system-wide paste-tray and floating-keyboard shortcuts with Carbon.
import AppKit
import Carbon

final class GlobalHotkeyManager: @unchecked Sendable {
  private var hotKeyRefs: [EventHotKeyRef] = []
  private var eventHandler: EventHandlerRef?
  var onPasteTray: @MainActor () -> Void = {}
  var onToggleKeyboard: @MainActor () -> Void = {}

  @MainActor
  init() {
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
      let hotKeyNumber = identifier.id
      DispatchQueue.main.async {
        switch hotKeyNumber {
        case 1: manager.onPasteTray()
        case 2: manager.onToggleKeyboard()
        default: break
        }
      }
      return noErr
    }

    let ptr = Unmanaged.passUnretained(self).toOpaque()
    InstallEventHandler(
      GetApplicationEventTarget(),
      handler,
      1,
      &eventType,
      ptr,
      &eventHandler
    )

    let modifiers = UInt32(cmdKey | optionKey)
    // ⌥⌘V leaves the system's ⌘⇧V Paste and Match Style shortcut alone.
    register(UInt32(kVK_ANSI_V), id: 1, modifiers: modifiers)
    // ⌥⌘K toggles Floating Key while aniCe is running, even when its windows are hidden.
    register(UInt32(kVK_ANSI_K), id: 2, modifiers: modifiers)
  }

  @MainActor
  private func register(_ keyCode: UInt32, id: UInt32, modifiers: UInt32) {
    var reference: EventHotKeyRef?
    let status = RegisterEventHotKey(
      keyCode,
      modifiers,
      EventHotKeyID(signature: OSType(0x414E4943), id: id),
      GetApplicationEventTarget(),
      0,
      &reference
    )
    if status == noErr, let reference { hotKeyRefs.append(reference) }
  }

  // Carbon unregistration is thread-safe C API; callable synchronously from nonisolated deinit.
  func unregister() {
    for reference in hotKeyRefs { UnregisterEventHotKey(reference) }
    hotKeyRefs.removeAll()
    if let eventHandler {
      RemoveEventHandler(eventHandler)
      self.eventHandler = nil
    }
  }
}
