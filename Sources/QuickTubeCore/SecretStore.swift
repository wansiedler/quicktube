import Foundation
import Security

public protocol SecretStore: Sendable {
    func get(_ key: String) throws -> String?
    func set(_ value: String, for key: String) throws
    func delete(_ key: String) throws
}

/// Test double and fallback; nothing persists.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init() {}

    public func get(_ key: String) throws -> String? {
        lock.withLock { values[key] }
    }

    public func set(_ value: String, for key: String) throws {
        lock.withLock { values[key] = value }
    }

    public func delete(_ key: String) throws {
        lock.withLock { values[key] = nil }
    }
}

public struct KeychainError: Error, Equatable {
    public let status: OSStatus
}

/// Generic-password items under one service name.
public struct KeychainStore: SecretStore {
    public let service: String

    public init(service: String = "com.wansiedler.quicktube") {
        self.service = service
    }

    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    public func get(_ key: String) throws -> String? {
        var query = query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func set(_ value: String, for key: String) throws {
        let data = Data(value.utf8)
        let attributes = [kSecValueData as String: data] as CFDictionary
        let update = SecItemUpdate(query(key) as CFDictionary, attributes)
        if update == errSecItemNotFound {
            var query = query(key)
            query[kSecValueData as String] = data
            let add = SecItemAdd(query as CFDictionary, nil)
            guard add == errSecSuccess else { throw KeychainError(status: add) }
        } else if update != errSecSuccess {
            throw KeychainError(status: update)
        }
    }

    public func delete(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}
