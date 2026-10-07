// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

/// Typed errors encountered during macOS identity storage, verification, or signing operations.
enum IdentityError: Error, LocalizedError, Equatable {
    /// Keychain is locked, system is unready, or storage is inaccessible.
    case storageUnavailable(String)
    /// Signed data protection configuration requires an active developer team and Keychain entitlements.
    case configurationRequired
    /// The user or Keychain policy did not authorize private-key access.
    case accessDenied
    /// An older development key does not satisfy the required non-extractable policy.
    case keyPolicyNeedsReset
    /// Storage state is inconsistent or corrupted (e.g. metadata references a missing key).
    case inconsistentStorage
    /// The private signing key associated with the saved identity cannot be found in Keychain.
    case keyMissing
    /// The public identity payload failed validation against protocol specifications.
    case invalidPublicIdentity
    /// The ECDSA signature is malformed, noncanonical, or does not verify against the public key.
    case invalidSignature

    var errorDescription: String? {
        switch self {
        case .storageUnavailable(let detail): "Identity storage is unavailable. Try again after unlocking your Mac. (\(detail))"
        case .keyPolicyNeedsReset: "This identity uses an older development key with an incorrect export policy. Reset identity to create a non-extractable replacement. Your existing identity has not been replaced."
        case .accessDenied: "Keychain did not authorize access to this identity. Your saved identity has not been replaced. Choose Try again to request access; an ad-hoc rebuild may need authorization again."
        case .configurationRequired: "This build needs a valid signing team and Keychain access entitlement. Configure signing or use the explicit development storage build."
        case .inconsistentStorage: "Your saved identity could not be verified. Try again, or reset the identity to create a new one."
        case .keyMissing: "The signing key for your saved identity is missing. Reset the identity to create a new one."
        case .invalidPublicIdentity: "The device identity is invalid."
        case .invalidSignature: "The signature is invalid."
        }
    }
}

/// Truthful description of the cryptographic key storage and protection mechanism on macOS.
enum KeyProtection: String, Codable, Sendable {
    /// Key generated and isolated inside Apple's physical Secure Enclave processor.
    case secureEnclave
    /// Key stored in standard Apple Data Protection Keychain with device-only accessibility.
    case keychainSoftware
    /// Key stored in the login Keychain for ad-hoc development builds; no hardware/migration guarantee.
    case developmentKeychain

    var label: String {
        switch self {
        case .secureEnclave: "Secure Enclave"
        case .keychainSoftware: "Keychain protected"
        case .developmentKeychain: "Development Keychain"
        }
    }
}

/// The public identity contract of a macOS aniCe installation.
///
/// Shared during authenticated pairing. Discovery exchanges no identity material.
struct DeviceIdentity: Codable, Equatable, Sendable {
    let identitySchemaVersion: Int
    let deviceId: String
    let deviceName: String
    let platform: String
    let algorithm: String
    let publicKey: String
    let fingerprint: String

    init(deviceId: String, deviceName: String, publicKey: Data) throws {
        self.identitySchemaVersion = 1
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.platform = "macos"
        self.algorithm = "ECDSA_P256_SHA256"
        self.publicKey = publicKey.base64EncodedString()
        self.fingerprint = Self.fingerprint(publicKey)
        try validate()
    }

    static func fingerprint(_ publicKey: Data) -> String {
        SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
    }

    static func normalizedName(_ name: String?) -> String {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let result = String(String.UnicodeScalarView(trimmed.unicodeScalars.prefix(64)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "Mac" : result
    }

    static func isCanonicalDeviceID(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
                    options: .regularExpression) != nil
    }

    var groupedFingerprint: String {
        stride(from: 0, to: fingerprint.count, by: 4).map {
            let start = fingerprint.index(fingerprint.startIndex, offsetBy: $0)
            return String(fingerprint[start..<fingerprint.index(start, offsetBy: 4)])
        }.joined(separator: " ")
    }

    func validate() throws {
        guard identitySchemaVersion == 1, algorithm == "ECDSA_P256_SHA256",
              ["macos", "android"].contains(platform),
              Self.isCanonicalDeviceID(deviceId),
              !deviceName.isEmpty, deviceName.unicodeScalars.count <= 64,
              deviceName == deviceName.trimmingCharacters(in: .whitespacesAndNewlines),
              let bytes = Data(base64Encoded: publicKey), bytes.base64EncodedString() == publicKey,
              bytes.count == 65, bytes.first == 4,
              fingerprint == Self.fingerprint(bytes),
              (try? P256.Signing.PublicKey(x963Representation: bytes)) != nil
        else { throw IdentityError.invalidPublicIdentity }
    }

    static func decode(_ data: Data) throws -> DeviceIdentity {
        let required = Set(["identitySchemaVersion", "deviceId", "deviceName", "platform", "algorithm", "publicKey", "fingerprint"])
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == required else { throw IdentityError.invalidPublicIdentity }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }

    func verify(message: Data, signature: Data) -> Bool {
        guard (try? validate()) != nil, let publicBytes = Data(base64Encoded: publicKey),
              let key = try? P256.Signing.PublicKey(x963Representation: publicBytes),
              let parsed = try? P256.Signing.ECDSASignature(derRepresentation: signature),
              parsed.derRepresentation == signature else { return false }
        // CryptoKit hashes the message with SHA-256 exactly once.
        return key.isValidSignature(parsed, for: message)
    }
}

struct LocalIdentity: Equatable, Sendable {
    let identity: DeviceIdentity
    let protection: KeyProtection
    let cleanupPending: Bool
}

struct SignedIdentityPayload: Sendable {
    let identity: DeviceIdentity
    let signature: Data
}
