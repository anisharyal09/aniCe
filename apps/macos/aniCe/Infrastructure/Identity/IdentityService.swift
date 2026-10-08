// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct StoredIdentity: Codable, Sendable {
    let identity: DeviceIdentity
    let keyTag: String
    let protection: KeyProtection
}

struct PendingIdentity: Codable, Sendable {
    let deviceId: String
    let deviceName: String
    let keyTag: String
}

struct IdentityRecord: Codable, Sendable {
    var storageVersion = 1
    var active: StoredIdentity?
    var pending: PendingIdentity?
    var retired: [String] = []
}

struct StoredPublicKey: Sendable {
    let bytes: Data
    let protection: KeyProtection
}

/// Abstraction for platform-specific keychain and key storage operations.
/// Only this app's exact namespace may be read, modified, or deleted by an adapter.
protocol IdentityStorage: Sendable {
    func loadRecord() throws -> IdentityRecord?
    func saveRecord(_ record: IdentityRecord) throws
    func keyTags() throws -> [String]
    func key(tag: String) throws -> StoredPublicKey?
    func createKey(tag: String) throws -> StoredPublicKey
    func sign(tag: String, message: Data) throws -> Data
    func deleteKey(tag: String) throws
}

/// Actor managing the local device identity lifecycle on macOS.
///
/// Features:
/// - Thread-safe actor isolation for all identity mutations.
/// - Two-phase atomic commit with staging tags to ensure active keys are never destroyed prematurely.
/// - Automatic self-verification challenge of newly created keys before committing.
/// - Non-silent failures: transient storage errors throw [IdentityError] without destroying established keys.
actor IdentityService {
    private let storage: any IdentityStorage
    private let deviceName: String
    private let tagPrefix: String

    init(storage: any IdentityStorage, deviceName: String, tagPrefix: String) {
        self.storage = storage
        self.deviceName = DeviceIdentity.normalizedName(deviceName)
        self.tagPrefix = tagPrefix
    }

    /// Loads public identity state without a private signing operation for an existing key.
    /// New keys still prove signing access before their active-record commit.
    func loadOrCreate() throws -> LocalIdentity {
        try loadIdentity()
    }

    private func loadIdentity() throws -> LocalIdentity {
        var record: IdentityRecord
        if let saved = try storage.loadRecord() {
            record = saved
            try validate(record)
        } else {
            guard try storage.keyTags().isEmpty else { throw IdentityError.inconsistentStorage }
            record = IdentityRecord(pending: newPending())
            try storage.saveRecord(record)
        }

        if let pending = record.pending {
            if record.active != nil {
                // An uncommitted reset always leaves the previous identity active.
                record.retired.append(pending.keyTag)
                record.pending = nil
                try storage.saveRecord(record)
            } else {
                // A first creation has a durable UUID/tag before key generation.
                let key = try storage.key(tag: pending.keyTag) ?? storage.createKey(tag: pending.keyTag)
                record.active = try storedIdentity(pending, key: key)
                record.pending = nil
                try storage.saveRecord(record)
            }
        }

        return try finish(record)
    }

    /// Public access does not add a preliminary signing operation to pairing.
    func publicIdentity() throws -> DeviceIdentity { try loadIdentity().identity }

    /// Updates public display metadata without replacing the device ID or signing key.
    func rename(_ name: String) throws -> LocalIdentity {
        let current = try loadIdentity()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.count <= 64,
              var record = try storage.loadRecord(), let active = record.active else {
            throw IdentityError.invalidPublicIdentity
        }
        let renamed = try DeviceIdentity(deviceId: current.identity.deviceId, deviceName: trimmed,
                                         publicKey: Data(base64Encoded: current.identity.publicKey)!)
        record.active = StoredIdentity(identity: renamed, keyTag: active.keyTag, protection: active.protection)
        try storage.saveRecord(record)
        return try loadIdentity()
    }

    func sign(message: Data) throws -> SignedIdentityPayload {
        // The requested signature itself proves access and key consistency below.
        // Avoid a second private-key operation solely for a preliminary self-check.
        let local = try loadIdentity()
        guard let record = try storage.loadRecord(), let active = record.active,
              active.identity == local.identity else { throw IdentityError.inconsistentStorage }
        let signature = try storage.sign(tag: active.keyTag, message: message)
        guard active.identity.verify(message: message, signature: signature) else {
            throw IdentityError.inconsistentStorage
        }
        return SignedIdentityPayload(identity: active.identity, signature: signature)
    }

    func reset() throws -> LocalIdentity {
        var old: IdentityRecord?
        do { old = try storage.loadRecord(); if let old { try validate(old) } }
        catch IdentityError.inconsistentStorage { old = nil }
        // Explicit reset also recovers missing/corrupt metadata. Never ignore an I/O error.
        let ownedTags = try storage.keyTags()
        let pending = newPending()
        var record = IdentityRecord(active: old?.active, pending: pending, retired: ownedTags.filter { $0 != old?.active?.keyTag })
        try storage.saveRecord(record)
        let key = try storage.createKey(tag: pending.keyTag)
        let replacement = try storedIdentity(pending, key: key)
        if let previous = record.active { record.retired.append(previous.keyTag) }
        record.active = replacement
        record.pending = nil
        // This atomic record update is the only identity-switch commit point.
        try storage.saveRecord(record)
        // The replacement already passed its signing check before the commit.
        return try finish(record)
    }

    private func newPending() -> PendingIdentity {
        PendingIdentity(deviceId: UUID().uuidString.lowercased(), deviceName: deviceName,
                        keyTag: tagPrefix + UUID().uuidString.lowercased())
    }

    private func storedIdentity(_ pending: PendingIdentity, key: StoredPublicKey) throws -> StoredIdentity {
        let identity = try DeviceIdentity(deviceId: pending.deviceId, deviceName: pending.deviceName, publicKey: key.bytes)
        try checkSigningKey(identity, tag: pending.keyTag)
        return StoredIdentity(identity: identity, keyTag: pending.keyTag, protection: key.protection)
    }

    private func validate(_ record: IdentityRecord) throws {
        guard record.storageVersion == 1, record.active != nil || record.pending != nil,
              record.retired.allSatisfy(validTag),
              Set(record.retired).count == record.retired.count else { throw IdentityError.inconsistentStorage }
        if let active = record.active {
            guard validTag(active.keyTag), !record.retired.contains(active.keyTag),
                  active.identity.platform == "macos", (try? active.identity.validate()) != nil
            else { throw IdentityError.inconsistentStorage }
        }
        if let pending = record.pending {
            guard validTag(pending.keyTag), pending.keyTag != record.active?.keyTag,
                  !record.retired.contains(pending.keyTag),
                  DeviceIdentity.isCanonicalDeviceID(pending.deviceId),
                  pending.deviceName == DeviceIdentity.normalizedName(pending.deviceName)
            else { throw IdentityError.inconsistentStorage }
        }
    }

    private func finish(_ source: IdentityRecord) throws -> LocalIdentity {
        guard let active = source.active else { throw IdentityError.inconsistentStorage }
        guard let key = try storage.key(tag: active.keyTag) else { throw IdentityError.keyMissing }
        guard key.bytes.base64EncodedString() == active.identity.publicKey,
              key.protection == active.protection else { throw IdentityError.inconsistentStorage }
        var record = source
        var remaining: [String] = []
        for tag in record.retired {
            do { try storage.deleteKey(tag: tag) } catch { remaining.append(tag) }
        }
        let changed = remaining != record.retired
        record.retired = remaining
        var cleanupPending = !remaining.isEmpty
        if changed {
            do { try storage.saveRecord(record) } catch { cleanupPending = true }
        }
        return LocalIdentity(identity: active.identity, protection: active.protection, cleanupPending: cleanupPending)
    }

    private func validTag(_ tag: String) -> Bool {
        tag.hasPrefix(tagPrefix) && DeviceIdentity.isCanonicalDeviceID(String(tag.dropFirst(tagPrefix.count)))
    }

    private func checkSigningKey(_ identity: DeviceIdentity, tag: String) throws {
        let challenge = Data(("aniCe identity storage self-check " + UUID().uuidString).utf8)
        let signature = try storage.sign(tag: tag, message: challenge)
        guard identity.verify(message: challenge, signature: signature) else { throw IdentityError.inconsistentStorage }
    }
}
