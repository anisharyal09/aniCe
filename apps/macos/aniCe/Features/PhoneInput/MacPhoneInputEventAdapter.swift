// SPDX-License-Identifier: GPL-3.0-or-later
// Translates one armed Phone-to-Mac session into bounded native keyboard and pointer events.
import AppKit
import CoreGraphics

enum MacPhoneInputEvent: Equatable {
  case text([UInt16])
  case key(usage: UInt8, keyCode: UInt16, pressed: Bool, modifiers: UInt8)
  case pointerMotion(location: CGPoint, deltaX: Int, deltaY: Int, buttons: UInt8, modifiers: UInt8)
  case pointerButton(button: UInt8, pressed: Bool, location: CGPoint, modifiers: UInt8)
  case scroll(horizontal: Int, vertical: Int, location: CGPoint, modifiers: UInt8)
}

enum MacPhoneInputEventError: Error, Equatable {
  case accessDenied
  case invalidMessage
  case noCursor
  case noDisplay
  case unsupportedKey(UInt8)
  case eventCreationFailed
  case oversizedGrapheme
}

@MainActor protocol MacPhoneInputEventSink: AnyObject {
  var canPostEvents: Bool { get }
  func requestPostEventAccess() -> Bool
  func cursorLocation() -> CGPoint?
  func displayBounds() -> [CGRect]
  func post(_ event: MacPhoneInputEvent) throws
}

@MainActor final class MacPhoneInputEventAdapter {
  private static let pointerButtons: [UInt8] = [1, 2, 4]
  private static let modifierKeyCodes: [UInt8: UInt16] = [
    224: 0x3B, 225: 0x38, 226: 0x3A, 227: 0x37,
    228: 0x3E, 229: 0x3C, 230: 0x3D, 231: 0x36,
  ]
  private static let keyCodesByUsage: [UInt8: UInt16] = {
    var result = [UInt8: UInt16]()
    for keyCode in 0..<128 {
      let usage = AniCeHIDProtocol.usage(forMacKeyCode: UInt16(keyCode))
      if usage != 0 { result[usage] = UInt16(keyCode) }
    }
    result.merge(modifierKeyCodes) { current, _ in current }
    return result
  }()

  private let sink: any MacPhoneInputEventSink
  private(set) var heldKeys = Set<UInt8>()
  private(set) var heldButtons: UInt8 = 0
  private(set) var modifiers: UInt8 = 0

  init(sink: any MacPhoneInputEventSink = CoreGraphicsPhoneInputEventSink()) {
    self.sink = sink
  }

  var canPostEvents: Bool { sink.canPostEvents }

  func requestPostEventAccess() -> Bool { sink.requestPostEventAccess() }

  func apply(_ message: PhoneInputMessage) throws {
    switch message.kind {
    case 4:
      try commit(message.text(2))
    case 5:
      let usage = UInt8(message.number(2))
      try key(usage: usage, modifiers: UInt8(message.number(3)), pressed: message.flag(4))
    case 6:
      try move(deltaX: Int(message.number(2)), deltaY: Int(message.number(3)))
    case 7:
      try setButtons(UInt8(message.number(2)), modifiers: UInt8(message.number(3)))
    case 8:
      try scroll(horizontal: Int(message.number(2)), vertical: Int(message.number(3)))
    case 9:
      guard releaseAll() else { throw MacPhoneInputEventError.accessDenied }
    default:
      throw MacPhoneInputEventError.invalidMessage
    }
  }

  @discardableResult func releaseAll() -> Bool {
    var released = true

    for button in Self.pointerButtons where heldButtons & button != 0 {
      do {
        let location = try currentLocation()
        try sink.post(.pointerButton(
          button: button, pressed: false, location: location, modifiers: modifiers))
        heldButtons &= ~button
      } catch {
        released = false
      }
    }

    for usage in heldKeys.sorted() where Self.modifierKeyCodes[usage] == nil {
      do { try key(usage: usage, modifiers: modifiers, pressed: false) }
      catch { released = false }
    }

    for usage in heldKeys.sorted() where Self.modifierKeyCodes[usage] != nil {
      var releaseModifiers = modifiers
      if let bit = Self.modifierBit(for: usage),
        !heldKeys.contains(where: { $0 != usage && Self.modifierBit(for: $0) == bit })
      {
        releaseModifiers &= ~bit
      }
      do { try key(usage: usage, modifiers: releaseModifiers, pressed: false) }
      catch { released = false }
    }

    if released { modifiers = 0 }
    return released
  }

