// SPDX-License-Identifier: GPL-3.0-or-later
// Defines bounded session CBOR values and typed failures with readable presentation messages.
import Foundation

enum SessionFailure: String, LocalizedError, Sendable {
  case malformed, unsupportedProfile, untrustedPeer, authentication, state, cancelled, expired, controlTimeout
  var errorDescription: String? {
    switch self {
    case .malformed: "Invalid session message"
    case .unsupportedProfile: "These devices use incompatible session versions"
    case .untrustedPeer: "This device is no longer trusted"
    case .authentication: "Device authentication failed"
    case .state: "The connection is no longer ready"
    case .cancelled: "The connection closed"
    case .expired: "The session reached its time or message limit"
    case .controlTimeout: "The other device stopped responding"
    }
  }
}

indirect enum SessionCBOR: Equatable, Sendable {
  case integer(Int64)
  case bytes(Data)
  case text(String)
  case array([SessionCBOR])
  case map([Entry])
  case bool(Bool)
  struct Entry: Equatable, Sendable {
    let key: SessionCBOR
    let value: SessionCBOR
    init(_ key: SessionCBOR, _ value: SessionCBOR) {
      self.key = key
      self.value = value
    }
  }
  func bytes(_ size: Int? = nil) throws -> Data {
    guard case .bytes(let data) = self, size == nil || data.count == size else {
      throw SessionFailure.malformed
    }
    return data
  }
}

enum SessionCbor {
  static let maxBytes = 4096
  private static let maxItems = 512
  private static let maxDepth = 8

  static func sequence(_ values: SessionCBOR...) throws -> Data { try encodeValues(values) }
  static func encode(_ value: SessionCBOR, maximumBytes: Int = maxBytes) throws -> Data { try encodeValues([value], maximumBytes: maximumBytes) }

