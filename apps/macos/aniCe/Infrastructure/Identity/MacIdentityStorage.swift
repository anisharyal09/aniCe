// SPDX-License-Identifier: GPL-3.0-or-later
// Preserves the original app-container journal location and native Keychain identity backend.
import Darwin
import CryptoKit
import Foundation
import os
import LocalAuthentication
import Security

enum MacIdentityBackend: Sendable {
    // Explicitly selected for local ad-hoc builds; never a runtime error fallback.
    case developmentKeychain
    case signedDataProtection

    static var current: Self {
        #if ANICE_DEVELOPMENT_KEYCHAIN
        .developmentKeychain
        #else
        .signedDataProtection
        #endif
    }
}

final class MacIdentityStorage: IdentityStorage, @unchecked Sendable {
    let namespace: String
    let backend: MacIdentityBackend
    private let recordURL: URL

    init(namespace: String, backend: MacIdentityBackend, recordURL: URL? = nil) {
        self.namespace = namespace
        self.backend = backend
        self.recordURL = recordURL ?? MacAppStorage.directory.appendingPathComponent("Identity/development-identity.json")
    }

    func loadRecord() throws -> IdentityRecord? {
        let data: Data
        switch backend {
        case .developmentKeychain:
            do { data = try Data(contentsOf: recordURL) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
            catch { throw IdentityError.storageUnavailable("record read") }
        case .signedDataProtection:
            var query = metadataQuery()
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var value: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &value)
            if status == errSecItemNotFound { return nil }
            try check(status)
            guard let found = value as? Data else { throw IdentityError.inconsistentStorage }
            data = found
        }
        do { return try JSONDecoder().decode(IdentityRecord.self, from: data) }
        catch { throw IdentityError.inconsistentStorage }
    }

