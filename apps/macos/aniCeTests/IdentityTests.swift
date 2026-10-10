// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies protected identity boundaries and durable recovery with isolated key and storage faults.
import CryptoKit
import Foundation
import Security
import XCTest
@testable import aniCe

final class IdentityTests: XCTestCase, @unchecked Sendable {
    func testSharedVectors() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "identity-vectors", withExtension: "json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let valid = try XCTUnwrap(root["valid"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(valid.count, 2)
        for vector in valid {
            let object = try XCTUnwrap(vector["identity"])
            let identity = try DeviceIdentity.decode(JSONSerialization.data(withJSONObject: object))
            let message = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(vector["messageBase64"] as? String)))
            let signature = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(vector["signatureBase64"] as? String)))
            XCTAssertTrue(identity.verify(message: message, signature: signature), String(describing: vector["name"]))
            let scalar = try hex(try XCTUnwrap(vector["privateScalarHex"] as? String))
            let key = try P256.Signing.PrivateKey(rawRepresentation: scalar)
            XCTAssertEqual(key.publicKey.x963Representation.base64EncodedString(), identity.publicKey)
            XCTAssertEqual(DeviceIdentity.fingerprint(key.publicKey.x963Representation), identity.fingerprint)
            XCTAssertTrue(identity.verify(message: message, signature: try key.signature(for: message).derRepresentation))
        }
        let invalidIdentities = try XCTUnwrap(root["invalidIdentities"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(invalidIdentities.count, 21, "Fixture inventory was reduced")
        for vector in invalidIdentities {
            XCTAssertThrowsError(try DeviceIdentity.decode(JSONSerialization.data(withJSONObject: try XCTUnwrap(vector["identity"]))),
                                 String(describing: vector["name"]))
        }
        let invalidSignatures = try XCTUnwrap(root["invalidSignatures"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(invalidSignatures.count, 12, "Fixture inventory was reduced")
        for vector in invalidSignatures {
            let identity = try DeviceIdentity.decode(JSONSerialization.data(withJSONObject: try XCTUnwrap(vector["identity"])))
            let message = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(vector["messageBase64"] as? String)))
            let signature = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(vector["signatureBase64"] as? String)))
            XCTAssertFalse(identity.verify(message: message, signature: signature), String(describing: vector["name"]))
        }
    }

    func testNameUsesUnicodeScalarsAndTrimsAfterTruncation() {
        XCTAssertEqual(DeviceIdentity.normalizedName("   \n"), "Mac")
        XCTAssertEqual(DeviceIdentity.normalizedName(String(repeating: "a", count: 63) + "  xyz"), String(repeating: "a", count: 63))
        XCTAssertEqual(DeviceIdentity.normalizedName(String(repeating: "😀", count: 100)).unicodeScalars.count, 64)
    }

    func testPersistenceConcurrencyAndSigningSnapshot() async throws {
        let storage = MemoryIdentityStorage()
        let service = service(storage)
        let identities = try await withThrowingTaskGroup(of: LocalIdentity.self) { group in
            for _ in 0..<20 { group.addTask { try await service.loadOrCreate() } }
            var result: [LocalIdentity] = []
            for try await identity in group { result.append(identity) }
            return result
        }
        XCTAssertEqual(Set(identities.map { $0.identity.deviceId }).count, 1)
        XCTAssertEqual(storage.keys.count, 1)
        let reloaded = try await self.service(storage).loadOrCreate()
        XCTAssertEqual(reloaded.identity, identities[0].identity)
        let message = Data("signed before reset".utf8)
        let signed = try await service.sign(message: message)
        let replacement = try await service.reset()
        XCTAssertNotEqual(replacement.identity.deviceId, signed.identity.deviceId)
        XCTAssertTrue(signed.identity.verify(message: message, signature: signed.signature))
        XCTAssertFalse(replacement.identity.verify(message: message, signature: signed.signature))
        XCTAssertEqual(storage.keys.count, 1)
    }

    func testResetInvalidatesAccessBeforeStorageFailureAndPreservesIdentity() async throws {
        let storage = MemoryIdentityStorage(), invalidated = expectation(description: "Reset invalidates access")
        invalidated.assertForOverFulfill = true
        let identity = service(storage)
        let original = try await identity.loadOrCreate()
        let token = NotificationCenter.default.addObserver(forName: IdentityService.invalidated,
            object: identity, queue: nil) { _ in invalidated.fulfill() }
        defer { NotificationCenter.default.removeObserver(token) }
        storage.configureFailure(operation: 1, after: false)
        do { _ = try await identity.reset(); XCTFail("Storage failure was ignored") }
        catch let error as IdentityError { XCTAssertEqual(error, .storageUnavailable("injected")) }
        await fulfillment(of: [invalidated], timeout: 1)
        XCTAssertTrue(storage.failureTriggered)
        XCTAssertEqual(storage.record?.active?.identity, original.identity)
        storage.clearFailure()
        let restored = try await identity.loadOrCreate()
        XCTAssertEqual(restored.identity, original.identity)
        XCTAssertEqual(storage.keys.count, 1)
    }

    func testTransientReadFailureAndMissingKeyDoNotRegenerate() async throws {
        let storage = MemoryIdentityStorage()
        let original = try await service(storage).loadOrCreate()
        storage.configureFailure(operation: 1, after: false)
        do { _ = try await service(storage).loadOrCreate(); XCTFail("Expected storage failure") } catch {}
        XCTAssertEqual(storage.record?.active?.identity, original.identity)
        storage.clearFailure()
        storage.keys.removeAll()
        do { _ = try await service(storage).loadOrCreate(); XCTFail("Expected missing key") }
        catch { XCTAssertEqual(error as? IdentityError, .keyMissing) }
        XCTAssertEqual(storage.record?.active?.identity, original.identity)
        XCTAssertTrue(storage.keys.isEmpty)
        let replacement = try await service(storage).reset()
        XCTAssertNotEqual(replacement.identity, original.identity)
    }

    func testInitialCreationRecoversEveryInterruptedOperation() async throws {
        let baseline = MemoryIdentityStorage()
        _ = try await service(baseline).loadOrCreate()
        let boundaries = baseline.operationCount
        XCTAssertGreaterThan(boundaries, 0)
        for after in [false, true] {
            for index in 1...boundaries {
                let storage = MemoryIdentityStorage()
                storage.configureFailure(operation: index, after: after)
                do { _ = try await service(storage).loadOrCreate() } catch {}
                XCTAssertTrue(storage.failureTriggered, "Fault boundary was not exercised: \(index)")
                let durableID = storage.record?.active?.identity.deviceId ?? storage.record?.pending?.deviceId
                storage.clearFailure()
                let recovered = try await service(storage).loadOrCreate()
                if let durableID { XCTAssertEqual(recovered.identity.deviceId, durableID, "operation \(index), after \(after)") }
                XCTAssertEqual(storage.keys.count, 1)
            }
        }
    }

    func testResetRecoversEveryInterruptedOperation() async throws {
        let baseline = MemoryIdentityStorage()
        _ = try await service(baseline).loadOrCreate()
        baseline.clearFailure()
        _ = try await service(baseline).reset()
        let boundaries = baseline.operationCount
        XCTAssertGreaterThan(boundaries, 0)
        for after in [false, true] {
            for index in 1...boundaries {
                let storage = MemoryIdentityStorage()
                let original = try await service(storage).loadOrCreate()
                storage.configureFailure(operation: index, after: after)
                do { _ = try await service(storage).reset() } catch {}
                XCTAssertTrue(storage.failureTriggered, "Fault boundary was not exercised: \(index)")
                let committed = try XCTUnwrap(storage.record?.active?.identity)
                storage.clearFailure()
                let recovered = try await service(storage).loadOrCreate()
                XCTAssertEqual(recovered.identity, committed, "operation \(index), after \(after)")
                XCTAssertEqual(storage.keys.count, 1)
                XCTAssertNil(storage.record?.pending)
                if committed != original.identity { XCTAssertNotEqual(committed.publicKey, original.identity.publicKey) }
            }
        }
    }

    func testReplacementCannotCommitWithoutSigningSelfCheck() async throws {
        let storage = MemoryIdentityStorage()
        let original = try await service(storage).loadOrCreate()
        storage.corruptSignatures = true
        do { _ = try await service(storage).reset(); XCTFail("Expected signing failure") }
        catch { XCTAssertEqual(error as? IdentityError, .inconsistentStorage) }
        XCTAssertEqual(storage.record?.active?.identity, original.identity)
        storage.corruptSignatures = false
        let recovered = try await service(storage).loadOrCreate()
        XCTAssertEqual(recovered.identity, original.identity)
        XCTAssertEqual(storage.keys.count, 1)
    }

    func testForeignRetiredTagAndOrphanKeysAreRejected() async throws {
        let storage = MemoryIdentityStorage()
        _ = try await service(storage).loadOrCreate()
        storage.record?.retired = ["unrelated.personal.key"]
        do { _ = try await service(storage).loadOrCreate(); XCTFail("Expected invalid record") }
        catch { XCTAssertEqual(error as? IdentityError, .inconsistentStorage) }
        XCTAssertEqual(storage.keys.count, 1)
        storage.record = nil
        do { _ = try await service(storage).loadOrCreate(); XCTFail("Expected orphan detection") }
        catch { XCTAssertEqual(error as? IdentityError, .inconsistentStorage) }
        XCTAssertEqual(storage.keys.count, 1)
    }

    func testIsolatedDevelopmentKeychainIntegration() async throws {
        // Run only explicitly; this never queries the production namespace.
        guard ProcessInfo.processInfo.environment["ANICE_RUN_KEYCHAIN_TESTS"] == "1" else {
            throw XCTSkip("Enable ANICE_RUN_KEYCHAIN_TESTS=1 for isolated login Keychain integration.")
        }
        let namespace = "io.github.anisharyal09.anice.tests." + UUID().uuidString.lowercased()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(namespace)
        let storage = MacIdentityStorage(namespace: namespace, backend: .developmentKeychain,
                                         recordURL: directory.appendingPathComponent("record.json"))
        defer {
            if let tags = try? storage.keyTags() { for tag in tags { try? storage.deleteKey(tag: tag) } }
            try? FileManager.default.removeItem(at: directory)
        }
        let initialService = IdentityService(storage: storage, deviceName: "Identity test", tagPrefix: namespace + ".")
        let initial = try await initialService.loadOrCreate()
        XCTAssertEqual(initial.protection, .developmentKeychain)
        let restarted = IdentityService(storage: storage, deviceName: "Identity test", tagPrefix: namespace + ".")
        let read = try await restarted.loadOrCreate()
        XCTAssertEqual(read.identity, initial.identity)
        let signed = try await restarted.sign(message: Data("test".utf8))
        XCTAssertTrue(initial.identity.verify(message: Data("test".utf8), signature: signed.signature))
        let replacement = try await restarted.reset()
        XCTAssertNotEqual(replacement.identity, initial.identity)
        XCTAssertEqual(try storage.keyTags().count, 1)
    }

    func testDevelopmentRejectsOldExportPolicyWithoutDeletingKey() throws {
        guard ProcessInfo.processInfo.environment["ANICE_RUN_KEYCHAIN_TESTS"] == "1" else {
            throw XCTSkip("Enable isolated Keychain tests explicitly")
        }
        let namespace = "io.github.anisharyal09.anice.identity.policy.test." + UUID().uuidString.lowercased()
        let tag = namespace + "." + UUID().uuidString.lowercased()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = MacIdentityStorage(namespace: namespace, backend: .developmentKeychain,
                                         recordURL: directory.appendingPathComponent("test-identity.json"))
        defer { try? storage.deleteKey(tag: tag) }
        var keychain: SecKeychain?
        XCTAssertEqual(SecKeychainCopyDefault(&keychain), errSecSuccess)
        let login = try XCTUnwrap(keychain)
        // Reproduce the earlier nested-only flag. No private bytes are exported.
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecUseDataProtectionKeychain as String: false,
            kSecUseKeychain as String: login,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: Data(tag.utf8),
                kSecAttrLabel as String: namespace,
                kSecAttrIsExtractable as String: false,
            ],
        ]
        var error: Unmanaged<CFError>?
        XCTAssertNotNil(SecKeyCreateRandomKey(attributes as CFDictionary, &error))
        XCTAssertThrowsError(try storage.key(tag: tag)) {
            XCTAssertEqual($0 as? IdentityError, .keyPolicyNeedsReset)
        }
        XCTAssertEqual(try storage.keyTags(), [tag], "Policy failure must preserve the old key")
        XCTAssertNil(try storage.loadRecord(), "Policy inspection must not create or replace identity metadata")
    }

    func testExistingIdentityUsesOnlyOnePrivateKeyOperationPerRequest() async throws {
        let storage = MemoryIdentityStorage()
        let identityService = service(storage)
        let original = try await identityService.loadOrCreate()
        XCTAssertEqual(storage.signingCount, 1, "Creation checks the key before commit only")
        _ = try await identityService.loadOrCreate()
        XCTAssertEqual(storage.signingCount, 1, "Public reload must not request private-key signing")
        let message = Data("Requested operation".utf8)
        let signed = try await identityService.sign(message: message)
        XCTAssertEqual(storage.signingCount, 2, "Signing must not also perform a preliminary signature")
        XCTAssertTrue(original.identity.verify(message: message, signature: signed.signature))
        _ = try await identityService.reset()
        XCTAssertEqual(storage.signingCount, 3, "Reset checks its replacement before commit only")
    }

    func testPublicReloadDoesNotSignAndActualDenialPreservesIdentity() async throws {
        let storage = MemoryIdentityStorage()
        let initial = try await service(storage).loadOrCreate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let journal = try encoder.encode(storage.record)
        let tags = Set(storage.keys.keys)
        storage.denySigning = true
        let restarted = service(storage)
        for _ in 0..<3 {
            let loaded = try await restarted.loadOrCreate()
            XCTAssertEqual(loaded.identity, initial.identity)
        }
        XCTAssertEqual(storage.signingCount, 1, "Reload is public-key validation, not a signing probe")
        do {
            _ = try await restarted.sign(message: Data("request".utf8))
            XCTFail("Signing denial must propagate")
        } catch let error as IdentityError { XCTAssertEqual(error, .accessDenied) }
        XCTAssertEqual(try encoder.encode(storage.record), journal)
        XCTAssertEqual(Set(storage.keys.keys), tags)
        storage.denySigning = false
        storage.corruptSignatures = true
        do {
            _ = try await restarted.sign(message: Data("request".utf8))
            XCTFail("A malformed signature must not be returned")
        } catch let error as IdentityError { XCTAssertEqual(error, .inconsistentStorage) }
        XCTAssertEqual(try encoder.encode(storage.record), journal)
        XCTAssertEqual(Set(storage.keys.keys), tags)
        storage.corruptSignatures = false
        let recovered = try await restarted.sign(message: Data("request".utf8))
        XCTAssertTrue(initial.identity.verify(message: Data("request".utf8), signature: recovered.signature))
    }

    @MainActor
    func testOpeningDetailsDoesNotReloadUntilExplicitRetry() async throws {
        let storage = MemoryIdentityStorage()
        let model = IdentityViewModel(service: service(storage))
        await model.load()
        let original = try XCTUnwrap(model.local?.identity)
        storage.configureFailure(operation: 1, after: false)
        await model.load()
        XCTAssertEqual(model.local?.identity, original)
        XCTAssertNil(model.recovery)
        await model.load(force: true)
        XCTAssertNil(model.local)
        XCTAssertNotNil(model.recovery)
        XCTAssertFalse(model.canReset)
        storage.clearFailure()
        await model.load(force: true)
        XCTAssertEqual(model.local?.identity, original)
    }

    @MainActor
    func testFailedAutomaticLoadRequiresExplicitRetry() async {
        let storage = MemoryIdentityStorage()
        storage.configureFailure(operation: 1, after: false)
        let model = IdentityViewModel(service: service(storage))
        await model.load()
        XCTAssertNotNil(model.recovery)
        storage.clearFailure()
        await model.load()
        XCTAssertNil(model.local)
        XCTAssertNil(storage.record)
        await model.load(force: true)
        XCTAssertNotNil(model.local)
        XCTAssertNil(model.recovery)
    }

    func testRecoveryDoesNotOfferResetForTemporaryOrSigningFailures() {
        for error in [IdentityError.accessDenied, .configurationRequired, .storageUnavailable("test")] {
            let recovery = IdentityRecovery(error: error)
            XCTAssertTrue(recovery.canRetry)
            XCTAssertFalse(recovery.canReset, "A temporary failure must not invite identity replacement")
        }
        let oldPolicy = IdentityRecovery(error: .keyPolicyNeedsReset)
        XCTAssertTrue(oldPolicy.canReset)
        XCTAssertFalse(oldPolicy.canRetry, "Retry cannot repair an immutable key policy")
        XCTAssertTrue(IdentityRecovery(error: .keyMissing).canReset)
        XCTAssertTrue(IdentityRecovery(error: .inconsistentStorage).canReset)
        XCTAssertFalse(IdentityRecovery(error: nil).canReset)
    }

    private func service(_ storage: MemoryIdentityStorage) -> IdentityService {
        IdentityService(storage: storage, deviceName: "Test Mac", tagPrefix: "test.identity.")
    }

    private func hex(_ value: String) throws -> Data {
        var result = Data()
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            result.append(try XCTUnwrap(UInt8(value[index..<next], radix: 16)))
            index = next
        }
        return result
    }
}

