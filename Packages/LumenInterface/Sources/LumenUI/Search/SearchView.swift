import SwiftUI
import LumenCore
import LumenFoundation
import LumenDesignSystem
import LumenPresentation
import LumenApplication
import LumenSearch

/// Universal search and command palette.
struct SearchView: View {
    let services: LumenServices
    let model: AppModel
    @State private var palette: CommandPaletteViewModel

    init(services: LumenServices, model: AppModel) {
        self.services = services
        self.model = model
        _palette = State(initialValue: CommandPaletteViewModel(services: services))
    }

    var body: some View {
        List {
            if let results = palette.results {
                if !results.history.isEmpty && palette.query.isEmpty {
                    Section("Recent") {
                        ForEach(results.history) { entry in
                            Button { palette.useHistory(entry) } label: {
                                Label(entry.query, systemImage: "clock.arrow.circlepath").foregroundStyle(LumenColor.textPrimary)
                            }
                            .swipeActions { Button("Remove", role: .destructive) { Task { await palette.removeHistory(entry) } } }
                        }
                    }
                }
                if !results.commands.isEmpty {
                    Section(palette.query.isEmpty ? "Suggested" : "Commands") {
                        ForEach(results.commands) { ranked in
                            Button {
                                Task { await model.runCommand(ranked.command.id) }
                            } label: {
                                HStack(spacing: LumenSpace.m) {
                                    IconBadge(ranked.command.symbolName)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HighlightedText(text: ranked.command.title, highlights: ranked.titleHighlights)
                                        if !ranked.command.subtitle.isEmpty {
                                            Text(ranked.command.subtitle).lumenText(.caption).foregroundStyle(LumenColor.textSecondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                if !results.results.isEmpty {
                    Section("Results") {
                        ForEach(results.results) { result in
                            Button { Task { await palette.open(result, router: model.router) } } label: {
                                ResultRow(result: result)
                            }
                        }
                    }
                } else if !palette.query.isEmpty && !palette.isSearching {
                    Section {
                        Text("No matches for “\(palette.query)”.").foregroundStyle(LumenColor.textSecondary)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .lumenScreenBackground()
        .navigationTitle("Search")
        .searchable(text: $palette.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Tasks, notes, commands…")
        .onSubmit(of: .search) { Task { await palette.remember() } }
        .task {
            if let pending = model.router.pendingSearchQuery {
                palette.query = pending
                model.router.pendingSearchQuery = nil
            }
            await palette.start()
        }
    }
}

private struct ResultRow: View {
    let result: SearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: LumenSpace.xxs) {
            HighlightedText(text: result.title, highlights: result.titleHighlights)
            if !result.subtitle.isEmpty {
                Text(result.subtitle).lumenText(.caption).foregroundStyle(LumenColor.textSecondary)
            }
            if let snippet = result.snippet {
                HighlightedText(text: snippet.text, highlights: snippet.highlights, role: .footnote, color: LumenColor.textSecondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, LumenSpace.xxs)
    }
}

/// Text with search matches emphasised.
struct HighlightedText: View {
    let text: String
    let highlights: [HighlightRange]
    var role: TextRoleValue = .body
    var color: Color = LumenColor.textPrimary

    enum TextRoleValue { case body, footnote }

    var body: some View {
        Text(attributed)
            .font(role == .body ? .lumen(.body) : .lumen(.footnote))
            .foregroundStyle(color)
    }

    private var attributed: AttributedString {
        var string = AttributedString(text)
        let count = text.count
        for range in highlights where range.offset >= 0 && range.length > 0 && range.offset + range.length <= count {
            let start = string.index(string.startIndex, offsetByCharacters: range.offset)
            let end = string.index(start, offsetByCharacters: range.length)
            string[start..<end].foregroundColor = LumenColor.accentText
            string[start..<end].font = role == .body ? Font.lumen(.bodyEmphasized) : Font.lumen(.footnote).weight(.semibold)
        }
        return string
    }
}
