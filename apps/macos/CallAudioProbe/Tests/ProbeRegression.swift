// SPDX-License-Identifier: GPL-3.0-or-later
// Standalone regressions; no Bluetooth, microphone access or calls required.
import CoreAudio
import Foundation
import IOBluetooth

@main
struct ProbeRegression {
  @MainActor
  static func main() async {
    let phone = "A0:B1:C2:D3:E4:F5"
    func endpoint(_ uid: String?, transport: OSType = kAudioDeviceTransportTypeBluetooth) -> ProbeDevice {
      ProbeDevice(identifier: 0, name: "Untrusted display name", uid: uid, transport: transport,
        transportName: "blue", isRunning: false, alive: true,
        streams: [ProbeStream(identifier: 1), ProbeStream(identifier: 2, direction: "output")])
    }
    precondition(endpointMatchesPhone(endpoint("A0-B1-C2-D3-E4-F5:input"), address: phone))
    precondition(endpointMatchesPhone(endpoint("Bluetooth_a0b1c2d3e4f5"), address: phone))
    precondition(!endpointMatchesPhone(endpoint("A0-B1-C2-D3-E4-F6"), address: phone))
    precondition(!endpointMatchesPhone(endpoint("0a0b1c2d3e4f50"), address: phone))
    precondition(!endpointMatchesPhone(endpoint(nil), address: phone))
    precondition(!endpointMatchesPhone(endpoint(phone, transport: kAudioDeviceTransportTypeBluetoothLE), address: phone))

    let log = ProbeLog(path: nil)
    let snapshot = CoreAudioSnapshot(devices: [endpoint("00-11-22-33-44-55")], hostVersion: "fixture")
    let unrelated = await evaluateBluetoothEndpoints(before: snapshot, after: snapshot,
      results: ProbeResults(), log: log, testAudio: true, microphoneChecked: true,
      selectedAddress: phone, audioStillConnected: { true })
    precondition(unrelated.state == .unknown)
    let associated = CoreAudioSnapshot(devices: [endpoint(phone)], hostVersion: "fixture")
    let bypass = await evaluateBluetoothEndpoints(before: nil, after: associated,
      results: ProbeResults(), log: log, testAudio: true, microphoneChecked: false,
      selectedAddress: phone, audioStillConnected: { true })
    precondition(bypass.state == .unknown)
    let skipped = await evaluateBluetoothEndpoints(before: nil, after: associated,
      results: ProbeResults(), log: log, testAudio: false, microphoneChecked: true,
      selectedAddress: phone, audioStillConnected: { true })
    precondition(skipped.state == .unknown)

    var empty = AudioBufferList(mNumberBuffers: 1,
      mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 64, mData: nil))
    precondition(validAudioBytes(&empty) == 0)
    var data = [UInt8](repeating: 0xA5, count: 64)
    data.withUnsafeMutableBytes { raw in
      var buffer = AudioBufferList(mNumberBuffers: 1,
        mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 64, mData: raw.baseAddress))
      precondition(validAudioBytes(&buffer) == 64)
      precondition(silenceOutput(&buffer) == 64)
    }
    precondition(data.allSatisfy { $0 == 0 })
    // Closing while waiting must finish promptly instead of consuming the
    // configured two-minute call timeout. No native device is created here.
    let waitingProbe = HFPProbe(log: log, address: ClassicAddress.parse(phone)!)
    do {
      try waitingProbe.answer()
      preconditionFailure("Answer must reject a missing native connection")
    } catch let failure as ProbeFailure {
      precondition(failure.exitCode == 4)
    } catch { preconditionFailure("unexpected Answer error: \(error)") }
    let started = ContinuousClock.now
    let closer = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(25))
      waitingProbe.close()
    }
    do {
      try await waitingProbe.waitForActiveCall(timeout: 120)
      preconditionFailure("closed probe must not report an active call")
    } catch {
      precondition(started.duration(to: .now) < .seconds(2))
      precondition(waitingProbe.state == .closed)
    }
    await closer.value
    let interrupted = await evaluateBluetoothEndpoints(before: nil, after: associated,
      results: ProbeResults(), log: log, testAudio: true, microphoneChecked: true,
      selectedAddress: phone, audioStillConnected: { false })
    precondition(interrupted.state == .unknown)
    do {
      let passive = try ProbeOptions.parse(["--device", phone, "--phone-audio-only", "--wait", "120"])
      precondition(passive.phoneAudioOnly)
      precondition(passive.device == phone && passive.waitSeconds == 120)
      let standard = try ProbeOptions.parse(["--device", phone])
      precondition(!standard.phoneAudioOnly)
      let snapshotJSON = formatSnapshotJSON(passive, before: nil, after: associated)
      precondition(snapshotJSON["audioSetupMode"] as? String == "phoneInitiatedOnly")
    } catch { preconditionFailure("passive audio options rejected: \(error)") }
    let unsupported: OSStatus = -536870201
    precondition(unsupported.fourCCDescription.contains("unsupported function"))
    print("PASS: phone association, unrelated headset, permission/skip verdicts, valid buffers, silent output, interrupted setup, quit while waiting and passive-mode options/JSON")
  }
}
