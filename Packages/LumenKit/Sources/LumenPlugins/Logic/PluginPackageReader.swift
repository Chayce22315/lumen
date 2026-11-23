import Foundation

/// A decoded package whose signature was checked.
public struct VerifiedPluginPackage: Sendable, Hashable {
    public let package: PluginPackage
    public let signature: PluginSignatureStatus

    public var manifest: PluginPackageManifest { package.manifest }
}

/// Decodes a package and verifies its signature. A package whose signature doesn't verify is
/// refused outright; unsigned packages are returned as `.unsigned` for the review to flag.
public struct PluginPackageReader: Sendable {
    public let decoder: PluginPackageDecoder
    private let verifier: any PluginSignatureVerifier
    private let digest: @Sendable (Data) -> String

    public init(verifier: any PluginSignatureVerifier, digest: @escaping @Sendable (Data) -> String, limits: PluginPackageFormat.Limits = PluginPackageFormat.Limits()) {
        self.decoder = PluginPackageDecoder(limits: limits, digest: digest)
        self.verifier = verifier
        self.digest = digest
    }

    public func read(_ data: Data) throws -> VerifiedPluginPackage {
        let package = try decoder.decode(data)
        guard let signature = package.signature else {
            return VerifiedPluginPackage(package: package, signature: .unsigned)
        }
        let message = PluginPackageFormat.signedMessage(payload: package.payload)
        guard try verifier.isValidSignature(signature.value, of: message, publicKey: signature.publicKey) else {
            throw PluginPackageError.signatureInvalid
        }
        return VerifiedPluginPackage(package: package, signature: .signed(publisherKey(signature.publicKey)))
    }

    public func publisherKey(_ raw: Data) -> PublisherKey {
        PublisherKey(rawValue: raw, digest: digest)
    }

    public func sha256(_ data: Data) -> String {
        digest(data)
    }
}
