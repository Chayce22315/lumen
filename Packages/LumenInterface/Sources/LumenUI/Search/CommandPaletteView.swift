import SwiftUI
import LumenCore
import LumenFoundation
import LumenDesignSystem
import LumenPresentation
import LumenApplication
import LumenSearch

/// The command palette (⌘K): one field, with commands, content and recent queries below, made for
/// the keyboard. ↑ and ↓ move the highlighted row, Return opens it, Esc closes the palette.
struct CommandPaletteView: View {
    let services: LumenServices
    let model: AppModel
    @State private var palette: CommandPaletteViewModel
    @FocusState private var fieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(services: LumenServices, model: AppModel) {
        self.services = services
        self.model = model
        _palette = State(initialValue: CommandPaletteViewModel(services: services))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                field
                HairlineDivider()
                rows
            }
            .lumenScreenBackground()
            .navigationTitle("Command Palette")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { model.router.dismissCommandPalette() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .task {
            fieldFocused = true
            await palette.start()
        }
    }

    private var field: some View {
        HStack(spacing: LumenSpace.s) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(LumenColor.textTertiary)
                .accessibilityHidden(true)
            TextField("Search or run a command", text: $palette.query)
                .lumenText(.body)
                .foregroundStyle(LumenColor.textPrimary)
                .focused($fieldFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit { openHighlighted() }
                .onKeyPress(.downArrow) {
                    palette.moveHighlight(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    palette.moveHighlight(by: -1)
                    return .handled
                }
                .accessibilityIdentifier("palette.field")
                .accessibilityHint("Up and down arrows choose a row; Return opens it.")
        }
        .padding(.horizontal, LumenSpace.l)
        .padding(.vertical, LumenSpace.m)
    }

    @ViewBuilder
    private var rows: some View {
        let sections = palette.sections
        if sections.isEmpty && palette.results != nil && !palette.query.isEmpty && !palette.isSearching {
            ContentUnavailableView.search(text: palette.query)
        } else {
            ScrollViewReader { proxy in
                List {
                    ForEach(sections) { section in
                        Section(section.title) {
                            ForEach(section.items) { item in
                                row(item)
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .onChange(of: palette.highlightedID) { _, id in
                    guard let id else { return }
                    // Keep the highlighted row on screen as the arrows move it.
                    withLumenAnimation(.lumenSnappy, reduceMotion: reduceMotion) { proxy.scrollTo(id) }
                }
            }
        }
    }

    private func row(_ item: PaletteItem) -> some View {
        let isHighlighted = palette.highlightedID == item.id
        return Button {
            open(item)
        } label: {
            label(for: item)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .listRowBackground(isHighlighted ? LumenColor.accentSubtle : LumenColor.surface)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
        .id(item.id)
    }

    @ViewBuilder
    private func label(for item: PaletteItem) -> some View {
        switch item {
        case .history(let entry):
            Label(entry.query, systemImage: "clock.arrow.circlepath")
                .lumenText(.body)
                .foregroundStyle(LumenColor.textPrimary)
                .accessibilityLabel("Recent search, \(entry.query)")
        case .command(let ranked):
            HStack(spacing: LumenSpace.m) {
                IconBadge(ranked.command.symbolName)
                VStack(alignment: .leading, spacing: 2) {
                    HighlightedText(text: ranked.command.title, highlights: ranked.titleHighlights)
                    if !ranked.command.subtitle.isEmpty {
                        Text(ranked.command.subtitle).lumenText(.caption).foregroundStyle(LumenColor.textSecondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        case .result(let result):
            ResultRow(result: result)
                .accessibilityElement(children: .combine)
        }
    }

    private func open(_ item: PaletteItem) {
        palette.highlight(item)
        Task {
            await palette.activate(item, in: model)
            // A recent query stays in the palette, back in the field.
            fieldFocused = true
        }
    }

    private func openHighlighted() {
        Task {
            await palette.activateHighlighted(in: model)
            fieldFocused = true
        }
    }
}
