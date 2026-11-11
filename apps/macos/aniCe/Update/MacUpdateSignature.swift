// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies code integrity, identifier and pinned leaf certificate for update bundles.
import CryptoKit
import Foundation
import Security

enum MacUpdateSignature {
  enum Error: LocalizedError {
    case invalidConfiguration, invalidCode(OSStatus), wrongCertificate

    var errorDescription: String? {
      switch self {
      case .invalidConfiguration:
        return "This build cannot verify update signatures. Install the update manually from the release."
      case .invalidCode:
        return "The downloaded app failed its signature check. Open the release on GitHub to install manually."
      case .wrongCertificate:
        return "The downloaded app was not signed by the aniCe update certificate. Open the release on GitHub to install manually."
      }
    }
  }

  // Do not accept additional slices whose signing identity has not been checked.
  static func validateArchitectures(_ executable: URL) throws {
    let file = try FileHandle(forReadingFrom: executable)
    defer { try? file.close() }
    guard let data = try file.read(upToCount: 72), data.count >= 8 else { throw Error.invalidConfiguration }
    func word(_ offset: Int) -> UInt32 {
      data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }
    let magic = word(0), count = word(4)
    guard (magic == 0xcafebabe || magic == 0xcafebabf), count == 2 else { throw Error.invalidConfiguration }
    let stride = magic == 0xcafebabe ? 20 : 32
    guard data.count >= 8 + 2 * stride else { throw Error.invalidConfiguration }
    let architectures = Set([word(8), word(8 + stride)])
    guard architectures == Set([0x01000007, 0x0100000c]) else { throw Error.invalidConfiguration }
    for offset in [8, 8 + stride] {
      let cpu = word(offset), subtype = word(offset + 4) & 0x00ff_ffff
      guard (cpu == 0x01000007 && subtype == 3) || (cpu == 0x0100000c && subtype == 0) else {
        throw Error.invalidConfiguration
      }
    }
  }

  static func validate(_ url: URL, identifier: String, pins: Set<String>) throws {
    let validCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
    guard !identifier.isEmpty, identifier.unicodeScalars.allSatisfy({ validCharacters.contains($0) }),
      !pins.isEmpty, pins.allSatisfy({ $0.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }) else {
      throw Error.invalidConfiguration
    }
    let executable = Bundle(url: url)?.executableURL ?? url
    try validateArchitectures(executable)
    var requirement: SecRequirement?
    var status = SecRequirementCreateWithString("identifier \"\(identifier)\"" as CFString, [], &requirement)
    guard status == errSecSuccess, let requirement else { throw Error.invalidCode(status) }
    for architecture in ["arm64", "x86_64"] {
      var code: SecStaticCode?
      let attributes = [kSecCodeAttributeArchitecture as String: architecture] as CFDictionary
      status = SecStaticCodeCreateWithPathAndAttributes(url as CFURL, [], attributes, &code)
      guard status == errSecSuccess, let code else { throw Error.invalidCode(status) }
      let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode)
      status = SecStaticCodeCheckValidity(code, flags, requirement)
      guard status == errSecSuccess else { throw Error.invalidCode(status) }
      var raw: CFDictionary?
      status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw)
      guard status == errSecSuccess, let info = raw as? [CFString: Any],
        let certificates = info[kSecCodeInfoCertificates] as? [SecCertificate], let leaf = certificates.first else {
        throw Error.invalidCode(status)
      }
      let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
      guard pins.contains(digest) else { throw Error.wrongCertificate }
    }
  }
}
