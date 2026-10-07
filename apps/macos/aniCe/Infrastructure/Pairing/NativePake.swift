// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Bridge to the native Rust PAKE static library (`libanice_pairing.a`).
///
/// Invokes `anice_pake` via the declared C ABI header. Automatically serializes
/// length-prefixed argument fields and ensures temporary memory buffers are wiped
/// via `resetBytes` upon exit.
enum NativePake {
  /// Invokes an operation on the in-memory OPAQUE state machine.
  ///
  /// - Parameters:
  ///   - op: Operation code (1: ServerRegister, 2: ClientLoginStart, 3: ServerLoginStart,
  ///         4: ClientLoginFinish, 5: ServerLoginFinish, 6: ReleaseHandle).
  ///   - fields: Length-prefixed argument byte arrays.
  /// - Returns: Output bytes returned by the PAKE runtime.
  static func call(_ op: UInt32, _ fields: [Data]) throws -> Data {
    var input = PairingCodec.fields(fields)
    guard !input.isEmpty else { throw PairingFailure.malformed }
    var output = [UInt8](repeating: 0, count: 4096)
    defer {
      input.resetBytes(in: 0..<input.count)
      _ = output.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
    }
    let n = input.withUnsafeBytes { p in
      guard let pointer = p.bindMemory(to: UInt8.self).baseAddress else { return -1 }
      return anice_pake(op, pointer, input.count, &output, output.count)
    }
    guard n > 0, n <= output.count else { throw PairingFailure.authentication }
    return Data(output.prefix(n))
  }
}
