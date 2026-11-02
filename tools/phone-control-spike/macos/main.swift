// SPDX-License-Identifier: GPL-3.0-or-later
// Phase 0 Core Graphics probe; the default path only constructs events.
import AppKit
import CoreGraphics
import Foundation

private let maximumUTF16UnitsPerEvent = 16

private enum ProbeFailure: Error, CustomStringConvertible {
  case oversizedGrapheme(Int)
  case eventCreation
  case mouseEventCreation
  case eventPostingAccessRequired
  case invalidArguments
  case textEditTargetRequired
  case targetActivationFailed
  case assertion(String)

  var description: String {
    switch self {
    case .oversizedGrapheme(let size): "one grapheme needs \(size) UTF-16 units"
    case .eventCreation: "Core Graphics could not create a keyboard event"
    case .mouseEventCreation: "Core Graphics could not create a mouse event"
    case .eventPostingAccessRequired: "event-posting access is not granted; no events were posted"
    case .invalidArguments: "usage: main.swift [--request-post-access | --post-textedit-sample <pid>]"
    case .textEditTargetRequired: "the target PID must belong to Apple TextEdit"
    case .targetActivationFailed: "could not activate the TextEdit target"
    case .assertion(let message): message
    }
  }
}

private func chunksAtGraphemeBoundaries(_ text: String) throws -> [String] {
  var chunks: [String] = []
  var current = ""
  var currentUnits = 0
  for grapheme in text {
    let value = String(grapheme)
    let units = value.utf16.count
    guard units <= maximumUTF16UnitsPerEvent else { throw ProbeFailure.oversizedGrapheme(units) }
    if currentUnits + units > maximumUTF16UnitsPerEvent {
      chunks.append(current)
      current = ""
      currentUnits = 0
    }
    current.append(grapheme)
    currentUnits += units
  }
  if !current.isEmpty { chunks.append(current) }
  return chunks
}

private func makeUnicodePair(for chunk: String) throws -> (down: CGEvent, up: CGEvent) {
  guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
    throw ProbeFailure.eventCreation
  }
  let units = Array(chunk.utf16)
  units.withUnsafeBufferPointer { buffer in
    keyDown.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
    keyUp.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
  }
  return (keyDown, keyUp)
}

private func constructUnicodePair(for chunk: String) throws {
  _ = try makeUnicodePair(for: chunk)
}

private func postFixedSample(to targetPID: pid_t) throws {
  guard CGPreflightPostEventAccess() else { throw ProbeFailure.eventPostingAccessRequired }
  guard let target = NSRunningApplication(processIdentifier: targetPID),
        target.bundleIdentifier == "com.apple.TextEdit" else {
    throw ProbeFailure.textEditTargetRequired
  }
  guard target.activate(options: []) else {
    throw ProbeFailure.targetActivationFailed
  }

  Thread.sleep(forTimeInterval: 0.5)
  let sample = "aniCe Phase 0: café — नमस्ते 👩🏽‍💻"
  let chunks = try chunksAtGraphemeBoundaries(sample)
  for chunk in chunks {
    let pair = try makeUnicodePair(for: chunk)
    pair.down.postToPid(targetPID)
    Thread.sleep(forTimeInterval: 0.02)
    pair.up.postToPid(targetPID)
    Thread.sleep(forTimeInterval: 0.04)
  }
  print("posted fixed sample: utf16=\(sample.utf16.count), chunks=\(chunks.count), target=TextEdit pid=\(targetPID)")
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  guard condition() else { throw ProbeFailure.assertion(message) }
}

private func run() throws {
  let samples = ["hello", "नमस्ते", "👨🏽‍💻", String(repeating: "abc क", count: 30)]
  for sample in samples {
    let chunks = try chunksAtGraphemeBoundaries(sample)
    try check(chunks.joined() == sample, "chunking changed \(sample.debugDescription)")
    try check(chunks.allSatisfy { $0.utf16.count <= maximumUTF16UnitsPerEvent }, "chunk exceeded budget")
    for chunk in chunks { try constructUnicodePair(for: chunk) }
    print("unicode chunks=\(chunks.count), maxUTF16=\(chunks.map(\.utf16.count).max() ?? 0)")
  }

  let longGrapheme = "a" + String(repeating: "\u{0301}", count: maximumUTF16UnitsPerEvent)
  do {
    _ = try chunksAtGraphemeBoundaries(longGrapheme)
    throw ProbeFailure.assertion("an oversized single grapheme was unexpectedly split")
  } catch ProbeFailure.oversizedGrapheme(let units) {
    try check(units > maximumUTF16UnitsPerEvent, "oversized grapheme count is wrong")
    print("oversized grapheme correctly rejected: UTF16=\(units)")
  }

  let point = CGPoint(x: -240, y: 180)
  guard let mouse = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                            mouseCursorPosition: point, mouseButton: .left) else {
    throw ProbeFailure.mouseEventCreation
  }
  mouse.setIntegerValueField(.mouseEventDeltaX, value: 11)
  mouse.setIntegerValueField(.mouseEventDeltaY, value: -7)
  try check(mouse.location == point, "mouse event did not retain global absolute coordinates")
  try check(mouse.getIntegerValueField(.mouseEventDeltaX) == 11, "horizontal delta was not retained")
  try check(mouse.getIntegerValueField(.mouseEventDeltaY) == -7, "vertical delta was not retained")
  print("mouse absolute=\(mouse.location), delta=(11,-7)")
  print("event posting access already granted=\(CGPreflightPostEventAccess())")
  print("No events were posted.")
}

do {
  let arguments = Array(CommandLine.arguments.dropFirst())
  if arguments.isEmpty {
    try run()
  } else if arguments == ["--request-post-access"] {
    let granted = CGRequestPostEventAccess()
    print("event-posting access granted=\(granted)")
    if !granted { print("No events were posted.") }
  } else if arguments.count == 2, arguments[0] == "--post-textedit-sample" {
    guard let rawPID = Int32(arguments[1]) else { throw ProbeFailure.invalidArguments }
    try postFixedSample(to: pid_t(rawPID))
  } else {
    throw ProbeFailure.invalidArguments
  }
} catch {
  fputs("Phase 0 macOS probe failed: \(error)\n", stderr)
  exit(EXIT_FAILURE)
}
