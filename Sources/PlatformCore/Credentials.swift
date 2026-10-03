import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
import Security

/// Secret persistence. Implementations must fail truthfully; there is no
/// plaintext fallback for unavailable secure storage.
public protocol CredentialStore: Sendable {
    func secret(forKey key: String) throws -> Data?
    func setSecret(_ secret: Data, forKey key: String) throws
}

public enum CredentialKey {
    /// Key material by SHA-256 of the resolved runtime root plus scope, so a
    /// secret is bound to its own root and cannot be borrowed across roots.
    public static func key(root: URL, scope: CredentialScope) -> String {
        var canonical = root.standardizedFileURL.path
        if canonical.hasSuffix("/") { canonical.removeLast() }
        let digest = SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "ondevice-agent-platform/\(digest)/\(scope.rawValue)"
    }
}

public enum SecretGenerator {
    public static func token() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw PlatformError(.internal, detail: "SecRandomCopyBytes \(status)")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Keychain-backed store used by the real executable. Items are generic
/// passwords scoped by service + account key.
public final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    private let service = "ondevice-agent-platform"

    public init() {}

    public func secret(forKey key: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            // Pin to the file-based keychain: the data-protection keychain is
            // unavailable to unsigned binaries, and an explicit pin keeps the
            // backend stable regardless of future signing/entitlement changes.
            kSecUseDataProtectionKeychain as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw PlatformError(.internal, detail: "keychain read \(status)")
        }
        return data
    }

    public func setSecret(_ secret: Data, forKey key: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecUseDataProtectionKeychain as String: false,
        ]
        let status = SecItemUpdate(base as CFDictionary,
                                   [kSecValueData as String: secret] as CFDictionary)
        if status == errSecSuccess { return }
        if status == errSecItemNotFound {
            var insert = base
            insert[kSecValueData as String] = secret
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw PlatformError(.internal, detail: "keychain add \(addStatus)")
            }
            return
        }
        throw PlatformError(.internal, detail: "keychain update \(status)")
    }

    /// Returns the stored secret or generates and stores a new one.
    public func ensureSecret(root: URL, scope: CredentialScope) throws -> String {
        let key = CredentialKey.key(root: root, scope: scope)
        if let existing = try secret(forKey: key), let text = String(data: existing, encoding: .utf8) {
            return text
        }
        let token = try SecretGenerator.token()
        try setSecret(Data(token.utf8), forKey: key)
        return token
    }
}
