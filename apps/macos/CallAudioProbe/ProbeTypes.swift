// SPDX-License-Identifier: GPL-3.0-or-later
// Value types shared by the Gate 1 probe's snapshot, CLI and HFP layers.
import CoreAudio
import Foundation

/// CoreAudio stream identity, direction and reported virtual/physical formats.
struct ProbeStream {
  var identifier: AudioObjectID
  var direction: String = "input"
  var name: String?
  var virtualFormat: String?
  var physicalFormat: String?
  var terminalType: UInt32?
}

struct ProbeDevice {
  var identifier: AudioObjectID
  var name: String
  var uid: String?
  var transport: OSType?
  var transportName: String?
  var isRunning: Bool?
  var alive: Bool
  var streams: [ProbeStream]

  var inputCount: Int { streams.filter { $0.direction == "input" }.count }
  var outputCount: Int { streams.filter { $0.direction == "output" }.count }
}

// MARK: - Classic Bluetooth address handling

enum ClassicAddress {
  /// Parses the OS form ("AA-BB-CC-DD-EE-FF"), the colon form and the bare
  /// 12-nibble form into exactly six bytes. Anything else is rejected rather
  /// than normalized into a plausible-looking address.
  static func parse(_ text: String) -> [UInt8]? {
    let separators = CharacterSet(charactersIn: ":-")
    let parts = text.components(separatedBy: separators).filter { !$0.isEmpty }
    var bytes: [UInt8] = []
    if parts.count == 1 {
      guard parts[0].count == 12 else { return nil }
      let digits = Array(parts[0])
      for index in stride(from: 0, to: 12, by: 2) {
        guard let value = UInt8(String(digits[index...index + 1]), radix: 16) else { return nil }
        bytes.append(value)
      }
    } else {
      guard parts.count == 6 else { return nil }
      for part in parts {
        guard part.count == 2, let value = UInt8(part, radix: 16) else { return nil }
        bytes.append(value)
      }
    }
    return bytes
  }

  /// Reports why an address cannot be used as a stable identity rather than
  /// silently accepting placeholders. `nil` means acceptable.
  static func rejectionReason(_ bytes: [UInt8]) -> String? {
    guard bytes.count == 6 else { return "address must be exactly six bytes" }
    if bytes.allSatisfy({ $0 == 0 }) { return "all-zero address is a placeholder" }
    if bytes.allSatisfy({ $0 == 0xFF }) { return "all-FF address is a placeholder" }
    if bytes[0] & 0x01 != 0 { return "multicast bit is set; not a unicast device address" }
    return nil
  }

  static func canonical(fromText text: String) -> String? {
    guard let bytes = parse(text), rejectionReason(bytes) == nil else { return nil }
    return canonical(bytes)
  }

  static func canonical(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
  }

  static func matchesAsteriskForm(uid: String, address: String) -> Bool {
    guard let bytes = parse(address) else { return false }
    let hex = bytes.map { String(format: "%02x", $0) }
    let forms = [hex.joined(), hex.joined(separator: "-"), hex.joined(separator: ":")]
    let lowered = uid.lowercased()
    return forms.contains { form in
      lowered.range(of: "(?<![0-9a-f])" + form + "(?![0-9a-f])", options: .regularExpression) != nil
    }
  }

}

// MARK: - Command-line options

struct ProbeOptions {
  var device: String?
  var listDevices = false
  var dial: String?
  var answer = false
  var interactive = false
  var skipPreSnapshot = false
  var skipAudioTest = false
  var skipMicrophoneCheck = false
  var requestMicrophone = false
  var phoneAudioOnly = false
  var waitSeconds: Double = 45
  var logPath: URL?
  var jsonPath: URL?

