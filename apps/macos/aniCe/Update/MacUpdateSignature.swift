// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies code integrity, identifier and pinned leaf certificate for update bundles.
import CryptoKit
import Foundation
import Security

enum MacUpdateSignature {
  enum Error: LocalizedError {
    case invalidConfiguration, invalidArchitecture, invalidCode(OSStatus), wrongCertificate

    var errorDescription: String? {
      switch self {
      case .invalidConfiguration:
        return "This build cannot verify update signatures. Install the update manually from the release."
      case .invalidArchitecture:
        return "The downloaded app is not an arm64 aniCe build. aniCe requires Apple Silicon."
      case .invalidCode:
        return "The downloaded app failed its signature check. Open the release on GitHub to install manually."
      case .wrongCertificate:
        return "The downloaded app was not signed by the aniCe update certificate. Open the release on GitHub to install manually."
      }
    }
  }

  // Official releases contain one native arm64 Mach-O executable, not a fat container.
  static func validateArchitecture(_ executable: URL) throws {
    let file = try FileHandle(forReadingFrom: executable)
    defer { try? file.close() }
    guard let data = try file.read(upToCount: 32), data.count == 32 else { throw Error.invalidArchitecture }
    func word(_ offset: Int) -> UInt32 {
      data[offset..<(offset + 4)].reversed().reduce(0) { ($0 << 8) | UInt32($1) }
    }
    // MH_MAGIC_64, CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64_ALL and MH_EXECUTE.
    guard word(0) == 0xfeedfacf, word(4) == 0x0100000c,
      (word(8) & 0x00ff_ffff) == 0, word(12) == 2 else {
      throw Error.invalidArchitecture
    }
  }

  static func validate(_ url: URL, identifier: String, pins: Set<String>) throws {
    let validCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
    guard !identifier.isEmpty, identifier.unicodeScalars.allSatisfy({ validCharacters.contains($0) }),
      !pins.isEmpty, pins.allSatisfy({ $0.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }) else {
      throw Error.invalidConfiguration
    }
    let executable = Bundle(url: url)?.executableURL ?? url
    try validateArchitecture(executable)
    var requirement: SecRequirement?
    var status = SecRequirementCreateWithString("identifier \"\(identifier)\"" as CFString, [], &requirement)
    guard status == errSecSuccess, let requirement else { throw Error.invalidCode(status) }
    var code: SecStaticCode?
    let attributes = [kSecCodeAttributeArchitecture as String: "arm64"] as CFDictionary
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
