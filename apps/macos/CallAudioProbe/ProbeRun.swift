// SPDX-License-Identifier: GPL-3.0-or-later
// Gate 1 audio-exposure probe.
//
// Answers one question: after the Mac's Hands-Free service connection to a
// paired phone is up and a call is active, does macOS expose a usable
// Bluetooth Classic audio endpoint that aniCe could bridge to the built-in
// microphone and speakers? A connected RFCOMM channel, an SDP record or a
// device name is not evidence; only an enumerable endpoint with usable input
// and output streams and valid input and initialized output buffers is.
//
// This probe is the opening part of Gate 1, not completion of Gate 1. Two-way
// speech, echo behaviour and phone-audio handback still require physical
// testing afterwards.
import Foundation
import IOBluetooth

// MARK: - Environment

@MainActor
func reportEnvironment(_ log: ProbeLog) {
  let version = ProcessInfo.processInfo.operatingSystemVersion
  log.heading("Environment")
  log.detail("macOS", "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")
  log.detail("process", Bundle.main.bundlePath)
  #if arch(x86_64)
    log.detail("translated", "yes or no (x86_64 build on Apple silicon is reported by the OS)")
  #else
    log.detail("translated", "no")
  #endif
  let controller = IOBluetoothHostController.default()
  let hostAddress = controller?.addressAsString() ?? "(unavailable)"
  log.detail("Mac Classic address", hostAddress)
  if let parsed = ClassicAddress.parse(hostAddress), let reason = ClassicAddress.rejectionReason(parsed) {
    log.result("Mac address rejected as identity: " + reason)
  }
  log.detail(
    "power",
    controller.map { $0.powerState == kBluetoothHCIPowerStateON ? "on" : "off" } ?? "controller unavailable")
  log.detail("microphone (TCC)", MicrophoneAccess.stateName)
  if !MicrophoneAccess.isGranted {
    log.result("Microphone access is not granted for this process.")
    log.line(MicrophoneAccess.remedy)
  }
}

// MARK: - Paired device listing

@MainActor
func listPairedDevices(_ log: ProbeLog) {
  log.heading("System-paired Classic devices")
  let paired = HFPProbe.pairedDevices()
  guard !paired.isEmpty else {
    log.result("None. Pair the phone in System Settings → Bluetooth, then rerun.")
    return
  }
  for device in paired {
    let address = device.addressString ?? "(no address)"
    let canonical = ClassicAddress.parse(address).map(ClassicAddress.canonical) ?? "(unparseable)"
    log.line(
      "- \(device.name ?? "(unnamed)") | \(canonical) | paired=\(device.isPaired()) "
        + "connected=\(device.isConnected())")
  }
  log.result("Pass one of these addresses with --device; names are never used for selection.")
}

// MARK: - The probe run

struct EndpointVerdict {
  let state: ProbeResultState
  let detail: String
}

@MainActor
func evaluateBluetoothEndpoints(
  before: CoreAudioSnapshot?, after: CoreAudioSnapshot, results: ProbeResults, log: ProbeLog,
  testAudio: Bool, microphoneChecked: Bool, selectedAddress: String,
  audioStillConnected: () -> Bool
) async -> EndpointVerdict {
  log.heading("Selected phone endpoint evaluation")
  let candidates = after.bluetoothDevices.filter {
    endpointMatchesPhone($0, address: selectedAddress)
  }
  func finish(_ state: ProbeResultState, _ detail: String) -> EndpointVerdict {
    results.record("Bluetooth Classic audio endpoint", state, detail)
    return EndpointVerdict(state: state, detail: detail)
  }
  guard audioStillConnected() else {
    return finish(.unknown, "call or SCO ended before endpoint evaluation")
  }
  guard !candidates.isEmpty else {
    return finish(.unknown, "no Classic endpoint UID identifies the selected phone; OS limitation unproven")
  }
  guard testAudio else { return finish(.unknown, "phone endpoint found; buffer check skipped") }
  guard microphoneChecked && MicrophoneAccess.isGranted else {
    return finish(.unknown, "microphone permission missing or check bypassed; rerun with --request-mic")
  }
  var failures: [String] = []
  for device in candidates {
    guard device.alive, device.inputCount > 0, device.outputCount > 0 else {
      failures.append("\(device.name): endpoint is not alive with both stream directions")
      continue
    }
    log.result("Phone endpoint: \(device.name) | uid=\(device.uid ?? "")")
    let outcome = await runAudioBufferCheck(on: device)
    guard audioStillConnected() else {
      return finish(.unknown, "call or SCO ended during buffer check")
    }
    switch outcome {
    case .usable(let callbacks, let seconds, let latency):
      return finish(.pass, "phone-associated endpoint delivered valid input and zero-filled output buffers in \(callbacks) callbacks / \(seconds)s (first callback \(latency)s); speech unverified")
    case .failed(let reason): failures.append("\(device.name): \(reason)")
    }
  }
  return finish(.fail, failures.joined(separator: "; "))
}

