// SPDX-License-Identifier: GPL-3.0-or-later
// Standalone call-probe entry point.
import Foundation

// MARK: - Entry point

let rawArguments = Array(CommandLine.arguments.dropFirst())
let options: ProbeOptions
do {
  options = try ProbeOptions.parse(rawArguments)
} catch {
  FileHandle.standardError.write(Data((String(describing: error) + "\n\n" + ProbeOptions.usage + "\n").utf8))
  exit(2)
}

let log = ProbeLog(path: options.logPath)
let results = ProbeResults()

// IOBluetooth's delegate callbacks need a live run loop. The probe therefore
// runs its async body in a task while the main thread services run-loop events.
Task { @MainActor in
  do {
    let code = try await runProbe(options: options, log: log, results: results)
    results.print(to: log)
    log.heading("Finished")
    exit(code)
  } catch let failure as ProbeFailure {
    log.line("")
    log.line("FAILED: " + failure.description)
    results.record("Probe", .fail, failure.description)
    results.print(to: log)
    exit(failure.exitCode)
  } catch {
    log.line("")
    log.line("FAILED: " + String(describing: error))
    results.record("Probe", .fail, String(describing: error))
    results.print(to: log)
    exit(4)
  }
}

RunLoop.main.run()