  static func textChunks(_ text: String, maximumUTF16Units: Int = 16) throws -> [[UInt16]] {
    var result = [[UInt16]]()
    var current = [UInt16]()

    for grapheme in text {
      let units = Array(grapheme.utf16)
      guard !units.isEmpty, units.count <= maximumUTF16Units else {
        throw MacPhoneInputEventError.oversizedGrapheme
      }
      if current.count + units.count > maximumUTF16Units {
        result.append(current)
        current.removeAll(keepingCapacity: true)
      }
      current.append(contentsOf: units)
    }

    if !current.isEmpty { result.append(current) }
    return result
  }

  static func clampedPoint(_ point: CGPoint, to displays: [CGRect]) -> CGPoint? {
    let valid = displays.filter { !$0.isNull && !$0.isEmpty && $0.minX.isFinite && $0.minY.isFinite }
    guard !valid.isEmpty else { return nil }
    if let display = valid.first(where: { $0.contains(point) }) {
      return clamp(point, to: display)
    }

    return valid
      .map { clamp(point, to: $0) }
      .min { distanceSquared(point, $0) < distanceSquared(point, $1) }
  }

  private static func clamp(_ point: CGPoint, to rect: CGRect) -> CGPoint {
    // Stay one point inside the exclusive upper edge so integer cursor rounding stays on-display.
    let maxX = max(rect.minX, rect.maxX - 1)
    let maxY = max(rect.minY, rect.maxY - 1)
    return CGPoint(
      x: min(max(point.x, rect.minX), maxX),
      y: min(max(point.y, rect.minY), maxY))
  }

  private static func distanceSquared(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
    let dx = lhs.x - rhs.x, dy = lhs.y - rhs.y
    return dx * dx + dy * dy
  }

  private static func modifierBit(for usage: UInt8) -> UInt8? {
    switch usage {
    case 224, 228: 1 << 0
    case 225, 229: 1 << 1
    case 226, 230: 1 << 2
    case 227, 231: 1 << 3
    default: nil
    }
  }

  private func requireAccess() throws {
    guard sink.canPostEvents else { throw MacPhoneInputEventError.accessDenied }
  }

  private func currentLocation() throws -> CGPoint {
    guard let location = sink.cursorLocation() else { throw MacPhoneInputEventError.noCursor }
    return location
  }

  private func commit(_ text: String) throws {
    let chunks = try Self.textChunks(text)
    for chunk in chunks {
      try requireAccess()
      try sink.post(.text(chunk))
    }
  }

  private func key(usage: UInt8, modifiers: UInt8, pressed: Bool) throws {
    guard let keyCode = Self.keyCodesByUsage[usage] else {
      throw MacPhoneInputEventError.unsupportedKey(usage)
    }
    try requireAccess()
    try sink.post(.key(usage: usage, keyCode: keyCode, pressed: pressed, modifiers: modifiers))
    if pressed { heldKeys.insert(usage) } else { heldKeys.remove(usage) }
    self.modifiers = modifiers
  }

  private func move(deltaX: Int, deltaY: Int) throws {
    try requireAccess()
    let current = try currentLocation()
    guard let location = Self.clampedPoint(
      CGPoint(x: current.x + CGFloat(deltaX), y: current.y + CGFloat(deltaY)),
      to: sink.displayBounds()) else { throw MacPhoneInputEventError.noDisplay }
    let actualX = Int(location.x.rounded(.towardZero) - current.x.rounded(.towardZero))
    let actualY = Int(location.y.rounded(.towardZero) - current.y.rounded(.towardZero))
    try sink.post(.pointerMotion(
      location: location, deltaX: actualX, deltaY: actualY,
      buttons: heldButtons, modifiers: modifiers))
  }

  private func setButtons(_ buttons: UInt8, modifiers: UInt8) throws {
    guard buttons & ~7 == 0 else { throw MacPhoneInputEventError.invalidMessage }
    try requireAccess()
    let location = try currentLocation()
    self.modifiers = modifiers
    for button in Self.pointerButtons where heldButtons & button != buttons & button {
      try sink.post(.pointerButton(
        button: button, pressed: buttons & button != 0,
        location: location, modifiers: modifiers))
      if buttons & button != 0 { heldButtons |= button } else { heldButtons &= ~button }
    }
  }