// Access is serialized by one service actor; the test configures faults only
// before an awaited operation and inspects the store only after it completes.
private final class MemoryIdentityStorage: IdentityStorage, @unchecked Sendable {
    var record: IdentityRecord?
    var keys: [String: P256.Signing.PrivateKey] = [:]
    var corruptSignatures = false
    var denySigning = false
    private(set) var signingCount = 0
    private(set) var operationCount = 0
    private(set) var failureTriggered = false
    private var failingOperation: Int?
    private var failAfter = false

    func configureFailure(operation: Int, after: Bool) {
        operationCount = 0; failureTriggered = false; failingOperation = operation; failAfter = after
    }
    func clearFailure() { failingOperation = nil; operationCount = 0 }
    private func operation<T>(_ body: () throws -> T) throws -> T {
        operationCount += 1
        let fails = operationCount == failingOperation
        if fails { failureTriggered = true }
        if fails && !failAfter { throw IdentityError.storageUnavailable("injected") }
        let result = try body()
        if fails && failAfter { throw IdentityError.storageUnavailable("injected after operation") }
        return result
    }
    func loadRecord() throws -> IdentityRecord? { try operation { record } }
    func saveRecord(_ value: IdentityRecord) throws { try operation { record = value } }
    func keyTags() throws -> [String] { try operation { Array(keys.keys) } }
    func key(tag: String) throws -> StoredPublicKey? {
        try operation { keys[tag].map { StoredPublicKey(bytes: $0.publicKey.x963Representation, protection: .keychainSoftware) } }
    }
    func createKey(tag: String) throws -> StoredPublicKey {
        try operation {
            guard keys[tag] == nil else { throw IdentityError.inconsistentStorage }
            let key = P256.Signing.PrivateKey(); keys[tag] = key
            return StoredPublicKey(bytes: key.publicKey.x963Representation, protection: .keychainSoftware)
        }
    }
    func sign(tag: String, message: Data) throws -> Data {
        try operation {
            signingCount += 1
            if denySigning { throw IdentityError.accessDenied }
            guard let key = keys[tag] else { throw IdentityError.keyMissing }
            return corruptSignatures ? Data([0]) : try key.signature(for: message).derRepresentation
        }
    }
    func deleteKey(tag: String) throws { try operation { keys[tag] = nil } }
}
