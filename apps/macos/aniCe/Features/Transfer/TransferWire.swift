// SPDX-License-Identifier: GPL-3.0-or-later
// Validates bounded transfer messages separately from authenticated session readiness and control records.
import Foundation

enum TransferWireError: Error { case malformed, unsupported }

struct TransferMessage: Equatable, Sendable {
  let kind: Int64
  let fields: [SessionCBOR]

  func encode(maximumChunkBytes: Int = 3072) throws -> Data {
    try validate(maximumChunkBytes: maximumChunkBytes)
    let bytes = try SessionCbor.encode(.array([.text("aniCe transfer"), .integer(1), .integer(kind), .array(fields)]), maximumBytes: maximumChunkBytes > 3072 ? 262144 : 4096)
    guard bytes.count <= (maximumChunkBytes > 3072 ? 262144 : 4000) else { throw TransferWireError.malformed }
    return bytes
  }

  static func decode(_ bytes: Data, maximumChunkBytes: Int = 3072) throws -> Self? {
    guard bytes.count <= (maximumChunkBytes > 3072 ? 262144 : 4000) else { throw TransferWireError.malformed }
    guard case .array(let row) = try SessionCbor.decode(bytes, maximumBytes: maximumChunkBytes > 3072 ? 262144 : 4096), row.first == .text("aniCe transfer") else { return nil }
    guard row.count == 4, case .integer(let version) = row[1] else { throw TransferWireError.malformed }
    guard version == 1 else { throw TransferWireError.unsupported }
    guard case .integer(let kind) = row[2], case .array(let fields) = row[3] else { throw TransferWireError.malformed }
    let message = Self(kind: kind, fields: fields)
    try message.validate(maximumChunkBytes: maximumChunkBytes)
    return message
  }

  func validate(maximumChunkBytes: Int = 3072) throws {
    guard (1...131072).contains(maximumChunkBytes) else { throw TransferWireError.malformed }
    func require(_ value: Bool) throws { if !value { throw TransferWireError.malformed } }
    func integer(_ i: Int, _ range: ClosedRange<Int64>) -> Bool {
      guard fields.indices.contains(i), case .integer(let n) = fields[i] else { return false }
      return range.contains(n)
    }
    func text(_ i: Int, _ count: Int, uuid: Bool = false, empty: Bool = false) -> Bool {
      guard fields.indices.contains(i), case .text(let s) = fields[i], s.utf8.count <= count, !s.contains("\0") else { return false }
      if uuid {
        if empty && s.isEmpty { return true }
        return s.utf8.count == 36 && UUID(uuidString: s) != nil
      }
      return !s.isEmpty || empty
    }
    func filename(_ i: Int) -> Bool {
      guard fields.indices.contains(i), case .text(let s) = fields[i] else { return false }
      let count = s.utf8.count
      guard (1...255).contains(count), !s.contains("/"), !s.contains("\\"), !s.contains("\0") else { return false }
      guard s != "." && s != ".." && !s.contains("../") && !s.contains("..\\") else { return false }
      return s.allSatisfy { $0 >= " " }
    }
    func blob(_ i: Int, _ size: Int) -> Bool {
      guard fields.indices.contains(i), case .bytes(let d) = fields[i] else { return false }
      return d.count == size
    }

    switch kind {
    case 1: // capability: [version, maxChunkBytes, maxWindow]
      try require(fields.count == 3 && (integer(0, 1...1) && integer(1, 1...3072) && integer(2, 1...64) ||
        maximumChunkBytes > 3072 && integer(0, 2...2) && integer(1, 1...Int64(maximumChunkBytes)) && integer(2, 1...8)))
    case 2: // offer: [batch, sliceIndex, totalSlices, totalFiles, totalBytes, files]
      try require(fields.count == 6 && text(0, 36, uuid: true) && integer(1, 0...15)
        && integer(2, 1...16) && integer(3, 1...128) && integer(4, 0...Int64.max))
      try require(number(1) < number(2))
      guard case .array(let files) = fields[5], !files.isEmpty, files.count <= 8 else { throw TransferWireError.malformed }
      var fileIds = Set<String>()
      for f in files {
        guard case .array(let row) = f, row.count == 4,
          case .text(let id) = row[0], id.utf8.count == 36, UUID(uuidString: id) != nil, fileIds.insert(id).inserted,
          case .text(let name) = row[1], (1...255).contains(name.utf8.count), !name.contains("/"), !name.contains("\\"), !name.contains("\0"),
          name != ".", name != "..", !name.contains("../"), !name.contains("..\\"), name.allSatisfy({ $0 >= " " }),
          case .integer(let sz) = row[2], sz >= 0,
          case .bytes(let hash) = row[3], hash.count == 32 else { throw TransferWireError.malformed }
      }
    case 3: // accept: [batch, acceptedFiles]
      try require(fields.count == 2 && text(0, 36, uuid: true))
      guard case .array(let files) = fields[1], files.count <= 64 else { throw TransferWireError.malformed }
      for f in files {
        guard case .text(let id) = f, id.utf8.count == 36, UUID(uuidString: id) != nil else { throw TransferWireError.malformed }
      }
    case 4: // reject: [batch, reason]
      try require(fields.count == 2 && text(0, 36, uuid: true) && integer(1, 0...4))
    case 5: // chunk: [batch, file, offset, data]
      try require(fields.count == 4 && text(0, 36, uuid: true) && text(1, 36, uuid: true) && integer(2, 0...Int64.max))
      guard case .bytes(let data) = fields[3], !data.isEmpty, data.count <= maximumChunkBytes else { throw TransferWireError.malformed }
    case 6: // ack: [batch, file, written]
      try require(fields.count == 3 && text(0, 36, uuid: true) && text(1, 36, uuid: true) && integer(2, 0...Int64.max))
    case 7: // file-result: [batch, file, result, hash]
      try require(fields.count == 4 && text(0, 36, uuid: true) && text(1, 36, uuid: true) && integer(2, 0...3) && blob(3, 32))
    case 8: // batch-result: [batch, result]
      try require(fields.count == 2 && text(0, 36, uuid: true) && integer(1, 0...3))
    case 9: // cancel: [batch, file, reason]
      try require(fields.count == 3 && text(0, 36, uuid: true) && text(1, 36, uuid: true, empty: true) && integer(2, 0...4))
    case 10: // resume: [batch, file, offset, prefixHash]
      try require(fields.count == 4 && text(0, 36, uuid: true) && text(1, 36, uuid: true) && integer(2, 0...Int64.max) && blob(3, 32))
    case 11: // status: [batch, file, bytesTransferred, state]
      try require(fields.count == 4 && text(0, 36, uuid: true) && text(1, 36, uuid: true, empty: true) && integer(2, 0...Int64.max) && integer(3, 0...4))
    default:
      throw TransferWireError.unsupported
    }
  }