    func saveRecord(_ record: IdentityRecord) throws {
        let data = try JSONEncoder().encode(record)
        switch backend {
        case .developmentKeychain:
            do {
                var directory = recordURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try directory.setResourceValues(values)
                try data.write(to: recordURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)
                var file = recordURL
                try file.setResourceValues(values)
            } catch { throw IdentityError.storageUnavailable("record write") }
        case .signedDataProtection:
            let query = metadataQuery()
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var addition = query
                addition[kSecValueData as String] = data
                addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                try check(SecItemAdd(addition as CFDictionary, nil))
            } else { try check(status) }
        }
    }

    func keyTags() throws -> [String] {
        var query = try keyQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return [] }
        try check(status)
        guard let attributes = value as? [[String: Any]] else { throw IdentityError.inconsistentStorage }
        return try attributes.map { item in
            guard let tagData = item[kSecAttrApplicationTag as String] as? Data,
                  let tag = String(data: tagData, encoding: .utf8), tag.hasPrefix(namespace + ".")
            else { throw IdentityError.inconsistentStorage }
            return tag
        }
    }

    func key(tag: String) throws -> StoredPublicKey? {
        guard let key = try keyReference(tag: tag) else { return nil }
        return try publicKey(key, tag: tag)
    }

    func createKey(tag: String) throws -> StoredPublicKey {
        try validateTag(tag)
        guard try keyReference(tag: tag) == nil else { throw IdentityError.inconsistentStorage }
        var privateAttributes: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: Data(tag.utf8),
            kSecAttrLabel as String: namespace,
            kSecAttrIsExtractable as String: false,
        ]
        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        switch backend {
        case .developmentKeychain:
            // The legacy key generator reads this flag from the top-level dictionary.
            // Keeping it only under kSecPrivateKeyAttrs leaves legacy keys extractable.
            attributes[kSecAttrIsExtractable as String] = false
            attributes[kSecUseDataProtectionKeychain as String] = false
            attributes[kSecUseKeychain as String] = try legacyKeychain()
        case .signedDataProtection:
            attributes[kSecUseDataProtectionKeychain as String] = true
            privateAttributes[kSecAttrSynchronizable as String] = false
            if SecureEnclave.isAvailable {
                var accessError: Unmanaged<CFError>?
                guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                                                  .privateKeyUsage, &accessError) else {
                    throw IdentityError.storageUnavailable("access policy")
                }
                privateAttributes[kSecAttrAccessControl as String] = access
                attributes[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
            } else {
                privateAttributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }
        }
        attributes[kSecPrivateKeyAttrs as String] = privateAttributes
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            try fail(error)
        }
        return try publicKey(key, tag: tag)
    }

    private static let signingRequests = OSAllocatedUnfairLock(initialState: 0)
    private static let signingLogger = Logger(subsystem: "io.github.anisharyal09.anice", category: "identity-signing")
    func sign(tag: String, message: Data) throws -> Data {
        let count = Self.signingRequests.withLock { $0 += 1; return $0 }
        Self.signingLogger.debug("Private signing request \(count, privacy: .public)")
        guard let key = try keyReference(tag: tag) else { throw IdentityError.inconsistentStorage }
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, message as CFData, &error)
        else { try fail(error) }
        return signature as Data
    }

    func deleteKey(tag: String) throws {
        var query = try keyQuery()
        try validateTag(tag)
        query[kSecAttrApplicationTag as String] = Data(tag.utf8)
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func publicKey(_ key: SecKey, tag: String) throws -> StoredPublicKey {
        // Never use SecKeyCopyAttributes on a legacy private key: Apple's legacy
        // implementation attempts external key representation while building it.
        let protection: KeyProtection
        if backend == .developmentKeychain {
            guard try !legacyKeyIsExtractable(key) else { throw IdentityError.keyPolicyNeedsReset }
            protection = .developmentKeychain
        } else {
            let attributes = try storedKeyAttributes(tag: tag)
            protection = attributes[kSecAttrTokenID as String] as? String == kSecAttrTokenIDSecureEnclave as String
                ? .secureEnclave : .keychainSoftware
        }
        guard let publicKey = SecKeyCopyPublicKey(key) else { throw IdentityError.inconsistentStorage }
        var error: Unmanaged<CFError>?
        guard let bytes = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else { try fail(error) }
        guard bytes.count == 65, bytes.first == 4, (try? P256.Signing.PublicKey(x963Representation: bytes)) != nil
        else { throw IdentityError.inconsistentStorage }
        return StoredPublicKey(bytes: bytes, protection: protection)
    }

    // These deprecated APIs are intentional for the ad-hoc development backend.
    // Retire this path after signed data-protection storage and migration are verified;
    // SecKeyCopyAttributes is not a safe substitute for this legacy policy query.
    private func legacyKeyIsExtractable(_ key: SecKey) throws -> Bool {
        var tag = UInt32(kSecKeyExtractable)
        var format = UInt32(CSSM_DB_ATTRIBUTE_FORMAT_UINT32)
        var list: UnsafeMutablePointer<SecKeychainAttributeList>?
        let status = withUnsafeMutablePointer(to: &tag) { tagPointer in
            withUnsafeMutablePointer(to: &format) { formatPointer in
                var info = SecKeychainAttributeInfo(count: 1, tag: tagPointer, format: formatPointer)
                // Legacy SecKey references are accepted as keychain items by this API.
                // Request exactly one policy attribute and no key data.
                return SecKeychainItemCopyAttributesAndData(
                    unsafeBitCast(key, to: SecKeychainItem.self), &info, nil, &list, nil, nil)
            }
        }
        defer { if let list { SecKeychainItemFreeAttributesAndData(list, nil) } }
        try check(status)
        guard let list, list.pointee.count == 1, let attribute = list.pointee.attr,
              attribute.pointee.length == MemoryLayout<UInt32>.size,
              let data = attribute.pointee.data else { throw IdentityError.inconsistentStorage }
        return data.loadUnaligned(as: UInt32.self) != 0
    }

    private func storedKeyAttributes(tag: String) throws -> [String: Any] {
        try validateTag(tag)
        var query = try keyQuery()
        query[kSecAttrApplicationTag as String] = Data(tag.utf8)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        try check(SecItemCopyMatching(query as CFDictionary, &value))
        guard let attributes = value as? [String: Any] else { throw IdentityError.inconsistentStorage }
        return attributes
    }

    private func keyReference(tag: String) throws -> SecKey? {
        try validateTag(tag)
        var query = try keyQuery()
        query[kSecAttrApplicationTag as String] = Data(tag.utf8)
        query[kSecReturnRef as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let value, CFGetTypeID(value) == SecKeyGetTypeID() else { throw IdentityError.inconsistentStorage }
        return (value as! SecKey)
    }

    private func keyQuery() throws -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassKey,
                                    kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                                    kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                                    kSecAttrLabel as String: namespace,
                                    kSecUseAuthenticationContext as String: noninteractiveContext()]
        switch backend {
        case .developmentKeychain:
            query[kSecUseDataProtectionKeychain as String] = false
            query[kSecMatchSearchList as String] = [try legacyKeychain()]
        case .signedDataProtection:
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrSynchronizable as String] = false
        }
        return query
    }

    private func metadataQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: namespace,
         kSecAttrAccount as String: "identity-record-v1", kSecUseDataProtectionKeychain as String: true,
         kSecAttrSynchronizable as String: false, kSecUseAuthenticationContext as String: noninteractiveContext()]
    }

    private func noninteractiveContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    private func legacyKeychain() throws -> SecKeychain {
        var keychain: SecKeychain?
        try check(SecKeychainCopyDefault(&keychain))
        guard let keychain else { throw IdentityError.storageUnavailable("login Keychain") }
        return keychain
    }

    private func validateTag(_ tag: String) throws {
        guard tag.hasPrefix(namespace + "."),
              DeviceIdentity.isCanonicalDeviceID(String(tag.dropFirst(namespace.count + 1)))
        else { throw IdentityError.inconsistentStorage }
    }

    private func check(_ status: OSStatus) throws {
        guard status != errSecSuccess else { return }
        if status == errSecAuthFailed || status == errSecUserCanceled { throw IdentityError.accessDenied }
        if status == errSecMissingEntitlement { throw IdentityError.configurationRequired }
        throw IdentityError.storageUnavailable(String(status))
    }

    private func fail(_ error: Unmanaged<CFError>?) throws -> Never {
        if let error {
            let value = error.takeRetainedValue()
            if CFErrorGetCode(value) == Int(errSecAuthFailed) || CFErrorGetCode(value) == Int(errSecUserCanceled) {
                throw IdentityError.accessDenied
            }
            if CFErrorGetCode(value) == Int(errSecMissingEntitlement) { throw IdentityError.configurationRequired }
            throw IdentityError.storageUnavailable(String(CFErrorGetCode(value)))
        }
        throw IdentityError.storageUnavailable("unknown system error")
    }
}

/// Sandbox removal must not redirect identity/trust reads to a fresh application-support directory.
enum MacAppStorage {
    static func directory(home: URL) -> URL {
        home.appendingPathComponent("Library/Containers/io.github.anisharyal09.anice/Data/Library/Application Support/aniCe", isDirectory: true)
    }
    static var directory: URL {
        // passwd names the account home independently of Foundation's sandbox container redirection.
        guard let home = getpwuid(getuid())?.pointee.pw_dir else {
            preconditionFailure("Account home unavailable")
        }
        return directory(home: URL(fileURLWithPath: String(cString: home), isDirectory: true))
    }
}
