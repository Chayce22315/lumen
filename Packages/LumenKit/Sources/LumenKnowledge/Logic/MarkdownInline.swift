import Foundation
import LumenFoundation

/// Removes inline Markdown syntax from block text.
///
/// - `*em*`, `**strong**`, `_em_`, `__strong__`, `~~strike~~`: matched delimiter runs are removed;
///   unmatched ones and intraword underscores (`snake_case`) stay literal.
/// - `` `code` `` keeps its content; `[text](url)` and `![alt](url)` keep the text; `<https://…>`
///   keeps the address.
/// - `[[Title|alias]]` becomes the alias, `[[Title]]` the title; entity mentions without an alias
///   (`[[task:<UUID>]]`) are dropped because their title is not known here.
/// - Backslash escapes produce the escaped character.
enum MarkdownInline {
    /// How far to look for a closing bracket or backtick run, bounding work on pathological input.
    private static let searchWindow = 4_000

    private enum Piece {
        case literal(Character)
        case delimiter(character: Character, count: Int, canOpen: Bool, canClose: Bool)
    }

    static func plainText(_ text: String) -> String {
        plainText(Array(text))
    }

    private static func plainText(_ characters: [Character]) -> String {
        var pieces: [Piece] = []
        pieces.reserveCapacity(characters.count)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "\\":
                if index + 1 < characters.count, isEscapable(characters[index + 1]) {
                    pieces.append(.literal(characters[index + 1]))
                    index += 2
                } else {
                    pieces.append(.literal(character))
                    index += 1
                }
            case "`":
                let run = runLength(of: "`", in: characters, from: index)
                if let close = closingBacktickRun(length: run, in: characters, from: index + run) {
                    var content = Array(characters[(index + run)..<close])
                    if content.count >= 2, content.first == " ", content.last == " ", content.contains(where: { $0 != " " }) {
                        content = Array(content.dropFirst().dropLast())
                    }
                    pieces.append(contentsOf: content.map(Piece.literal))
                    index = close + run
                } else {
                    pieces.append(contentsOf: Array(repeating: Piece.literal("`"), count: run))
                    index += run
                }
            case "!" where index + 1 < characters.count && characters[index + 1] == "[":
                if let link = inlineLink(in: characters, at: index + 1) {
                    pieces.append(contentsOf: link.text.map(Piece.literal))
                    index = link.end
                } else {
                    pieces.append(.literal(character))
                    index += 1
                }
            case "[":
                if let wiki = wikiLink(in: characters, at: index) {
                    pieces.append(contentsOf: wiki.text.map(Piece.literal))
                    index = wiki.end
                } else if let link = inlineLink(in: characters, at: index) {
                    pieces.append(contentsOf: link.text.map(Piece.literal))
                    index = link.end
                } else {
                    pieces.append(.literal(character))
                    index += 1
                }
            case "<":
                if let autolink = autolink(in: characters, at: index) {
                    pieces.append(contentsOf: autolink.text.map(Piece.literal))
                    index = autolink.end
                } else {
                    pieces.append(.literal(character))
                    index += 1
                }
            case "*", "_", "~":
                let run = runLength(of: character, in: characters, from: index)
                let previous: Character? = index > 0 ? characters[index - 1] : nil
                let next: Character? = index + run < characters.count ? characters[index + run] : nil
                var canOpen = next.map { !$0.isWhitespace } ?? false
                var canClose = previous.map { !$0.isWhitespace } ?? false
                if character == "_" {
                    canOpen = canOpen && !(previous.map(isAlphanumeric) ?? false)
                    canClose = canClose && !(next.map(isAlphanumeric) ?? false)
                }
                pieces.append(.delimiter(character: character, count: run, canOpen: canOpen, canClose: canClose))
                index += run
            default:
                pieces.append(.literal(character))
                index += 1
            }
        }
        return render(pieces)
    }

    /// Removes matched delimiter pairs and renders the rest.
    private static func render(_ pieces: [Piece]) -> String {
        var removed = Set<Int>()
        var openers: [Int] = []
        for (position, piece) in pieces.enumerated() {
            guard case .delimiter(let character, let count, let canOpen, let canClose) = piece else { continue }
            var matched = false
            if canClose {
                if let stackIndex = openers.lastIndex(where: { opener in
                    if case .delimiter(let openCharacter, let openCount, _, _) = pieces[opener] {
                        return openCharacter == character && openCount == count
                    }
                    return false
                }) {
                    removed.insert(openers[stackIndex])
                    removed.insert(position)
                    openers.removeSubrange(stackIndex...)
                    matched = true
                }
            }
            if !matched && canOpen {
                openers.append(position)
            }
        }
        var output = ""
        output.reserveCapacity(pieces.count)
        for (position, piece) in pieces.enumerated() {
            switch piece {
            case .literal(let character):
                output.append(character)
            case .delimiter(let character, let count, _, _):
                if !removed.contains(position) {
                    output.append(String(repeating: character, count: count))
                }
            }
        }
        return output
    }

    // MARK: - Constructs

    private static func wikiLink(in characters: [Character], at start: Int) -> (text: String, end: Int)? {
        guard start + 1 < characters.count, characters[start + 1] == "[" else { return nil }
        var cursor = start + 2
        let limit = min(characters.count, start + searchWindow)
        while cursor + 1 < limit {
            let character = characters[cursor]
            if character == "[" || character.isNewline { return nil }
            if character == "]" {
                guard characters[cursor + 1] == "]" else { return nil }
                let content = String(characters[(start + 2)..<cursor])
                let parts = content.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                guard let target = parts.first.flatMap({ String($0).nonBlank }) else { return nil }
                let alias = parts.count > 1 ? String(parts[1]).nonBlank : nil
                let text: String
                if let alias {
                    text = alias
                } else if EntityReference(uri: target) != nil {
                    text = ""
                } else {
                    text = target
                }
                return (text, cursor + 2)
            }
            cursor += 1
        }
        return nil
    }

    /// `[text](destination)` starting at the `[`.
    private static func inlineLink(in characters: [Character], at start: Int) -> (text: String, end: Int)? {
        guard characters[start] == "[" else { return nil }
        let limit = min(characters.count, start + searchWindow)
        var depth = 0
        var cursor = start
        var textEnd: Int?
        while cursor < limit {
            let character = characters[cursor]
            if character == "\\" {
                cursor += 2
                continue
            }
            if character == "[" {
                depth += 1
            } else if character == "]" {
                depth -= 1
                if depth == 0 {
                    textEnd = cursor
                    break
                }
            }
            cursor += 1
        }
        guard let textEnd, textEnd + 1 < characters.count, characters[textEnd + 1] == "(" else { return nil }
        var parenthesisDepth = 0
        cursor = textEnd + 1
        while cursor < limit {
            let character = characters[cursor]
            if character == "\\" {
                cursor += 2
                continue
            }
            if character == "(" {
                parenthesisDepth += 1
            } else if character == ")" {
                parenthesisDepth -= 1
                if parenthesisDepth == 0 {
                    let label = plainText(Array(characters[(start + 1)..<textEnd]))
                    return (label, cursor + 1)
                }
            } else if character.isNewline {
                return nil
            }
            cursor += 1
        }
        return nil
    }

    /// `<scheme:address>` or `<name@example.com>`.
    private static func autolink(in characters: [Character], at start: Int) -> (text: String, end: Int)? {
        let limit = min(characters.count, start + searchWindow)
        var cursor = start + 1
        while cursor < limit {
            let character = characters[cursor]
            if character == ">" {
                let content = String(characters[(start + 1)..<cursor])
                guard content.contains(":") || content.contains("@") else { return nil }
                return (content, cursor + 1)
            }
            if character.isWhitespace || character == "<" { return nil }
            cursor += 1
        }
        return nil
    }

    // MARK: - Helpers

    private static func runLength(of character: Character, in characters: [Character], from start: Int) -> Int {
        var end = start
        while end < characters.count, characters[end] == character {
            end += 1
        }
        return end - start
    }

    private static func closingBacktickRun(length: Int, in characters: [Character], from start: Int) -> Int? {
        var cursor = start
        let limit = min(characters.count, start + searchWindow)
        while cursor < limit {
            if characters[cursor] == "`" {
                let run = runLength(of: "`", in: characters, from: cursor)
                if run == length { return cursor }
                cursor += run
            } else {
                cursor += 1
            }
        }
        return nil
    }

    private static func isEscapable(_ character: Character) -> Bool {
        character.isASCII && (character.isPunctuation || character.isSymbol)
    }

    private static func isAlphanumeric(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}