  func string(_ i: Int) -> String { if fields.indices.contains(i), case .text(let v) = fields[i] { return v }; return "" }
  func number(_ i: Int) -> Int64 { if fields.indices.contains(i), case .integer(let v) = fields[i] { return v }; return 0 }
  func bytes(_ i: Int) -> Data { if fields.indices.contains(i), case .bytes(let v) = fields[i] { return v }; return Data() }

  static func capability(version: Int64 = 1, maxChunkBytes: Int64 = 3072, maxWindow: Int64 = 64) -> TransferMessage {
    TransferMessage(kind: 1, fields: [.integer(version), .integer(maxChunkBytes), .integer(maxWindow)])
  }
  static func offer(batch: String, sliceIndex: Int64, totalSlices: Int64, totalFiles: Int64, totalBytes: Int64, files: [SessionCBOR]) -> TransferMessage {
    TransferMessage(kind: 2, fields: [.text(batch), .integer(sliceIndex), .integer(totalSlices), .integer(totalFiles), .integer(totalBytes), .array(files)])
  }
  static func accept(batch: String, files: [String] = []) -> TransferMessage {
    TransferMessage(kind: 3, fields: [.text(batch), .array(files.map { .text($0) })])
  }
  static func reject(batch: String, reason: Int64) -> TransferMessage {
    TransferMessage(kind: 4, fields: [.text(batch), .integer(reason)])
  }
  static func chunk(batch: String, file: String, offset: Int64, data: Data) -> TransferMessage {
    TransferMessage(kind: 5, fields: [.text(batch), .text(file), .integer(offset), .bytes(data)])
  }
  static func ack(batch: String, file: String, written: Int64) -> TransferMessage {
    TransferMessage(kind: 6, fields: [.text(batch), .text(file), .integer(written)])
  }
  static func fileResult(batch: String, file: String, result: Int64, hash: Data) -> TransferMessage {
    TransferMessage(kind: 7, fields: [.text(batch), .text(file), .integer(result), .bytes(hash)])
  }
  static func batchResult(batch: String, result: Int64) -> TransferMessage {
    TransferMessage(kind: 8, fields: [.text(batch), .integer(result)])
  }
  static func cancel(batch: String, file: String = "", reason: Int64 = 0) -> TransferMessage {
    TransferMessage(kind: 9, fields: [.text(batch), .text(file), .integer(reason)])
  }
  static func resume(batch: String, file: String, offset: Int64, prefixHash: Data) -> TransferMessage {
    TransferMessage(kind: 10, fields: [.text(batch), .text(file), .integer(offset), .bytes(prefixHash)])
  }
  static func status(batch: String, file: String = "", bytesTransferred: Int64, state: Int64) -> TransferMessage {
    TransferMessage(kind: 11, fields: [.text(batch), .text(file), .integer(bytesTransferred), .integer(state)])
  }
}

