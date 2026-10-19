// SPDX-License-Identifier: GPL-3.0-or-later
// Registers system-wide hotkey (⌥⌘V) using Carbon EventHotKey API for quick paste tray invocation.
import AppKit
import Carbon

final class GlobalHotkeyManager: @unchecked Sendable {
  private var hotKeyRef: EventHotKeyRef?
  private var eventHandler: EventHandlerRef?
  var onTrigger: @MainActor () -> Void = {}

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
    let handler: EventHandlerUPP = { _, _, userData in
      guard let userData else { return noErr }
      let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
      DispatchQueue.main.async {
        manager.onTrigger()
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

    // Option + Command + V (kVK_ANSI_V = 9). Leaves system ⌘⇧V ("Paste and Match Style") unshadowed.
    let hotKeyID = EventHotKeyID(signature: OSType(0x414E4943), id: 1) // 'ANIC', 1
    let modifiers = UInt32(cmdKey | optionKey)
    RegisterEventHotKey(
      UInt32(kVK_ANSI_V),
      modifiers,
      hotKeyID,
      GetApplicationEventTarget(),
      0,
      &hotKeyRef
    )
  }

  // Carbon unregistration is thread-safe C API; callable synchronously from nonisolated deinit.
  func unregister() {
    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
      self.hotKeyRef = nil
    }
    if let eventHandler {
      RemoveEventHandler(eventHandler)
      self.eventHandler = nil
    }
  }
}
