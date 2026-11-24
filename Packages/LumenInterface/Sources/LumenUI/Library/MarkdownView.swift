import SwiftUI
import LumenFoundation
import LumenCore
import LumenDesignSystem
import LumenKnowledge

/// Renders Markdown blocks parsed by the knowledge engine. Inline styling (bold, italics, code,
/// links) uses the system's Markdown attributed strings.
struct MarkdownView: View {
    let structure: MarkdownStructure
    let onToggleCheckbox: (Int) -> Void

    var body: some View {
        let checkboxes = checkboxIndices
        VStack(alignment: .leading, spacing: LumenSpace.m) {
            ForEach(Array(structure.blocks.enumerated()), id: \.offset) { offset, block in
                BlockView(block: block, checkboxIndex: checkboxes[offset], onToggle: onToggleCheckbox)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Block offset → position among all checkboxes (the index the toggle function expects).
    private var checkboxIndices: [Int: Int] {
        var result: [Int: Int] = [:]
        var next = 0
        for (offset, block) in structure.blocks.enumerated() {
            if case .listItem(_, _, _, _, .some) = block {
                result[offset] = next
                next += 1
            }
        }
        return result
    }
}

private struct BlockView: View {
    let block: MarkdownBlock
    let checkboxIndex: Int?
    let onToggle: (Int) -> Void

    var body: some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .lumenText(level <= 1 ? .title : (level == 2 ? .headline : .bodyEmphasized))
                .padding(.top, level <= 2 ? LumenSpace.s : 0)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            inline(text).lumenText(.body)
        case .listItem(let ordered, let number, let depth, let text, let checkbox):
            HStack(alignment: .firstTextBaseline, spacing: LumenSpace.s) {
                if let checkbox {
                    Button {
                        if let checkboxIndex { onToggle(checkboxIndex) }
                    } label: {
                        Image(systemName: checkbox == .checked ? "checkmark.square.fill" : "square")
                            .foregroundStyle(checkbox == .checked ? LumenColor.accent : LumenColor.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(checkbox == .checked ? "Checked" : "Unchecked")
                } else {
                    Text(ordered ? "\(number ?? 1)." : "•").foregroundStyle(LumenColor.textSecondary)
                }
                inline(text)
                    .lumenText(.body)
                    .strikethrough(checkbox == .checked, color: LumenColor.textTertiary)
                    .foregroundStyle(checkbox == .checked ? LumenColor.textTertiary : LumenColor.textPrimary)
            }
            .padding(.leading, CGFloat(depth) * LumenSpace.l)
        case .blockquote(let text):
            HStack(spacing: LumenSpace.m) {
                Rectangle().fill(LumenColor.accent).frame(width: 3)
                inline(text).lumenText(.body).foregroundStyle(LumenColor.textSecondary)
            }
        case .codeBlock(_, let code):
            ScrollView(.horizontal) {
                Text(code)
                    .lumenText(.monospaced)
                    .padding(LumenSpace.m)
            }
            .background(LumenColor.surfaceHighlight.opacity(0.5), in: RoundedRectangle(cornerRadius: LumenRadius.small))
        case .thematicBreak:
            HairlineDivider()
        }
    }

    private func inline(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(text)
    }
}
