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

    // MARK: - Files handed over by other apps

    /// The folder iOS copies a document into when another app hands it to Lumen ("Open in
    /// Lumen"; Lumen doesn't open documents in place).
    public static func inboxDirectory(documentsDirectory: URL) -> URL {
        documentsDirectory.appendingPathComponent("Inbox", isDirectory: true)
    }

    /// Whether `url` is such a copy. Only these are Lumen's to delete: a file picked in the Files
    /// app is the user's own and is never removed.
    public static func isInboxCopy(_ url: URL, documentsDirectory: URL) -> Bool {
        guard url.isFileURL else { return false }
        let inbox = inboxDirectory(documentsDirectory: documentsDirectory).standardizedFileURL.resolvingSymlinksInPath().path
        let file = url.standardizedFileURL.resolvingSymlinksInPath().path
        return file.hasPrefix(inbox + "/")
    }

    /// Deletes `url` when it is an inbox copy; its bytes have been read by then. Returns whether a
    /// file was removed.
    @discardableResult
    public static func removeInboxCopy(_ url: URL, documentsDirectory: URL, fileManager: FileManager = .default) -> Bool {
        guard isInboxCopy(url, documentsDirectory: documentsDirectory) else { return false }
        do {
            try fileManager.removeItem(at: url)
            return true
        } catch {
            // Best-effort cleanup: the package was read already; a copy that can't be removed only
            // takes space in the app's own container.
            return false
        }
    }
}
