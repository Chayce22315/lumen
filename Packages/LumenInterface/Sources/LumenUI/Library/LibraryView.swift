import SwiftUI
import LumenCore
import UniformTypeIdentifiers
import LumenFoundation
import LumenDesignSystem
import LumenPresentation
import LumenApplication
import LumenKnowledge

/// Notes, collections, tags and documents.
struct LibraryView: View {
    let services: LumenServices
    let model: AppModel
    @State private var library: LibraryViewModel
    @State private var isImporting = false
    @State private var newCollectionName = ""
    @State private var isNamingCollection = false

    init(services: LumenServices, model: AppModel, initialFilter: LibraryViewModel.Filter = .all) {
        self.services = services
        self.model = model
        let library = LibraryViewModel(services: services)
        library.filter = initialFilter
        _library = State(initialValue: library)
    }

    var body: some View {
        List {
            filters
            notesSection
            if !library.collections.isEmpty { collectionsSection }
            if !library.documents.isEmpty { documentsSection }
        }
        .scrollContentBackground(.hidden)
        .lumenScreenBackground()
        .navigationTitle("Library")
        .toolbar { toolbar }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            Task { await importFiles(result) }
        }
        .alert("New collection", isPresented: $isNamingCollection) {
            TextField("Name", text: $newCollectionName)
            Button("Create") {
                let name = newCollectionName
                newCollectionName = ""
                Task { await library.createCollection(named: name) }
            }
            Button("Cancel", role: .cancel) { newCollectionName = "" }
        }
        .task { await library.start() }
        .refreshable { await library.load() }
    }

    private var filters: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: LumenSpace.s) {
                    filterChip("All", .all)
                    filterChip("Pinned", .pinned)
                    ForEach(library.tags.prefix(8)) { usage in
                        filterChip("#\(usage.tag)", .tag(usage.tag))
                    }
                    filterChip("Archived", .archived)
                }
                .padding(.vertical, LumenSpace.xs)
            }
            .listRowInsets(EdgeInsets(top: 0, leading: LumenSpace.l, bottom: 0, trailing: LumenSpace.l))
            .listRowBackground(Color.clear)
        }
    }

    private func filterChip(_ title: String, _ filter: LibraryViewModel.Filter) -> some View {
        Button { library.filter = filter } label: {
            Chip(title, isProminent: library.filter == filter)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(library.filter == filter ? .isSelected : [])
    }

    @ViewBuilder
    private var notesSection: some View {
        Section("Notes") {
            switch library.notes {
            case .idle, .loading:
                SkeletonRows(count: 3)
            case .failed(let error):
                Text(error.message).foregroundStyle(LumenColor.danger)
            case .loaded(let notes) where notes.isEmpty:
                Text("No notes here yet. Notes support Markdown, [[links]] between notes and #tags.")
                    .lumenText(.subheadline)
                    .foregroundStyle(LumenColor.textSecondary)
            case .loaded(let notes):
                ForEach(notes) { note in
                    NavigationLink(value: AppDestination.entity(note.reference)) {
                        NoteRow(note: note)
                    }
                    .swipeActions(edge: .leading) {
                        Button { Task { await library.togglePin(note) } } label: {
                            Label(note.isPinned ? "Unpin" : "Pin", systemImage: note.isPinned ? "pin.slash" : "pin")
                        }
                        .tint(LumenColor.accentFill)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { Task { await library.delete(note) } } label: { Label("Delete", systemImage: "trash") }
                        Button { Task { await library.setArchived(!note.isArchived, note) } } label: {
                            Label(note.isArchived ? "Unarchive" : "Archive", systemImage: "archivebox")
                        }
                    }
                }
            }
        }
    }

    private var collectionsSection: some View {
        Section("Collections") {
            ForEach(library.collections.flatMap(\.flattened)) { node in
                Button {
                    library.filter = .collection(node.collection.id)
                } label: {
                    Label(node.collection.name, systemImage: node.collection.symbolName ?? "folder")
                        .padding(.leading, CGFloat(node.depth) * LumenSpace.l)
                        .foregroundStyle(library.filter == .collection(node.collection.id) ? LumenColor.accentText : LumenColor.textPrimary)
                }
            }
        }
    }

    private var documentsSection: some View {
        Section("Documents") {
            ForEach(library.documents) { document in
                NavigationLink(value: AppDestination.entity(document.reference)) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(document.title).lumenText(.body)
                            Text(ByteCountFormatter.string(fromByteCount: document.byteCount, countStyle: .file))
                                .lumenText(.caption)
                                .foregroundStyle(LumenColor.textSecondary)
                        }
                    } icon: {
                        IconBadge("doc")
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("New collection", systemImage: "folder.badge.plus") { isNamingCollection = true }
                Button("Import files", systemImage: "square.and.arrow.down") { isImporting = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                Task {
                    if let note = await library.createNote() {
                        model.router.push(.entity(note.reference))
                    }
                }
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .accessibilityLabel("New note")
        }
    }

    private func importFiles(_ result: Result<[URL], any Error>) async {
        guard case .success(let urls) = result else { return }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let type = UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.data.identifier
                _ = await library.importDocument(data: data, fileName: url.lastPathComponent, contentType: type)
            } catch {
                services.errors.report(error, context: "Reading \(url.lastPathComponent)")
            }
        }
    }
}

private struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: LumenSpace.xxs) {
            HStack(spacing: LumenSpace.xs) {
                if note.isPinned {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(LumenColor.accent)
                }
                Text(note.title.isEmpty ? "Untitled note" : note.title)
                    .lumenText(.body)
                    .foregroundStyle(LumenColor.textPrimary)
                    .lineLimit(1)
            }
            if !note.excerpt.isEmpty {
                Text(note.excerpt)
                    .lumenText(.caption)
                    .foregroundStyle(LumenColor.textSecondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, LumenSpace.xxs)
    }
}