  private static func encodeValues(_ values: [SessionCBOR], maximumBytes: Int = maxBytes) throws -> Data {
    guard (1...524416).contains(maximumBytes) else { throw SessionFailure.malformed }
    var measuredItems = 0
    func headSize(_ n: UInt64) -> Int {
      n < 24 ? 1 : n <= 255 ? 2 : n <= 65535 ? 3 : n <= 0xffff_ffff ? 5 : 9
    }
    func adding(_ size: Int, _ next: Int) throws -> Int {
      guard next >= 0, next <= maximumBytes, size <= maximumBytes - next else {
        throw SessionFailure.malformed
      }
      return size + next
    }
    func measure(_ value: SessionCBOR, _ depth: Int) throws -> Int {
      measuredItems += 1
      guard depth <= maxDepth, measuredItems <= maxItems else { throw SessionFailure.malformed }
      switch value {
      case .integer(let n):
        return headSize(n >= 0 ? UInt64(n) : UInt64(-(n + 1)))
      case .bytes(let data):
        guard data.count <= maximumBytes else { throw SessionFailure.malformed }
        return try adding(headSize(UInt64(data.count)), data.count)
      case .text(let text):
        let count = text.utf8.count
        guard count <= maximumBytes else { throw SessionFailure.malformed }
        return try adding(headSize(UInt64(count)), count)
      case .array(let array):
        guard array.count <= maxItems else { throw SessionFailure.malformed }
        var size = headSize(UInt64(array.count))
        for item in array { size = try adding(size, measure(item, depth + 1)) }
        return size
      case .map(let map):
        guard map.count <= maxItems / 2 else { throw SessionFailure.malformed }
        for pair in map {
          switch pair.key {
          case .array, .map: throw SessionFailure.malformed
          default: break
          }
        }
        let sorted = try map.map { (try encode($0.key), $0) }.sorted { less($0.0, $1.0) }
        for i in sorted.indices.dropFirst() {
          guard sorted[i - 1].0 != sorted[i].0 else { throw SessionFailure.malformed }
        }
        var size = headSize(UInt64(sorted.count))
        for (encodedKey, pair) in sorted {
          let keySize = try measure(pair.key, depth + 1)
          guard keySize == encodedKey.count else { throw SessionFailure.malformed }
          size = try adding(size, keySize)
          size = try adding(size, measure(pair.value, depth + 1))
        }
        return size
      case .bool:
        return 1
      }
    }
    var encodedSize = 0
    for value in values { encodedSize = try adding(encodedSize, measure(value, 0)) }
    var out = Data(capacity: encodedSize)
    var items = 0
    func head(_ major: UInt8, _ n: UInt64) {
      let width = n < 24 ? 0 : n <= 255 ? 1 : n <= 65535 ? 2 : n <= 0xffff_ffff ? 4 : 8
      out.append(
        (major << 5)
          | (width == 0 ? UInt8(n) : width == 1 ? 24 : width == 2 ? 25 : width == 4 ? 26 : 27))
      if width > 0 {
        for i in stride(from: width - 1, through: 0, by: -1) {
          out.append(UInt8(truncatingIfNeeded: n >> (i * 8)))
        }
      }
    }
    func write(_ value: SessionCBOR, _ depth: Int) throws {
      items += 1
      guard depth <= maxDepth, items <= maxItems else { throw SessionFailure.malformed }
      switch value {
      case .integer(let n): head(n >= 0 ? 0 : 1, n >= 0 ? UInt64(n) : UInt64(-(n + 1)))
      case .bytes(let data):
        guard data.count <= maximumBytes else { throw SessionFailure.malformed }
        head(2, UInt64(data.count))
        out.append(data)
      case .text(let text):
        let data = Data(text.utf8)
        guard data.count <= maximumBytes else { throw SessionFailure.malformed }
        head(3, UInt64(data.count))
        out.append(data)
      case .array(let array):
        guard array.count <= maxItems else { throw SessionFailure.malformed }
        head(4, UInt64(array.count))
        for v in array { try write(v, depth + 1) }
      case .map(let map):
        guard map.count <= maxItems / 2 else { throw SessionFailure.malformed }
        for pair in map {
          switch pair.key {
          case .array, .map: throw SessionFailure.malformed
          default: break
          }
        }
        // Sort encoded keys deterministically; duplicate encodings cannot bind different values.
        let sorted = try map.map { (try encode($0.key), $0) }.sorted { less($0.0, $1.0) }
        for i in sorted.indices.dropFirst() {
          guard sorted[i - 1].0 != sorted[i].0 else { throw SessionFailure.malformed }
        }
        head(5, UInt64(sorted.count))
        for pair in sorted {
          try write(pair.1.key, depth + 1)
          try write(pair.1.value, depth + 1)
        }
      case .bool(let b): out.append(b ? 0xf5 : 0xf4)
      }
      guard out.count <= maximumBytes else { throw SessionFailure.malformed }
    }
    for v in values { try write(v, 0) }
    guard out.count == encodedSize else { throw SessionFailure.malformed }
    return out
  }
  static func decode(_ data: Data, maximumBytes: Int = maxBytes, materializeBytes: Bool = true) throws -> SessionCBOR {
    let values = try decodeSequence(data, maximumBytes: maximumBytes, materializeBytes: materializeBytes)
    guard values.count == 1 else { throw SessionFailure.malformed }
    return values[0]
  }
  static func decodeSequence(_ data: Data, maximumBytes: Int = maxBytes, materializeBytes: Bool = true) throws -> [SessionCBOR] {
    guard (1...524416).contains(maximumBytes), data.count <= maximumBytes else { throw SessionFailure.malformed }
    // Index from the buffer's own start so a sliced input needs no re-basing copy.
    let base = data.startIndex
    var offset = 0
    var items = 0
    func byte() throws -> UInt8 {
      guard offset < data.count else { throw SessionFailure.malformed }
      defer { offset += 1 }
      return data[base + offset]
    }
    func length(_ extra: UInt8) throws -> UInt64 {
      if extra < 24 { return UInt64(extra) }
      let width: Int
      switch extra {
      case 24: width = 1
      case 25: width = 2
      case 26: width = 4
      case 27: width = 8
      default: throw SessionFailure.malformed
      }
      var n: UInt64 = 0
      for _ in 0..<width { n = (n << 8) | UInt64(try byte()) }
      let floor: UInt64 = width == 1 ? 24 : width == 2 ? 256 : width == 4 ? 65536 : 0x1_0000_0000
      guard n >= floor, n <= UInt64(Int64.max) else { throw SessionFailure.malformed }
      return n
    }
    func read(_ depth: Int) throws -> SessionCBOR {
      items += 1
      guard depth <= maxDepth, items <= maxItems else { throw SessionFailure.malformed }
      let first = try byte()
      let major = first >> 5
      let extra = first & 31
      if major == 7 {
        switch extra {
        case 20: return .bool(false)
        case 21: return .bool(true)
        default: throw SessionFailure.malformed
        }
      }
      let n = try length(extra)
      switch major {
      case 0: return .integer(Int64(n))
      case 1: return .integer(-1 - Int64(n))
      case 2, 3:
        guard n <= maximumBytes, n <= data.count - offset else { throw SessionFailure.malformed }
        let start = offset
        offset += Int(n)
        // Control classification retains structural validation without copying file payloads.
        if major == 2 && !materializeBytes { return .bytes(Data()) }
        let bytes = data.subdata(in: (base + start)..<(base + offset))
        if major == 2 { return .bytes(bytes) }
        guard let text = String(data: bytes, encoding: .utf8) else {
          throw SessionFailure.malformed
        }
        return .text(text)
      case 4:
        guard n <= maxItems else { throw SessionFailure.malformed }
        return .array(try (0..<Int(n)).map { _ in try read(depth + 1) })
      case 5:
        guard n <= maxItems / 2 else { throw SessionFailure.malformed }
        var previous: Data?
        var pairs: [SessionCBOR.Entry] = []
        for _ in 0..<Int(n) {
          let start = offset
          let key = try read(depth + 1)
          switch key {
          case .array, .map: throw SessionFailure.malformed
          default: break
          }
          let encoded = data.subdata(in: (base + start)..<(base + offset))
          if let previous { guard less(previous, encoded) else { throw SessionFailure.malformed } }
          previous = encoded
          pairs.append(.init(key, try read(depth + 1)))
        }
        return .map(pairs)
      default: throw SessionFailure.malformed
      }
    }
    var values: [SessionCBOR] = []
    while offset < data.count { values.append(try read(0)) }
    return values
  }
  private static func less(_ a: Data, _ b: Data) -> Bool {
    a.count != b.count ? a.count < b.count : a.lexicographicallyPrecedes(b)
  }
}