  static let usage = """
    CallAudioProbe — Gate 1 Hands-Free audio-exposure probe for aniCe.

    Build: python3 scripts/build-call-audio-probe.py
    Run:   build/CallAudioProbe.app/Contents/MacOS/CallAudioProbe --device AA:BB:CC:DD:EE:FF

    Required:
      --device ADDR          Six-byte Classic address of the paired Audio Gateway
                             (the phone). Display names are never treated as identity.

    Execution:
      --dial NUMBER          Place a controlled outgoing call through the AG.
      --answer               Answer the next incoming call when RING arrives.
      --interactive          Read commands from stdin (answer, dial, hangup,
                             snapshot, status, quit). Commands run only after the
                             Hands-Free service connection is up.
      --phone-audio-only     After answering, wait for phone-initiated SCO without
                             invoking a Mac audio-transfer request. Native feature
                             advertisement and codec handling remain unchanged.
      --wait SECONDS         How long to wait for an active call (default 45).
      --no-pre-snapshot      Skip the pre-call CoreAudio snapshot.
      --no-audio-test        Skip the bounded input/output buffer check.
      --skip-mic-test        Skip the buffer check and
                             report UNKNOWN instead; the probe never prompts.
      --request-mic          Ask macOS for microphone access at startup so the
                             app gains an entry in System Settings. Without this
                             the probe only reads the current answer.

    Inspection:
      --list-devices         Print paired Classic devices and exit.
      --log FILE             Write the transcript to FILE (the console always
                             receives it as well).
      --json FILE            Write the CoreAudio snapshots and result table as JSON.
      --help                 Print this text.

    Exit codes:
      0  audio-exposure evidence collected (see the result table)
      2  invalid arguments
      3  device not found or not paired
      4  Hands-Free service connection or SLC negotiation failed
      5  no active call reached the probe
      6  phone endpoint failed the buffer check
      7  inconclusive setup, identity, permission or audio release
    """

  static func parse(_ arguments: [String]) throws -> ProbeOptions {
    var options = ProbeOptions()
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      func value() throws -> String {
        guard index + 1 < arguments.count else {
          throw ProbeFailure.usage("missing value for " + argument)
        }
        index += 1
        return arguments[index]
      }
      switch argument {
      case "--device": options.device = try value()
      case "--dial": options.dial = try value()
      case "--wait":
        let text = try value()
        guard let seconds = Double(text), seconds > 0, seconds <= 600 else {
          throw ProbeFailure.usage("--wait expects seconds in (0, 600]")
        }
        options.waitSeconds = seconds
      case "--log": options.logPath = URL(fileURLWithPath: try value())
      case "--json": options.jsonPath = URL(fileURLWithPath: try value())
      case "--answer": options.answer = true
      case "--interactive": options.interactive = true
      case "--no-pre-snapshot": options.skipPreSnapshot = true
      case "--no-audio-test": options.skipAudioTest = true
      case "--skip-mic-test": options.skipMicrophoneCheck = true
      case "--request-mic": options.requestMicrophone = true
      case "--phone-audio-only": options.phoneAudioOnly = true
      case "--list-devices": options.listDevices = true
      case "--help", "-h":
        print(usage)
        exit(0)
      default:
        throw ProbeFailure.usage("unknown argument " + argument)
      }
      index += 1
    }
    return options
  }
}

enum ProbeFailure: Error, CustomStringConvertible {
  case usage(String)
  case device(String)
  case handsFree(String)
  case call(String)
  case audio(String)

  var description: String {
    switch self {
    case .usage(let text): return "usage: " + text
    case .device(let text): return "device: " + text
    case .handsFree(let text): return "hands-free: " + text
    case .call(let text): return "call: " + text
    case .audio(let text): return "audio: " + text
    }
  }

  var exitCode: Int32 {
    switch self {
    case .usage: return 2
    case .device: return 3
    case .handsFree: return 4
    case .call: return 5
    case .audio: return 6
    }
  }
}

func endpointMatchesPhone(_ device: ProbeDevice, address: String) -> Bool {
  device.transport == kAudioDeviceTransportTypeBluetooth &&
    device.uid.map { ClassicAddress.matchesAsteriskForm(uid: $0, address: address) } == true
}
