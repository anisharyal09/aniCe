// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies Android signatures and produces an isolated Mac Keychain signature bundle.
import CryptoKit
import Foundation
import Security

/// Command line utility for cross-platform signature interchange verification.
///
/// Usage: identity-interchange <input-android-json> <output-macos-json>
/// 1. Reads and verifies Android Keystore signature from input JSON.
/// 2. Creates an isolated temporary macOS identity in development Keychain.
/// 3. Signs a test message and writes public identity, message, and signature to output JSON.

struct TestBundle: Codable {
    let identity: DeviceIdentity
    let messageBase64: String
    let signatureBase64: String
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    fputs("Usage: identity-interchange <android-bundle-in> <mac-bundle-out>\n", stderr)
    exit(1)
}

let inputPath = URL(fileURLWithPath: arguments[1])
let outputPath = URL(fileURLWithPath: arguments[2])

do {
    // 1. Verify Android Keystore signature
    let inputData = try Data(contentsOf: inputPath)
    guard let object = try JSONSerialization.jsonObject(with: inputData) as? [String: Any],
          Set(object.keys) == Set(["identity", "messageBase64", "signatureBase64"]),
          let publicRecord = object["identity"] else { throw IdentityError.invalidPublicIdentity }
    _ = try DeviceIdentity.decode(JSONSerialization.data(withJSONObject: publicRecord))
    let androidBundle = try JSONDecoder().decode(TestBundle.self, from: inputData)
    try androidBundle.identity.validate()

    guard let messageData = Data(base64Encoded: androidBundle.messageBase64),
          let signatureData = Data(base64Encoded: androidBundle.signatureBase64),
          messageData.base64EncodedString() == androidBundle.messageBase64,
          signatureData.base64EncodedString() == androidBundle.signatureBase64,
          androidBundle.identity.platform == "android" else {
        fputs("Error: Android bundle has invalid Base64 data\n", stderr)
        exit(1)
    }

    guard androidBundle.identity.verify(message: messageData, signature: signatureData) else {
        fputs("Error: Android Keystore signature verification failed on macOS\n", stderr)
        exit(2)
    }
    guard !androidBundle.identity.verify(message: messageData + Data([0]), signature: signatureData),
          !androidBundle.identity.verify(message: messageData, signature: Data([0])) else {
        throw IdentityError.invalidPublicIdentity
    }
    print("Verified Android signature; altered message and malformed signature rejected.")

    // 2. Generate an isolated test macOS identity and sign test message
    let testNamespace = "io.github.anisharyal09.anice.interchange.test." + UUID().uuidString.lowercased()
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let storage = MacIdentityStorage(
        namespace: testNamespace,
        backend: .developmentKeychain,
        recordURL: tempDir.appendingPathComponent("test-identity.json")
    )
    defer {
        if let tags = try? storage.keyTags() {
            for tag in tags { try? storage.deleteKey(tag: tag) }
        }
    }
    let service = IdentityService(
        storage: storage,
        deviceName: "Mac Interchange Test",
        tagPrefix: testNamespace + "."
    )

    _ = try await service.loadOrCreate()
    let testMessage = "aniCe Mac-to-Android interchange challenge: \(UUID().uuidString)".data(using: .utf8)!
    let signedPayload = try await service.sign(message: testMessage)

    guard !signedPayload.identity.verify(message: messageData, signature: signatureData) else {
        throw IdentityError.invalidPublicIdentity
    }

    let macBundle = TestBundle(
        identity: signedPayload.identity,
        messageBase64: testMessage.base64EncodedString(),
        signatureBase64: signedPayload.signature.base64EncodedString()
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let outputData = try encoder.encode(macBundle)
    try outputData.write(to: outputPath, options: .atomic)

    // Cleanup failure must fail the test rather than silently report success.
    for tag in try storage.keyTags() { try storage.deleteKey(tag: tag) }
    guard try storage.keyTags().isEmpty else { throw IdentityError.inconsistentStorage }

    print("Successfully generated macOS signature bundle for Android verification.")
} catch {
    fputs("Identity interchange error: \(error.localizedDescription)\n", stderr)
    exit(3)
}
