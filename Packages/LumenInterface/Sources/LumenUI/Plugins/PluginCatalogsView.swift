import SwiftUI
import LumenFoundation
import LumenDesignSystem
import LumenPresentation
import LumenApplication
import LumenPlugins

/// Catalogs the user added: static plugin lists at `https` addresses. Each entry installs
/// through the same review as any other package, after its download matched the listed SHA-256.
struct PluginCatalogsView: View {
    let services: LumenServices
    @State private var catalogs: PluginCatalogsViewModel
    @State private var reviewing: PluginInstallRequest?

    init(services: LumenServices) {
        self.services = services
        _catalogs = State(initialValue: PluginCatalogsViewModel(services: services))
    }

    var body: some View {
        Form {
            Section {
                TextField("https://example.com/plugins/catalog.json", text: $catalogs.newCatalogAddress)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { Task { await catalogs.add() } }
                    .accessibilityLabel("Catalog address")
                Button("Add catalog") { Task { await catalogs.add() } }
                    .disabled(!catalogs.canAdd)
                if let failure = catalogs.addFailure {
                    Label(failure.message, systemImage: "exclamationmark.triangle")
                        .lumenText(.caption)
                        .foregroundStyle(LumenColor.danger)
                }
            } header: {
                Text("Add a catalog")
            } footer: {
                Text("A catalog is a list of plugins published at an https address, such as a file in a GitHub repository. Lumen comes with none; add only catalogs you trust. Every plugin is still reviewed before it is installed.")
            }

            if catalogs.isLoaded, catalogs.catalogs.isEmpty {
                Section {
                    Text("No catalogs yet.").foregroundStyle(LumenColor.textSecondary)
                }
            }

            ForEach(catalogs.catalogs) { catalog in
                Section {
                    let rows = catalogs.rows(for: catalog)
                    if rows.isEmpty {
                        Text("This catalog lists no plugins.").foregroundStyle(LumenColor.textSecondary)
                    }
                    ForEach(rows) { row in
                        CatalogEntryRow(row: row) { reviewing = .catalogEntry(row.entry, row.catalog) }
                    }
                } header: {
                    HStack {
                        Text(catalog.displayName)
                        Spacer()
                        Menu {
                            Button { Task { await catalogs.refresh(catalog) } } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                            Button(role: .destructive) { Task { await catalogs.remove(catalog) } } label: {
                                Label("Remove catalog", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("Options for \(catalog.displayName)")
                        .disabled(catalogs.isWorking)
                    }
                } footer: {
                    Text(catalog.url.absoluteString)
                }
            }
        }
        .navigationTitle("Catalogs")
        .task { await catalogs.load() }
        .refreshable { await catalogs.refreshAll() }
        .sheet(item: $reviewing, onDismiss: { Task { await catalogs.load() } }) { request in
            NavigationStack {
                PluginReviewView(services: services, request: request)
            }
        }
    }
}

private struct CatalogEntryRow: View {
    let row: PluginCatalogsViewModel.EntryRow
    let review: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: LumenSpace.m) {
            VStack(alignment: .leading, spacing: LumenSpace.xxs) {
                Text(row.entry.name).lumenText(.body)
                Text(verbatim: "\(row.entry.publisher) · \(row.statusText)")
                    .lumenText(.caption)
                    .foregroundStyle(LumenColor.textSecondary)
                if !row.entry.summary.isEmpty {
                    Text(row.entry.summary)
                        .lumenText(.caption)
                        .foregroundStyle(LumenColor.textTertiary)
                        .lineLimit(3)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if let title = row.actionTitle {
                Button(title, action: review)
                    .buttonStyle(.lumenQuiet)
                    .accessibilityLabel("\(title) \(row.entry.name)")
            }
        }
    }
}