func formatSnapshotJSON(
  _ options: ProbeOptions, before: CoreAudioSnapshot?, after: CoreAudioSnapshot
) -> [String: Any] {
  func deviceObject(_ device: ProbeDevice) -> [String: Any] {
    [
      "identifier": Int(device.identifier),
      "name": device.name,
      "uid": device.uid ?? NSNull(),
      "transport": device.transportName ?? NSNull(),
      "inputs": device.inputCount,
      "outputs": device.outputCount,
      "running": device.isRunning ?? false,
      "streams": device.streams.map { stream in
        [
          "identifier": Int(stream.identifier),
          "direction": stream.direction,
          "virtualFormat": stream.virtualFormat ?? NSNull(),
          "physicalFormat": stream.physicalFormat ?? NSNull(),
        ] as [String: Any]
      },
    ]
  }
  var payload: [String: Any] = [
    "host": after.hostVersion,
    "deviceSelection": options.device ?? "",
    "audioSetupMode": options.phoneAudioOnly ? "phoneInitiatedOnly" : "nativeTransfer",
    "after": after.devices.map(deviceObject),
    "bluetoothClassic": after.bluetoothDevices.map { $0.name },
    "bluetoothLE": after.bluetoothLEDevices.map { $0.name },
    "results": NSNull(),
  ]
  if let before { payload["before"] = before.devices.map(deviceObject) }
  return payload
}

