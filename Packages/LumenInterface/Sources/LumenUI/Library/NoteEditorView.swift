import SwiftUI
import QuickLook
import LumenCore
import LumenFoundation
import LumenDesignSystem
import LumenPresentation
import LumenApplication
import LumenKnowledge

/// Writing a note: edit or read mode, autosaved, with backlinks and history.
struct NoteEditorView: View {
    let services: LumenServices
    let model: AppModel
    @State private var editor: NoteEditorViewModel
    @State private var isReading = false
    @State private var showsHistory = false
    @FocusState private var focus: Field?

    private enum Field { case title, body }

    init(noteID: Note.ID, services: LumenServices, model: AppModel) {
        self.services = services
        self.model = model
        _editor = State(initialValue: NoteEditorViewModel(noteID: noteID, services: services))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LumenSpace.l) {
                TextField("Title", text: $editor.title, axis: .vertical)
                    .lumenText(.display)
                    .focused($focus, equals: .title)
                    .submitLabel(.next)
                    .onSubmit { focus = .body }
                if isReading {
                    MarkdownView(structure: editor.structure) { editor.toggleCheckbox(at: $0) }
                } else {
                    TextEditor(text: $editor.body)
                        .lumenText(.body)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 320)
                        .focused($focus, equals: .body)
                        .accessibilityLabel("Note text")
                }
                footer
                if !editor.backlinks.isEmpty { backlinks }
            }
            .padding(.horizontal, LumenSpace.screen)
            .padding(.vertical, LumenSpace.l)
            .frame(maxWidth: LumenLayout.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .lumenScreenBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation(.lumenSmooth) { isReading.toggle() }
                } label: {
                    Image(systemName: isReading ? "pencil" : "book")
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel(isReading ? "Edit" : "Read")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Version history", systemImage: "clock.arrow.circlepath") { showsHistory = true }
                    ShareLink(item: "# \(editor.title)\n\n\(editor.body)")
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showsHistory) {
            NavigationStack { VersionHistoryView(editor: editor) }
        }
        .task {
            await editor.load()
            if editor.title.isEmpty { focus = .title }
        }
        .onDisappear { Task { await editor.saveNow() } }
    }

    private var footer: some View {
        HStack(spacing: LumenSpace.m) {
            Text("\(editor.structure.wordCount) words")
            if editor.structure.readingTimeMinutes > 0 {
                Text("\(editor.structure.readingTimeMinutes) min read")
            }
            Spacer()
            if editor.isSaving {
                ProgressView().controlSize(.mini)
            } else if editor.lastSaved != nil {
                Label("Saved", systemImage: "checkmark").labelStyle(.titleAndIcon)
            }
        }
        .lumenText(.caption)
        .foregroundStyle(LumenColor.textTertiary)
    }

    private var backlinks: some View {
        VStack(alignment: .leading, spacing: LumenSpace.s) {
            SectionHeader("Linked from")
            ForEach(editor.backlinks) { note in
                Button {
                    model.router.push(.entity(note.reference))
                } label: {
                    Label(note.title.isEmpty ? "Untitled note" : note.title, systemImage: "arrow.turn.up.left")
                        .lumenText(.subheadline)
                }
                .buttonStyle(.lumenQuiet)
            }
        }
    }
}

/// Earlier versions of a note, with restore.
private struct VersionHistoryView: View {
    let editor: NoteEditorViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if editor.versions.isEmpty {
                Text("Versions are saved as you write.").foregroundStyle(LumenColor.textSecondary)
            }
            ForEach(editor.versions.reversed()) { version in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(version.savedAt, style: .date).lumenText(.body)
                        Text(version.savedAt, style: .time).lumenText(.caption).foregroundStyle(LumenColor.textSecondary)
                    }
                    Spacer()
                    Button("Restore") {
                        Task {
                            await editor.restore(version)
                            dismiss()
                        }
                    }
                    .buttonStyle(.lumenQuiet)
                }
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }
}

/// An imported document's details and contents, with a QuickLook preview of the file.
struct DocumentDetailView: View {
    @State private var detail: DocumentDetailViewModel

    init(documentID: DocumentItem.ID, services: LumenServices) {
        _detail = State(initialValue: DocumentDetailViewModel(documentID: documentID, services: services))
    }

    var body: some View {
        List {
            switch detail.state {
            case .idle, .loading:
                SkeletonRows(count: 3)
            case .failed(let error):
                StateMessage(error.title, message: error.message, symbolName: "doc.questionmark", actionTitle: "Try again") {
                    Task { await detail.load() }
                }
            case .loaded(let document):
                Section {
                    LabeledContent("Name", value: document.originalFileName)
                    LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: document.byteCount, countStyle: .file))
                    LabeledContent("Added") { Text(document.createdAt, style: .date) }
                    if let fileURL = detail.fileURL {
                        Button { detail.preview() } label: { Label("Preview", systemImage: "eye") }
                        ShareLink(item: fileURL) { Label("Share file", systemImage: "square.and.arrow.up") }
                    } else {
                        Label("This document's file isn't on this device.", systemImage: "icloud.slash")
                            .lumenText(.footnote)
                            .foregroundStyle(LumenColor.textSecondary)
                    }
                }
                if let text = document.extractedText, !text.isEmpty {
                    Section("Contents") {
                        Text(text.truncated(to: 20_000))
                            .lumenText(.body)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .lumenScreenBackground()
        .navigationTitle(detail.state.value?.title ?? "Document")
        .navigationBarTitleDisplayMode(.inline)
        .quickLookPreview($detail.previewURL)
        .task { await detail.start() }
    }
}
