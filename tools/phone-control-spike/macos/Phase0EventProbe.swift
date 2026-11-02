// SPDX-License-Identifier: GPL-3.0-or-later
// Small GUI wrapper for the explicitly approved, TextEdit-only Phase 0 delivery check.
import AppKit
import CoreGraphics
import SwiftUI

private let maximumUTF16UnitsPerEvent = 16
private let fixedSample = "aniCe Phase 0: café — नमस्ते 👩🏽‍💻"

@main
private struct Phase0EventProbe: App {
  var body: some Scene {
    WindowGroup("aniCe Phase 0 Event Probe") {
      ProbeView()
        .frame(width: 460, height: 260)
    }
  }
}

private struct ProbeView: View {
  @State private var status = CGPreflightPostEventAccess()
    ? "Event-posting access is already granted."
    : "Event-posting access has not been granted."

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("TextEdit delivery check")
        .font(.title2.weight(.semibold))
      Text("The send button targets Apple TextEdit only and inserts one fixed multilingual sample. It sends no mouse events.")
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Button("Request event access", action: requestAccess)
        Button("Send sample to TextEdit", action: sendSample)
      }
      Text(status)
        .font(.callout)
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
    }
    .padding(22)
  }

  private func requestAccess() {
    let granted = CGRequestPostEventAccess()
    status = granted
      ? "Event-posting access is granted."
      : "Access is not granted yet. Check macOS Privacy & Security settings."
  }

  private func sendSample() {
    guard CGPreflightPostEventAccess() else {
      status = "Access is not granted; no events were sent."
      return
    }
    guard let target = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first else {
      status = "Open TextEdit with a blank document first; no events were sent."
      return
    }
    guard target.activate(options: []) else {
      status = "TextEdit could not be activated; no events were sent."
      return
    }

    status = "Sending the fixed sample to TextEdit…"
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      do {
        let chunks = try chunksAtGraphemeBoundaries(fixedSample)
        for chunk in chunks {
          let pair = try makeUnicodePair(for: chunk)
          pair.down.postToPid(target.processIdentifier)
          Thread.sleep(forTimeInterval: 0.02)
          pair.up.postToPid(target.processIdentifier)
          Thread.sleep(forTimeInterval: 0.04)
        }
        status = "Sent \(fixedSample.utf16.count) UTF-16 units in \(chunks.count) chunks to TextEdit."
      } catch {
        status = "The probe could not construct the sample events: \(error.localizedDescription)"
      }
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
    guard units <= maximumUTF16UnitsPerEvent else {
      throw ProbeError.oversizedGrapheme(units)
    }
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
    throw ProbeError.eventCreation
  }
  let units = Array(chunk.utf16)
  units.withUnsafeBufferPointer { buffer in
    keyDown.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
    keyUp.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
  }
  return (keyDown, keyUp)
}

private enum ProbeError: Error, LocalizedError {
  case oversizedGrapheme(Int)
  case eventCreation

  var errorDescription: String? {
    switch self {
    case .oversizedGrapheme(let size): "One grapheme needs \(size) UTF-16 units."
    case .eventCreation: "Core Graphics could not create a keyboard event."
    }
  }
}