@MainActor
func runProbe(options: ProbeOptions, log: ProbeLog, results: ProbeResults) async throws -> Int32 {
  reportEnvironment(log)
  if options.requestMicrophone {
    log.step("Requesting microphone access")
    let granted = await MicrophoneAccess.requestOnce()
    log.result("Microphone access " + (granted ? "granted" : "not granted"))
    if !granted { log.line(MicrophoneAccess.remedy) }
  }
  if options.listDevices {
    listPairedDevices(log)
    return 0
  }
  guard let addressText = options.device else {
    throw ProbeFailure.usage("--device ADDRESS is required (see --help)")
  }
  guard let address = ClassicAddress.parse(addressText) else {
    throw ProbeFailure.device("'\(addressText)' is not a six-byte Classic address")
  }
  if let reason = ClassicAddress.rejectionReason(address) {
    throw ProbeFailure.device("address \(ClassicAddress.canonical(address)) rejected: " + reason)
  }

  let probe = HFPProbe(log: log, address: address)
  defer { probe.close() }

  // Snapshot before any connection work so a pre-existing headset endpoint is
  // visible rather than attributed to the phone.
  var before: CoreAudioSnapshot?
  if !options.skipPreSnapshot {
    log.heading("CoreAudio snapshot before HFP connection")
    let snapshot = takeCoreAudioSnapshot()
    before = snapshot
    log.line(encodeSnapshot(snapshot))
    results.record(
      "Baseline snapshot", .pass, "\(snapshot.devices.count) devices, "
        + "\(snapshot.bluetoothDevices.count) Bluetooth Classic")
  }

  let device = try probe.selectDevice()
  results.record("Device selection", .pass, device.name ?? ClassicAddress.canonical(address))
  if !device.isConnected() {
    log.result(
      "Note: the phone is paired but its Classic link is currently down. The probe will raise "
        + "it for the SDP query; in System Settings → Bluetooth, confirm the phone is paired and "
        + "Bluetooth is on.")
  }

  let channelID: UInt8
  do {
    channelID = try await probe.queryAudioGatewayService()
  } catch {
    results.record("SDP / Audio Gateway service", .fail, "\(error)")
    throw error
  }
  results.record("SDP / Audio Gateway service", .pass, "RFCOMM channel \(channelID)")

  do {
    try await probe.openConnection(to: device, channelID: channelID)
    try await probe.establishServiceLevelConnection()
    results.record("Hands-Free Service Level Connection", .pass, "native SLC completed")
  } catch {
    results.record("Hands-Free Service Level Connection", .fail, "\(error)")
    probe.close()
    throw error
  }

  // Separate the two questions the probe must keep apart: whether the link is
  // up (proven here), and whether audio exists (only proven after call
  // activation). An endpoint that appears merely from the connection is noted,
  // but SCO audio is not expected until a call is active.
  let afterConnection = takeCoreAudioSnapshot()
  let connectedBluetooth = afterConnection.bluetoothDevices
  if connectedBluetooth.isEmpty {
    log.result("No Bluetooth Classic CoreAudio device appeared from the HFP connection alone.")
  } else {
    log.result(
      "Bluetooth Classic CoreAudio devices present after the HFP connection: "
        + connectedBluetooth.map { "\($0.name) (in=\($0.inputCount), out=\($0.outputCount))" }
        .joined(separator: ", "))
    log.result("Call audio is still unproven until the active-call snapshot.")
  }

  // A call is required: HFP audio exists for calls. The probe never infers
  // call audio from a connected link.
  if let number = options.dial {
    try probe.dial(number)
  }
  if options.answer {
    log.step("Waiting briefly for an incoming call to answer")
    let ringDeadline = ContinuousClock.now.advanced(by: .seconds(10))
    while ContinuousClock.now < ringDeadline && !probe.ringing {
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    if probe.ringing {
      try probe.answer()
    } else {
      results.record("Call answer", .skipped, "no RING within 10 seconds")
    }
  }
  var commandTask: Task<Void, Never>?
  defer { commandTask?.cancel() }
  if options.interactive {
    log.heading("Interactive commands")
    log.result("Type: answer | dial NUMBER | hangup | snapshot | status | quit")
    let input = AsyncStream<String> { continuation in
      Task.detached {
        while let line = readLine(strippingNewline: true) { continuation.yield(line) }
        continuation.finish()
      }
    }
    let commands = Task { @MainActor in
      for await line in input {
        if Task.isCancelled { break }
        switch line.trimmingCharacters(in: .whitespaces) {
        case "answer":
          do { try probe.answer() }
          catch { log.result("Answer command failed: \(error)") }
        case "hangup": probe.hangUp()
        case "quit":
          log.step("Quit command received; closing native probe connection")
          probe.close()
          return
        case "status": log.result("state=\(probe.state.rawValue) call=\(probe.callActive) SCO=\(probe.audioConnected)")
        case "snapshot": log.line(encodeSnapshot(takeCoreAudioSnapshot()))
        default:
          if line.hasPrefix("dial ") { try? probe.dial(String(line.dropFirst(5))) }
        }
      }
    }
    commandTask = commands
  }

  var callReached = probe.callActive
  if callReached {
    results.record("Active call", .pass, "call indicator active")
  } else {
    do {
      try await probe.waitForActiveCall(timeout: options.waitSeconds)
      callReached = true
      results.record("Active call", .pass, "call indicator became active")
    } catch {
      results.record("Active call", .fail, "\(error)")
    }
  }

  if callReached {
    log.heading("CoreAudio snapshot with call active")
    guard await probe.establishAudio(phoneInitiatedOnly: options.phoneAudioOnly) else {
      results.record("Native SCO audio", .unknown, "audio setup incomplete; OS endpoint limitation unproven")
      let after = takeCoreAudioSnapshot()
      log.heading("CoreAudio snapshot after unsuccessful audio transfer")
      log.line(encodeSnapshot(after))
      let released = await probe.releaseAudio()
      results.record("SCO release", released ? .pass : .unknown)
      if let jsonPath = options.jsonPath {
        var payload = formatSnapshotJSON(options, before: before, after: after)
        payload["verdict"] = "native audio setup incomplete; endpoint exposure unproven"
        payload["verdictState"] = ProbeResultState.unknown.rawValue
        payload["results"] = results.jsonEntries
        do {
          let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
          try data.write(to: jsonPath)
          log.detail("json", jsonPath.path)
        } catch { log.result("Could not save JSON: \(error)") }
      }
      return 7
    }
    results.record("Native SCO audio", .pass, "native SCO connection confirmed")
    let endpointDeadline = ContinuousClock.now.advanced(by: .seconds(10))
    var after = takeCoreAudioSnapshot()
    while ContinuousClock.now < endpointDeadline && probe.audioConnected && probe.callActive {
      if after.bluetoothDevices.contains(where: {
        endpointMatchesPhone($0, address: addressText) && $0.inputCount > 0 && $0.outputCount > 0
      }) { break }
      try await Task.sleep(for: .milliseconds(200))
      after = takeCoreAudioSnapshot()
    }
    log.line(encodeSnapshot(after))
    log.heading("CoreAudio difference")
    if let before {
      let changes = compareSnapshots(before: before, after: after)
      log.line(changes.isEmpty ? "  no device or stream changes" : changes.map { "  " + $0 }.joined(separator: "\n"))
    } else {
      log.line("  pre-call snapshot was skipped")
    }

    let verdict = await evaluateBluetoothEndpoints(
      before: before, after: after, results: results, log: log,
      testAudio: !options.skipAudioTest, microphoneChecked: !options.skipMicrophoneCheck,
      selectedAddress: addressText, audioStillConnected: { probe.audioConnected && probe.callActive })


    log.heading("Reminder")
    log.result(
      "This probe establishes audio exposure only. Two-way speech, echo behaviour, mute, handback "
        + "to the phone and cleanup still require physical acceptance in the packaged runtime.")

    let released = await probe.releaseAudio()
    results.record("SCO release", released ? .pass : .unknown, "physical phone-audio handback remains unverified")
    if let jsonPath = options.jsonPath {
      var payload = formatSnapshotJSON(options, before: before, after: after)
      payload["verdict"] = verdict.detail
      payload["verdictState"] = verdict.state.rawValue
      payload["results"] = results.jsonEntries
      if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: jsonPath)
        log.detail("json", jsonPath.path)
      }
    }

    if !released { return 7 }
    return verdict.state == .pass ? 0 : (verdict.state == .unknown ? 7 : 6)
  }

  probe.close()
  // The outer handler prints the result table and exits with this code.
  return 5
}
