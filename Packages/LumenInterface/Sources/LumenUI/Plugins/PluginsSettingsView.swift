import SwiftUI
import UniformTypeIdentifiers
import LumenFoundation
import LumenDesignSystem
import LumenPresentation
import LumenApplication
import LumenPlugins

/// Settings › Plugins: installing from Files or a catalog, the installed plugins and Lumen's
/// built-in features. Packages opened from outside the app (Files, the share sheet, install
/// links) arrive through `inbox` and are reviewed here.
struct PluginsSettingsView: View {
    let services: LumenServices
    @Bindable var inbox: PluginRequestInbox
    @State private var plugins: PluginsViewModel
    @State private var isImporting = false

    init(services: LumenServices, inbox: PluginRequestInbox) {
        self.services = services
        self.inbox = inbox
        _plugins = State(initialValue: PluginsViewModel(services: services))
    }

    var body: some View {
        Form {
            Section {
                if plugins.allowsThirdParty {
                    Button { isImporting = true } label: {
                        Label("Install from Files", systemImage: "doc.badge.plus")
                    }
                    .accessibilityIdentifier("plugins.import")
                    NavigationLink {
                        PluginCatalogsView(services: services)
                    } label: {
                        Label("Catalogs", systemImage: "list.bullet.rectangle")
                    }
                }
            } header: {
                Text("Add plugins")
            } footer: {
                Text(plugins.allowsThirdParty
                    ? "Plugins add automation templates, commands and assistant shortcuts that Lumen runs itself; they can't run code. You see what each one asks for before it is installed."
                    : "This build of Lumen doesn't allow third-party plugins.")
            }

            Section("Installed") {
                if plugins.isLoaded, plugins.thirdParty.isEmpty {
                    Text("No plugins installed.")
                        .foregroundStyle(LumenColor.textSecondary)
                }
                ForEach(plugins.thirdParty) { row in
                    NavigationLink {
                        PluginDetailView(services: services, pluginID: row.id)
                    } label: {
                        PluginRowView(row: row)
                    }
                }
            }

            Section {
                ForEach(plugins.builtIn) { row in
                    PluginRowView(row: row)
                }
            } header: {
                Text("Built into Lumen")
            } footer: {
                Text("Lumen's own features use the same plugin system as installed plugins.")
            }
        }
        .navigationTitle("Plugins")
        .task { await plugins.start() }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: Self.packageTypes) { result in
            switch result {
            case .success(let url):
                inbox.receiveFile(url)
            case .failure(let error):
                inbox.receive(.unreadable(ErrorPresentation.from(error)))
            }
        }
        .sheet(item: $inbox.pending) { request in
            NavigationStack {
                PluginReviewView(services: services, request: request)
            }
        }
    }

    /// `.lumenplugin` files, declared by the app (`UTExportedTypeDeclarations`).
    static var packageTypes: [UTType] {
        [UTType(exportedAs: PluginPackageFormat.typeIdentifier, conformingTo: .json)]
    }
}

/// A plugin's name, publisher or summary, and state.
struct PluginRowView: View {
    let row: PluginsViewModel.Row

    var body: some View {
        HStack(spacing: LumenSpace.m) {
            IconBadge(row.isBuiltIn ? "sparkle" : "puzzlepiece.extension", tint: row.hasProblem ? LumenColor.warning : LumenColor.accent)
            VStack(alignment: .leading, spacing: LumenSpace.xxs) {
                Text(row.name).lumenText(.body)
                Text(row.isBuiltIn ? row.status.manifest.summary : row.subtitle)
                    .lumenText(.caption)
                    .foregroundStyle(LumenColor.textSecondary)
                    .lineLimit(2)
                Text(row.stateText)
                    .lumenText(.caption)
                    .foregroundStyle(row.hasProblem ? LumenColor.warning : LumenColor.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
