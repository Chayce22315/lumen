import Foundation
import LumenFoundation

/// Finds `[[links]]` and `#hashtags` in Markdown.
///
/// Rules:
/// - `[[Title]]` and `[[Title|alias]]` link by title. When the part before `|` parses as an
///   `EntityReference` URI (`task:<UUID>`, `note:<UUID>`, any `kind:<UUID>`), the link is an entity
///   mention instead. A link lies on one line, its target is non-empty and it contains no `[` or `]`.
/// - A hashtag is `#` followed by letters, digits, `-` and `_`, containing at least one letter. The
///   `#` must start the line or follow whitespace or one of `( [ { * _ ~ " '` (not a link
///   destination such as `](#anchor)`), so headings (`# Title`), URLs fragments, `C#` and `#1` are
///   not tags.
/// - Nothing inside fenced code blocks (```` ``` ```` / `~~~`) or inline code spans counts, and a
///   backslash escapes `[[`.
///
/// Results are in source order; ranges index into the parsed string.
public enum WikiLinkParser {
    public static func parse(_ text: String) -> ParsedLinks {
        var result = ParsedLinks()
        let lines = MarkdownSource.lines(of: text)
        let fenced = MarkdownSource.fencedLineMask(lines)
        for (lineIndex, line) in lines.enumerated() where !fenced[lineIndex] {
            scan(line.text, into: &result)
        }
        return result
    }

    public static func links(in text: String) -> [WikiLinkMatch] {
        parse(text).links
    }

    public static func hashtags(in text: String) -> [HashtagMatch] {
        parse(text).hashtags
    }

    public static func isHashtagCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == "_"
    }

    private static let hashtagPrefixes: Set<Character> = ["(", "[", "{", "*", "_", "~", "\"", "'"]

    // MARK: - Scanning

    private static func scan(_ line: Substring, into result: inout ParsedLinks) {
        let spans = MarkdownSource.codeSpans(in: line)
        var nextSpan = 0
        var index = line.startIndex
        while index < line.endIndex {
            if nextSpan < spans.count, index >= spans[nextSpan].lowerBound {
                if index < spans[nextSpan].upperBound {
                    index = spans[nextSpan].upperBound
                }
                nextSpan += 1
                continue
            }
            let character = line[index]
            if character == "[", let link = wikiLink(at: index, in: line, codeSpans: spans) {
                result.links.append(link)
                index = link.range.upperBound
                continue
            }
            if character == "#", let hashtag = hashtag(at: index, in: line) {
                result.hashtags.append(hashtag)
                index = hashtag.range.upperBound
                continue
            }
            index = line.index(after: index)
        }
    }

    private static func wikiLink(at start: Substring.Index, in line: Substring, codeSpans: [Range<String.Index>]) -> WikiLinkMatch? {
        let second = line.index(after: start)
        guard second < line.endIndex, line[second] == "[", !MarkdownSource.isEscaped(start, in: line) else { return nil }
        let contentStart = line.index(after: second)
        var cursor = contentStart
        var contentEnd: Substring.Index?
        while cursor < line.endIndex {
            let character = line[cursor]
            if character == "[" { return nil }
            if character == "]" {
                let next = line.index(after: cursor)
                guard next < line.endIndex, line[next] == "]" else { return nil }
                contentEnd = cursor
                break
            }
            cursor = line.index(after: cursor)
        }
        guard let contentEnd else { return nil }
        // A code span starting inside the brackets means the brackets are not a link.
        if codeSpans.contains(where: { $0.lowerBound >= contentStart && $0.lowerBound < contentEnd }) {
            return nil
        }
        let end = line.index(contentEnd, offsetBy: 2)
        let content = line[contentStart..<contentEnd]
        let targetPart: Substring
        let aliasPart: Substring?
        if let bar = content.firstIndex(of: "|") {
            targetPart = content[content.startIndex..<bar]
            aliasPart = content[content.index(after: bar)...]
        } else {
            targetPart = content
            aliasPart = nil
        }
        guard let targetText = String(targetPart).nonBlank else { return nil }
        let target: WikiLinkMatch.Target
        if let reference = EntityReference(uri: targetText) {
            target = .entity(reference)
        } else {
            target = .title(targetText)
        }
        return WikiLinkMatch(
            target: target,
            alias: aliasPart.flatMap { String($0).nonBlank },
            range: start..<end,
            rawText: String(line[start..<end])
        )
    }

    private static func hashtag(at start: Substring.Index, in line: Substring) -> HashtagMatch? {
        if start > line.startIndex {
            let previousIndex = line.index(before: start)
            let previous = line[previousIndex]
            guard previous.isWhitespace || hashtagPrefixes.contains(previous) else { return nil }
            // `](#anchor)` is a link destination, not a tag.
            if previous == "(", previousIndex > line.startIndex, line[line.index(before: previousIndex)] == "]" {
                return nil
            }
        }
        let tagStart = line.index(after: start)
        let tagEnd = line[tagStart...].firstIndex(where: { !isHashtagCharacter($0) }) ?? line.endIndex
        let tag = line[tagStart..<tagEnd]
        guard !tag.isEmpty, tag.contains(where: \.isLetter), let normalized = TagNormalizer.normalize(String(tag)) else {
            return nil
        }
        return HashtagMatch(tag: String(tag), normalized: normalized, range: start..<tagEnd)
    }
}
