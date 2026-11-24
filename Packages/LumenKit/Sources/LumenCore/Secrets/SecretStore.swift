import Foundation
import Synchronization

/// Identifies one secret (an API key, a sync token).
public struct SecretKey: Hashable, Sendable, Codable {
    public let account: String

    public init(_ account: String) {
        self.account = account
    }
}

/// Secure storage for credentials. Production uses the Keychain; secrets never touch SQLite,
/// settings, logs or analytics.
public protocol SecretStore: Sendable {
    func secret(for key: SecretKey) throws -> String?
    func setSecret(_ value: String, for key: SecretKey) throws
    func removeSecret(for key: SecretKey) throws
}

extension SecretStore {
    public func hasSecret(for key: SecretKey) -> Bool {
        ((try? secret(for: key)) ?? nil) != nil
    }
}

/// Process-local secret storage for tests and previews. Never used in release builds.
public final class InMemorySecretStore: SecretStore {
    private let storage = Mutex<[SecretKey: String]>([:])

    public init(_ initial: [SecretKey: String] = [:]) {
        storage.withLock { $0 = initial }
    }

    public func secret(for key: SecretKey) throws -> String? {
        storage.withLock { $0[key] }
    }

    public func setSecret(_ value: String, for key: SecretKey) throws {
        storage.withLock { $0[key] = value }
    }

    public func removeSecret(for key: SecretKey) throws {
        _ = storage.withLock { $0.removeValue(forKey: key) }
    }
}