  private func scroll(horizontal: Int, vertical: Int) throws {
    try requireAccess()
    try sink.post(.scroll(
      horizontal: horizontal, vertical: vertical,
      location: try currentLocation(), modifiers: modifiers))
  }
}

@MainActor final class CoreGraphicsPhoneInputEventSink: MacPhoneInputEventSink {
  var canPostEvents: Bool { CGPreflightPostEventAccess() }

  func requestPostEventAccess() -> Bool { CGRequestPostEventAccess() }

  func cursorLocation() -> CGPoint? { CGEvent(source: nil)?.location }

  func displayBounds() -> [CGRect] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
    return displays.prefix(Int(count)).map(CGDisplayBounds)
  }

  func post(_ input: MacPhoneInputEvent) throws {
    guard canPostEvents else { throw MacPhoneInputEventError.accessDenied }
    switch input {
    case .text(let units):
      guard !units.isEmpty else { throw MacPhoneInputEventError.invalidMessage }
      guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
      else { throw MacPhoneInputEventError.eventCreationFailed }
      Self.setUnicode(units, on: down)
      Self.setUnicode(units, on: up)
      down.post(tap: .cghidEventTap)
      up.post(tap: .cghidEventTap)

    case .key(_, let keyCode, let pressed, let modifiers):
      guard let event = CGEvent(
        keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: pressed)
      else { throw MacPhoneInputEventError.eventCreationFailed }
      event.flags = Self.flags(modifiers)
      event.post(tap: .cghidEventTap)

    case .pointerMotion(let location, let deltaX, let deltaY, let buttons, let modifiers):
      let (type, button) = Self.dragType(buttons)
      guard let event = CGEvent(
        mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: button)
      else { throw MacPhoneInputEventError.eventCreationFailed }
      event.setIntegerValueField(.mouseEventDeltaX, value: Int64(deltaX))
      event.setIntegerValueField(.mouseEventDeltaY, value: Int64(deltaY))
      event.flags = Self.flags(modifiers)
      event.post(tap: .cghidEventTap)

    case .pointerButton(let button, let pressed, let location, let modifiers):
      let mouseButton = try Self.mouseButton(button)
      let type = Self.buttonType(button, pressed: pressed)
      guard let event = CGEvent(
        mouseEventSource: nil, mouseType: type, mouseCursorPosition: location,
        mouseButton: mouseButton) else { throw MacPhoneInputEventError.eventCreationFailed }
      event.flags = Self.flags(modifiers)
      event.post(tap: .cghidEventTap)

    case .scroll(let horizontal, let vertical, let location, let modifiers):
      guard let event = CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
        wheel1: Int32(vertical), wheel2: Int32(horizontal), wheel3: 0)
      else { throw MacPhoneInputEventError.eventCreationFailed }
      event.location = location
      event.flags = Self.flags(modifiers)
      event.post(tap: .cghidEventTap)
    }
  }

  private static func setUnicode(_ units: [UInt16], on event: CGEvent) {
    units.withUnsafeBufferPointer {
      event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress)
    }
  }

  private static func flags(_ modifiers: UInt8) -> CGEventFlags {
    var flags: CGEventFlags = []
    if modifiers & 0x11 != 0 { flags.insert(.maskControl) }
    if modifiers & 0x22 != 0 { flags.insert(.maskShift) }
    if modifiers & 0x44 != 0 { flags.insert(.maskAlternate) }
    if modifiers & 0x88 != 0 { flags.insert(.maskCommand) }
    return flags
  }

  private static func mouseButton(_ button: UInt8) throws -> CGMouseButton {
    switch button {
    case 1: .left
    case 2: .right
    case 4: .center
    default: throw MacPhoneInputEventError.invalidMessage
    }
  }

  private static func buttonType(_ button: UInt8, pressed: Bool) -> CGEventType {
    switch (button, pressed) {
    case (1, true): .leftMouseDown
    case (1, false): .leftMouseUp
    case (2, true): .rightMouseDown
    case (2, false): .rightMouseUp
    case (4, true): .otherMouseDown
    default: .otherMouseUp
    }
  }

  private static func dragType(_ buttons: UInt8) -> (CGEventType, CGMouseButton) {
    if buttons & 1 != 0 { return (.leftMouseDragged, .left) }
    if buttons & 2 != 0 { return (.rightMouseDragged, .right) }
    if buttons & 4 != 0 { return (.otherMouseDragged, .center) }
    return (.mouseMoved, .left)
  }
}
