// SPDX-License-Identifier: GPL-3.0-or-later
// Lists and runs locally approved system Shortcuts with bounded process lifetime.
import Foundation

struct MacDeskDeckSystemShortcut: Equatable, Identifiable {
  let identifier: String
  let name: String
  var id: String { identifier }
}

private final class DeskDeckProcessState: @unchecked Sendable {
  private let lock = NSLock()
  private var process: Process?
  private var cancelled = false

  func start(_ process: Process) throws -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !cancelled else { return false }
    self.process = process
    try process.run()
    return true
  }

  func finish() {
    lock.lock()
    process = nil
    lock.unlock()
  }

  func terminate() {
    lock.lock()
    cancelled = true
    let process = self.process
    lock.unlock()
    guard let process, process.isRunning else { return }
    process.terminate()
    let processID = process.processIdentifier
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
      self?.forceTerminate(processID)
    }
  }

  private func forceTerminate(_ processID: Int32) {
    lock.lock()
    defer { lock.unlock() }
    guard let process, process.processIdentifier == processID, process.isRunning else { return }
    _ = kill(processID, SIGKILL)
  }
}

private final class DeskDeckProcessOutput: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = Data()

  func append(_ data: Data) {
    guard !data.isEmpty else { return }
    lock.lock()
    let remaining = max(0, 256 * 1024 - storage.count)
    if remaining > 0 { storage.append(data.prefix(remaining)) }
    lock.unlock()
  }

  var data: Data {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}

enum MacDeskDeckShortcutRunner {
  private static let executable = URL(fileURLWithPath: "/usr/bin/shortcuts")
  private static let identifierPattern = try! NSRegularExpression(
    pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")

  static func parseList(_ output: String) -> [MacDeskDeckSystemShortcut] {
    var seen = Set<String>()
    let rows = output.split(whereSeparator: \.isNewline).compactMap { rawLine -> MacDeskDeckSystemShortcut? in
      let line = String(rawLine)
      let range = NSRange(line.startIndex..<line.endIndex, in: line)
      guard let match = identifierPattern.firstMatch(in: line, range: range),
        let idRange = Range(match.range, in: line) else { return nil }
      let identifier = String(line[idRange])
      guard UUID(uuidString: identifier) != nil, seen.insert(identifier.lowercased()).inserted else { return nil }
      let before = String(line[..<idRange.lowerBound])
      let after = String(line[idRange.upperBound...])
      let rawName = [before, after].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: " ")
      let name = rawName.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "()[]{}")))
      guard !name.isEmpty, name.utf16.count <= 80,
        !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
      return MacDeskDeckSystemShortcut(identifier: identifier, name: name)
    }
    return rows.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  static func list() async -> (shortcuts: [MacDeskDeckSystemShortcut], available: Bool) {
    let result = await run(["list", "--show-identifiers"], timeout: 5, captureOutput: true)
    guard result.status == 0 else { return ([], false) }
    return (parseList(String(decoding: result.output, as: UTF8.self)), true)
  }

  static func run(identifier: String) async -> Int64 {
    guard UUID(uuidString: identifier) != nil else { return 5 }
    let result = await run(["run", identifier], timeout: 5, captureOutput: false)
    return resultCode(result.status)
  }

  static func resultCode(_ processStatus: Int32) -> Int64 { processStatus == 0 ? 0 : 7 }

  private static func run(_ arguments: [String], timeout: TimeInterval, captureOutput: Bool) async -> (status: Int32, output: Data) {
    let state = DeskDeckProcessState()
    let output = DeskDeckProcessOutput()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        if captureOutput {
          process.standardOutput = pipe
          pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { output.append(chunk) }
          }
        } else {
          process.standardOutput = FileHandle.nullDevice
        }
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { child in
          if captureOutput {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
              pipe.fileHandleForReading.readabilityHandler = nil
              output.append(pipe.fileHandleForReading.availableData)
              state.finish()
              continuation.resume(returning: (child.terminationStatus, output.data))
            }
          } else {
            state.finish()
            continuation.resume(returning: (child.terminationStatus, Data()))
          }
        }
        do {
          guard try state.start(process) else {
            state.finish()
            continuation.resume(returning: (-1, Data()))
            return
          }
        } catch {
          state.finish()
          continuation.resume(returning: (-1, Data()))
          return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { state.terminate() }
      }
    } onCancel: {
      state.terminate()
    }
  }
}
