// SPDX-License-Identifier: GPL-3.0-or-later
// Marshals PIN-pairing operations through the Rust C ABI and clears temporary buffers.
import Foundation

enum NativePake {
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
