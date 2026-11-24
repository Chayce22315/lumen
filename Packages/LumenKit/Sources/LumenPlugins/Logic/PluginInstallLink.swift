import Foundation

/// `lumen://plugin/install?url=<https address of a .lumenplugin file>`: a link a publisher can
/// put on a web page. Opening it downloads the package and shows the install review; nothing is
/// installed without the user's confirmation there.
public enum PluginInstallLink {
    public static let scheme = "lumen"
    public static let host = "plugin"
    public static let path = "/install"
    public static let maximumURLLength = 2_048

    /// The package address in an install link, or `nil` when `url` isn't a valid install link.
    /// The address must be `https`, with a host and no user name or password.
    public static func packageURL(from url: URL) -> URL? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host, url.path == path,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let values = (components.queryItems ?? []).filter { $0.name == "url" }.compactMap(\.value)
        guard values.count == 1, let text = values.first, text.count <= maximumURLLength,
              let package = URL(string: text), isAllowedDownload(package) else { return nil }
        return package
    }

    /// The install link for a package address.
    public static func link(for packageURL: URL) -> URL? {
        guard isAllowedDownload(packageURL) else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = path
        components.queryItems = [URLQueryItem(name: "url", value: packageURL.absoluteString)]
        return components.url
    }

    /// Whether Lumen downloads from `url`: `https` with a host and no embedded credentials.
    public static func isAllowedDownload(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && (url.host?.isEmpty == false) && url.user == nil && url.password == nil
    }

    /// Whether `url` names a plugin package file on this device (opened from Files or the share sheet).
    public static func isPackageFile(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == PluginPackageFormat.fileExtension
    }
}
