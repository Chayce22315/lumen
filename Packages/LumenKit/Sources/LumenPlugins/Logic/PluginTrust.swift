import Foundation

/// How far Lumen trusts a package's origin, decided before the review is shown.
///
/// Trust is on first use and per publisher key: the key that signed the installed version of a
/// plugin is pinned, and an update for the same identifier must be signed by that key. A
/// publisher name proves nothing (anyone can type it), so only keys are compared.
public enum PluginTrust: Sendable, Hashable {
    /// Signed with the key that signed the installed version.
    case pinnedKey(PublisherKey)
    /// Signed with a key no installed plugin uses yet: the user is trusting it for the first time.
    case newKey(PublisherKey)
    /// Signed with a key that already signed other installed plugins (listed by identifier).
    case knownKey(PublisherKey, otherPlugins: [String])
    /// Not signed: installing needs an extra confirmation.
    case unsigned

    public var key: PublisherKey? {
        switch self {
        case .pinnedKey(let key), .newKey(let key), .knownKey(let key, _): return key
        case .unsigned: return nil
        }
    }

    public var requiresUnsignedConfirmation: Bool { self == .unsigned }
}

/// Applies the trust rules. Pure.
public enum PluginTrustEvaluator {
    /// - Parameters:
    ///   - signature: the verified signature status of the offered package.
    ///   - pluginID: the offered package's identifier.
    ///   - installed: every installed package, with the key that signed it (`nil` when unsigned).
    /// - Throws: `publisherKeyChanged` when the installed version was signed by another key, and
    ///   `signatureRemoved` when it was signed and the update isn't.
    public static func evaluate(
        _ signature: PluginSignatureStatus,
        pluginID: String,
        installed: [(id: String, key: PublisherKey?)]
    ) throws -> PluginTrust {
        let pinned = installed.first { $0.id == pluginID }
        switch (signature, pinned?.key) {
        case (.signed(let offered), .some(let pinnedKey)):
            guard offered.rawValue == pinnedKey.rawValue else {
                throw PluginPackageError.publisherKeyChanged(pluginID: pluginID, pinned: pinnedKey.fingerprint, presented: offered.fingerprint)
            }
            return .pinnedKey(offered)
        case (.unsigned, .some):
            throw PluginPackageError.signatureRemoved(pluginID: pluginID)
        case (.signed(let offered), .none):
            let others = installed.filter { $0.id != pluginID && $0.key?.rawValue == offered.rawValue }.map(\.id).sorted()
            return others.isEmpty ? .newKey(offered) : .knownKey(offered, otherPlugins: others)
        case (.unsigned, .none):
            return .unsigned
        }
    }
}
