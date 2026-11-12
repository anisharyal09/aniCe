// SPDX-License-Identifier: GPL-3.0-or-later
// Rejects unsafe ZIP layouts before ditto extracts an update into private staging.
import Foundation

enum MacUpdateArchive {
  enum Error: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
      "The downloaded update is not a valid aniCe archive. Open the release on GitHub to install manually."
    }
  }
  private static let maximumEntries = 20_000
  private static let maximumExpanded: UInt64 = 1_073_741_824

  static func validate(_ url: URL) throws {
    let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
    func fail(_ message: String) -> Error { .invalid(message) }
    guard bytes.count >= 22, bytes.count <= Int(MacReleaseCatalog.maxBytes) else { throw fail("Invalid ZIP size") }
    func word(_ offset: Int) throws -> UInt16 {
      guard offset >= 0, offset <= bytes.count - 2 else { throw fail("Truncated ZIP") }
      return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }
    func dword(_ offset: Int) throws -> UInt32 { UInt32(try word(offset)) | UInt32(try word(offset + 2)) << 16 }
    func checkExtra(_ start: Int, _ length: Int) throws {
      guard start >= 0, length >= 0, start <= bytes.count, length <= bytes.count - start else { throw fail("Invalid ZIP extra data") }
      var offset = start
      while offset < start + length {
        guard offset <= start + length - 4 else { throw fail("Invalid ZIP extra data") }
        let id = try word(offset), size = Int(try word(offset + 2))
        guard size <= start + length - offset - 4, id == 0x5855, size == 8 || size == 12 else { throw fail("Unsupported ZIP extra data") }
        offset += 4 + size
      }
    }
    guard try dword(0) == 0x04034b50 else { throw fail("Invalid ZIP header") }
    let lowerBound = max(0, bytes.count - 65_557)
    var end: Int?
    for offset in stride(from: bytes.count - 22, through: lowerBound, by: -1) {
      if try dword(offset) == 0x06054b50, offset + 22 + Int(try word(offset + 20)) == bytes.count { end = offset; break }
    }
    guard let end, try word(end + 4) == 0, try word(end + 6) == 0,
      try word(end + 8) == word(end + 10) else { throw fail("Unsupported ZIP directory") }
    let count = Int(try word(end + 10)), directorySize = Int(try dword(end + 12)), directoryOffset = Int(try dword(end + 16))
    guard count > 0, count <= maximumEntries, directoryOffset <= end,
      directorySize <= end - directoryOffset, directoryOffset + directorySize == end else { throw fail("Invalid ZIP directory") }
    var cursor = directoryOffset, expanded: UInt64 = 0
    var names = Set<String>(), links: [String: String] = [:], ranges: [Range<Int>] = []
    for _ in 0..<count {
      guard cursor <= end - 46, try dword(cursor) == 0x02014b50 else { throw fail("Invalid ZIP entry") }
      let flags = try word(cursor + 8), method = try word(cursor + 10)
      let compressed = Int(try dword(cursor + 20)), unpacked = UInt64(try dword(cursor + 24))
      let nameLength = Int(try word(cursor + 28)), extraLength = Int(try word(cursor + 30)), commentLength = Int(try word(cursor + 32))
      let external = try dword(cursor + 38), local = Int(try dword(cursor + 42))
      let entryLength = 46 + nameLength + extraLength + commentLength
      guard flags & 1 == 0, compressed != Int(UInt32.max), unpacked != UInt64(UInt32.max),
        local != Int(UInt32.max), entryLength <= end - cursor else { throw fail("Unsupported ZIP entry") }
      expanded += unpacked
      guard expanded <= maximumExpanded else { throw fail("ZIP expands beyond limit") }
      try checkExtra(cursor + 46 + nameLength, extraLength)
      let nameData = bytes[(cursor + 46)..<(cursor + 46 + nameLength)]
      guard let name = String(data: nameData, encoding: .utf8), !name.isEmpty,
        !name.hasPrefix("/"), !name.contains("\\"), !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw fail("Invalid ZIP path") }
      let trimmed = name.hasSuffix("/") ? String(name.dropLast()) : name
      let components = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
      guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
        components[0] == "aniCe.app" || (components.count > 1 && components[0] == "__MACOSX" && components[1] == "aniCe.app"),
        names.insert(trimmed).inserted else { throw fail("Unsafe or duplicate ZIP path") }
      guard local <= directoryOffset - 30, try dword(local) == 0x04034b50,
        try word(local + 6) == flags, try word(local + 8) == method else { throw fail("Invalid local ZIP entry") }
      let localNameLength = Int(try word(local + 26)), localExtraLength = Int(try word(local + 28))
      let start = local + 30 + localNameLength + localExtraLength
      guard start <= directoryOffset, compressed <= directoryOffset - start,
        localNameLength == nameLength, bytes[(local + 30)..<(local + 30 + localNameLength)].elementsEqual(nameData) else { throw fail("Inconsistent ZIP entry") }
      try checkExtra(local + 30 + localNameLength, localExtraLength)
      ranges.append(local..<(start + compressed))
      let kind = (external >> 16) & 0o170000
      guard kind == 0 || kind == 0o100000 || kind == 0o040000 || kind == 0o120000 else { throw fail("Unsupported ZIP file type") }
      if kind == 0o120000 {
        guard components[0] == "aniCe.app", method == 0, compressed == Int(unpacked), compressed <= 4096,
          let target = String(data: bytes[start..<(start + compressed)], encoding: .utf8),
          !target.isEmpty, !target.hasPrefix("/"), !target.contains("\\"),
          !target.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw fail("Invalid ZIP symlink") }
        var resolved = Array(components.dropLast())
        for part in target.split(separator: "/", omittingEmptySubsequences: false) {
          if part.isEmpty || part == "." { continue }
          if part == ".." { guard resolved.count > 1 else { throw fail("Escaping ZIP symlink") }; resolved.removeLast() }
          else { resolved.append(String(part)) }
        }
        guard resolved.first == "aniCe.app" else { throw fail("Escaping ZIP symlink") }
        links[trimmed] = target
      }
      cursor += entryLength
    }
    guard cursor == end else { throw fail("Invalid ZIP directory size") }
    let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
    for index in 1..<sorted.count where sorted[index - 1].upperBound > sorted[index].lowerBound { throw fail("Overlapping ZIP entries") }
    // Resolve symlink chains too: a lexically internal target can escape through another link.
    for (path, target) in links {
      var pending = Array(path.split(separator: "/").dropLast()).map(String.init) + target.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
      var resolved: [String] = [], traversals = 0
      while !pending.isEmpty {
        let part = pending.removeFirst()
        if part.isEmpty || part == "." { continue }
        if part == ".." { guard resolved.count > 1 else { throw fail("Escaping ZIP symlink chain") }; resolved.removeLast(); continue }
        resolved.append(part)
        guard resolved.first == "aniCe.app" else { throw fail("Escaping ZIP symlink chain") }
        if let next = links[resolved.joined(separator: "/")] {
          traversals += 1; guard traversals <= 40 else { throw fail("Cyclic ZIP symlink") }
          resolved.removeLast()
          pending = next.split(separator: "/", omittingEmptySubsequences: false).map(String.init) + pending
        }
      }
    }
    for path in names {
      var parts = path.split(separator: "/").map(String.init)
      while parts.count > 1 { parts.removeLast(); if links[parts.joined(separator: "/")] != nil { throw fail("ZIP entry below symlink") } }
    }
  }
}
