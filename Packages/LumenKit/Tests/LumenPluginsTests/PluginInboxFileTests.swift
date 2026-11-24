import Foundation
import Testing
import LumenPlugins

@Suite("Files handed over by other apps")
struct PluginInboxFileTests {
    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-inbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ name: String, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        try Data("{}".utf8).write(to: file)
        return file
    }

    @Test("only the copy in Documents/Inbox is removed; the user's own files are kept")
    func removesOnlyInboxCopies() throws {
        let documents = try scratch()
        defer { try? FileManager.default.removeItem(at: documents) } // best-effort cleanup of a scratch directory
        let inbox = PluginPackageFile.inboxDirectory(documentsDirectory: documents)
        let copy = try write("weekly.lumenplugin", in: inbox)
        let picked = try write("weekly.lumenplugin", in: documents.appendingPathComponent("Downloads"))
        let lookalike = try write("weekly.lumenplugin", in: documents.appendingPathComponent("InboxOld"))
        let escaping = inbox.appendingPathComponent("../Downloads/weekly.lumenplugin")

        #expect(PluginPackageFile.isInboxCopy(copy, documentsDirectory: documents))
        #expect(!PluginPackageFile.isInboxCopy(picked, documentsDirectory: documents))
        #expect(!PluginPackageFile.isInboxCopy(lookalike, documentsDirectory: documents))
        #expect(!PluginPackageFile.isInboxCopy(escaping, documentsDirectory: documents))
        #expect(!PluginPackageFile.isInboxCopy(try #require(URL(string: "https://example.com/Inbox/a.lumenplugin")), documentsDirectory: documents))

        #expect(PluginPackageFile.removeInboxCopy(copy, documentsDirectory: documents))
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(!PluginPackageFile.removeInboxCopy(picked, documentsDirectory: documents))
        #expect(!PluginPackageFile.removeInboxCopy(escaping, documentsDirectory: documents))
        #expect(FileManager.default.fileExists(atPath: picked.path))
        #expect(FileManager.default.fileExists(atPath: lookalike.path))
        // Already gone: nothing to remove, no error.
        #expect(!PluginPackageFile.removeInboxCopy(copy, documentsDirectory: documents))
    }
}
