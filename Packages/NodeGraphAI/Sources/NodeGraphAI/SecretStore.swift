#if !os(tvOS) && !os(watchOS)
import Foundation
import Security
import Synchronization

/// Where API keys live. Never in `ModelEndpoint` and never in a file (decision 214).
public protocol SecretStore: Sendable {
    func secret(for account: String) -> String?
    func setSecret(_ secret: String?, for account: String) throws
}

/// The Keychain, one generic-password item per endpoint account, on this device only.
public struct KeychainSecretStore: SecretStore {
    private let service: String

    public init(service: String = "NodeGraph.AI") { self.service = service }

    public struct KeychainError: Error, LocalizedError {
        public var status: OSStatus
        public var errorDescription: String? { "The Keychain refused the change (\(status))." }
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func secret(for account: String) -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setSecret(_ secret: String?, for account: String) throws {
        SecItemDelete(query(account) as CFDictionary)
        guard let secret, !secret.isEmpty else { return }
        var item = query(account)
        item[kSecValueData as String] = Data(secret.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { throw KeychainError(status: status) }
    }
}

/// Keys held in memory, for tests.
public final class InMemorySecretStore: SecretStore {
    private let values = Mutex<[String: String]>([:])

    public init(_ initial: [String: String] = [:]) { values.withLock { $0 = initial } }

    public func secret(for account: String) -> String? { values.withLock { $0[account] } }

    public func setSecret(_ secret: String?, for account: String) throws {
        values.withLock { $0[account] = (secret?.isEmpty ?? true) ? nil : secret }
    }
}
#endif
