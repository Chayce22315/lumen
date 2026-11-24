import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Checks Ed25519 signatures. Apple platforms use CryptoKit (`CryptoKitSignatureVerifier`);
/// tests use a fake; elsewhere `UnavailableSignatureVerifier` refuses signed packages.
public protocol PluginSignatureVerifier: Sendable {
    /// Whether `signature` (64 bytes) is a valid Ed25519 signature of `message` by `publicKey`
    /// (32 raw bytes). Throws when the key itself is unusable or verification is unavailable.
    func isValidSignature(_ signature: Data, of message: Data, publicKey: Data) throws -> Bool
}

/// For platforms without an Ed25519 implementation: signed packages can't be checked, so they
/// are refused rather than trusted.
public struct UnavailableSignatureVerifier: PluginSignatureVerifier {
    public init() {}

    public func isValidSignature(_ signature: Data, of message: Data, publicKey: Data) throws -> Bool {
        throw PluginPackageError.signatureUnverifiable
    }
}

#if canImport(CryptoKit)
/// Ed25519 verification with CryptoKit's `Curve25519.Signing`.
public struct CryptoKitSignatureVerifier: PluginSignatureVerifier {
    public init() {}

    public func isValidSignature(_ signature: Data, of message: Data, publicKey: Data) throws -> Bool {
        let key: Curve25519.Signing.PublicKey
        do {
            key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        } catch {
            // A key CryptoKit can't load can't have made a valid signature.
            return false
        }
        return key.isValidSignature(signature, for: message)
    }
}
#endif

public enum PluginSignatureVerifiers {
    /// The best verifier this platform has.
    public static var platformDefault: any PluginSignatureVerifier {
        #if canImport(CryptoKit)
        return CryptoKitSignatureVerifier()
        #else
        return UnavailableSignatureVerifier()
        #endif
    }
}

/// A publisher's signing key with the fingerprint people compare.
public struct PublisherKey: Sendable, Hashable {
    /// Raw 32-byte Ed25519 public key.
    public let rawValue: Data
    /// The first 16 bytes of the key's SHA-256, as 8 groups of 4 uppercase hex digits.
    public let fingerprint: String

    public init(rawValue: Data, digest: (Data) -> String) {
        self.rawValue = rawValue
        let hex = digest(rawValue).uppercased().prefix(32)
        var groups: [String] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 4, limitedBy: hex.endIndex) ?? hex.endIndex
            groups.append(String(hex[index..<end]))
            index = end
        }
        self.fingerprint = groups.joined(separator: " ")
    }

    /// The key as stored and written in packages.
    public var base64: String { rawValue.base64EncodedString() }
}

/// What the signature of a package says.
public enum PluginSignatureStatus: Sendable, Hashable {
    case unsigned
    /// The signature matches the payload and was made by this key.
    case signed(PublisherKey)

    public var key: PublisherKey? {
        if case .signed(let key) = self { return key }
        return nil
    }

    public var isSigned: Bool { key != nil }
}
