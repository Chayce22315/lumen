import Foundation

/// Reads a `.lumenplugin` file from disk without loading more than the package limit.
public enum PluginPackageFile {
    /// The file's bytes. Throws `tooLarge` past `limit` bytes (only `limit + 1` are read), and
    /// `malformed` when the file can't be opened.
    public static func read(_ url: URL, limit: Int = PluginPackageFormat.Limits().maximumPackageBytes) throws -> Data {
        #if canImport(Darwin)
        // Files picked in the Files app (or opened in place) are security-scoped; access is held
        // for the read only. Files copied into the app's Inbox need no scope (this returns false).
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer { if isAccessing { url.stopAccessingSecurityScopedResource() } }
        #endif
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw PluginPackageError.malformed(path: "", reason: "The file couldn't be opened.")
        }
        defer {
            do {
                try handle.close()
            } catch {
                // Closing a read-only handle can't lose data; the bytes were already read.
            }
        }
        let data: Data
        do {
            data = try handle.read(upToCount: limit + 1) ?? Data()
        } catch {
            throw PluginPackageError.malformed(path: "", reason: "The file couldn't be read.")
        }
        guard data.count <= limit else { throw PluginPackageError.tooLarge(bytes: data.count, limit: limit) }
        return data
    }
}
