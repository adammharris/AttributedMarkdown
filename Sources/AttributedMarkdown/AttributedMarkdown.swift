//
//  AttributedMarkdown.swift
//  AttributedMarkdown
//
//  Updated: compile fixes for attribute extraction & substring handling.
//
//  This file provides the public surface for converting an `AttributedString`
//  (produced by Apple's `AttributedString(markdown:)`) back into a Markdown string
//  for a defined, minimally supported subset.
//
//  Scope implemented (inline):
//  - Bold (**)
//  - Italic (*)
//  - Strikethrough (~~)
//  - Inline code (`code`)
//  - Links [text](url)
//  - Escaping of special characters in plain text
//
//  Not yet implemented (block-level):
//  - Headings (#, ##, ###)
//  - Ordered / unordered lists
//  - Paragraph separation / structural reconstruction
//
//  Determinism:
//  - Wrapper order (outer → inner): ~~ , ** , *
//  - Code spans override other inline decorations.
//
//  NOTE: Some Foundation attribute symbols differ across toolchains. This
//  implementation uses conditional compilation & defensive lookups to
//  avoid hard failures when certain attribute keys are absent.
//
//  Escaping:
//  - Escapes \ * _ [ ] ( ) ` ~ in plain text segments.
//
//  Future enhancements: run coalescing, block structure, smarter escaping.
//
import Foundation

extension AttributedString {
    public func toMarkdown() -> String {
        // Uses the unified AST-based serializer for full inline + block-level (headings, lists,
        // block quotes, code fences) round-trip support.
        return self.toMarkdownViaAST()
    }
}

// MARK: - Internal Serializer

private enum MarkdownSerializer {

    static func serialize(_ attributed: AttributedString) -> String {
        var result = String()
        result.reserveCapacity(attributed.characters.count + attributed.characters.count / 4)

        // Bridge once to NSAttributedString for attribute keys like (strike) that
        // are not (consistently) exposed via the Swift attribute scopes across
        // all toolchains.
        let ns = NSAttributedString(attributed)
        var utf16Offset = 0

        // Stack-based wrapper diffing to avoid redundant markers across runs.
        enum Wrapper: String, CaseIterable {
            case strike = "~~"
            case bold = "**"
            case italic = "*"
        }

        func desiredWrappers(for attrs: InlineAttributes) -> [Wrapper] {
            // Deterministic outer → inner ordering.
            var list: [Wrapper] = []
            if attrs.isStrikethrough { list.append(.strike) }
            if attrs.isBold { list.append(.bold) }
            if attrs.isItalic { list.append(.italic) }
            return list
        }

        var open: [Wrapper] = []
        var pendingPlain = String()

        for run in attributed.runs {
            if !pendingPlain.isEmpty {
                result.append(escapePlain(pendingPlain))
                pendingPlain.removeAll(keepingCapacity: true)
            }

            let slice = attributed[run.range]
            var buffer = String()
            buffer.reserveCapacity(slice.characters.count)
            for ch in slice.characters { buffer.append(ch) }
            guard !buffer.isEmpty else { continue }

            let inline = InlineAttributes(
                from: run,
                slice: slice,
                ns: ns,
                utf16Location: utf16Offset
            )

            if inline.isCode {
                if !open.isEmpty {
                    for w in open.reversed() { result.append(w.rawValue) }
                    open.removeAll()
                }
                let codeText = wrapCode(buffer)
                if let link = inline.link {
                    result.append("[\(codeText)](\(escapeLinkDestination(link)))")
                } else {
                    result.append(codeText)
                }
                utf16Offset += buffer.utf16.count
                continue
            }

            let desired = desiredWrappers(for: inline)

            let (leadingSpaces, coreText, trailingSpaces) = splitTrimmableEdges(from: buffer)

            if coreText.isEmpty {
                pendingPlain.append(buffer)
                utf16Offset += buffer.utf16.count
                continue
            }

            if !leadingSpaces.isEmpty {
                result.append(escapePlain(leadingSpaces))
            }

            if let link = inline.link {
                if !open.isEmpty {
                    for w in open.reversed() { result.append(w.rawValue) }
                    open.removeAll()
                }
                var inner = escapePlain(coreText)
                for w in desired.reversed() {
                    let token = w.rawValue
                    inner = "\(token)\(inner)\(token)"
                }
                result.append("[\(inner)](\(escapeLinkDestination(link)))")
                pendingPlain.append(trailingSpaces)
                utf16Offset += buffer.utf16.count
                continue
            }

            var i = 0
            while i < open.count && i < desired.count && open[i] == desired[i] {
                i += 1
            }
            if i < open.count {
                for w in open[i...].reversed() {
                    result.append(w.rawValue)
                }
                open.removeLast(open.count - i)
            }
            if i < desired.count {
                for w in desired[i...] {
                    result.append(w.rawValue)
                    open.append(w)
                }
            }

            result.append(escapePlain(coreText))
            if trailingSpaces.contains("\n"), !open.isEmpty {
                for ch in trailingSpaces {
                    if ch == "\n" {
                        for w in open.reversed() { result.append(w.rawValue) }
                        open.removeAll()
                        result.append("\n")
                        continue
                    }
                    pendingPlain.append(ch)
                }
            } else {
                pendingPlain.append(trailingSpaces)
            }
            utf16Offset += buffer.utf16.count
        }

        // Close any remaining wrappers.
        if !open.isEmpty {
            for w in open.reversed() { result.append(w.rawValue) }
            open.removeAll()
        }

        if !pendingPlain.isEmpty {
            result.append(escapePlain(pendingPlain))
        }

        return result
    }

    // (Previous emitInline removed in favor of stack-based diffing inside serialize)

    // MARK: Escaping

    private static func escapePlain(_ text: String) -> String {
        var out = String()
        out.reserveCapacity(text.count)
        for ch in text {
            switch ch {
            case "*", "_", "[", "]", "(", ")", "`", "~":
                out.append("\\\(ch)")
            case "\\":
                out.append("\\\\")
            default:
                out.append(ch)
            }
        }
        return out
    }

    private static func splitTrimmableEdges(from text: String) -> (leading: String, core: String, trailing: String) {
        guard !text.isEmpty else { return ("", "", "") }

        var start = text.startIndex
        var end = text.endIndex

        while start < end, isTrimmable(text[start]) {
            start = text.index(after: start)
        }

        while end > start, isTrimmable(text[text.index(before: end)]) {
            end = text.index(before: end)
        }

        let leading = String(text[..<start])
        let core = String(text[start..<end])
        let trailing = String(text[end...])
        return (leading, core, trailing)
    }

    private static func isTrimmable(_ character: Character) -> Bool {
        character == " " || character == "\t"
    }

    // Choose code fence length based on longest backtick run.
    private static func wrapCode(_ text: String) -> String {
        let maxSequential = longestBacktickRun(in: text)
        let fence = String(repeating: "`", count: maxSequential + 1)
        return fence + text + fence
    }

    private static func longestBacktickRun(in text: String) -> Int {
        var current = 0
        var longest = 0
        for ch in text {
            if ch == "`" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }

    private static func escapeLinkDestination(_ url: URL) -> String {
        let raw = url.absoluteString
        var out = String()
        out.reserveCapacity(raw.count)
        for ch in raw {
            switch ch {
            case " ", "(", ")", "[", "]":
                out.append("\\\(ch)")
            default:
                out.append(ch)
            }
        }
        return out
    }

    // MARK: Attribute Extraction

    private struct InlineAttributes {
        let isBold: Bool
        let isItalic: Bool
        let isStrikethrough: Bool
        let isCode: Bool
        let link: URL?

        init(
            from run: AttributedString.Runs.Run,
            slice: AttributedSubstring,
            ns: NSAttributedString,
            utf16Location: Int
        ) {

            // Inline presentation intent (bold / italic / code).
            var bold = false
            var italic = false
            var code = false

            if let inlineIntent = run[inlinePresentationKey] {
                if inlineIntent.contains(.stronglyEmphasized) { bold = true }
                if inlineIntent.contains(.emphasized) { italic = true }
                if inlineIntent.contains(.code) { code = true }
            }

            // Link
            var detectedLink: URL? = run[linkKey]

            // Strikethrough detection: inspect attributes at the starting UTF16 location.
            var strike = false
            if utf16Location < ns.length {
                let attrs = ns.attributes(at: utf16Location, effectiveRange: nil)

                // Platform key if available.
                #if canImport(AppKit) || canImport(UIKit)
                    if let v = attrs[NSAttributedString.Key("NSStrikethroughStyle")]
                        ?? attrs[NSAttributedString.Key("NSStrikethrough")]
                    {
                        if let num = v as? NSNumber, num.intValue != 0 {
                            strike = true
                        } else if let intVal = v as? Int, intVal != 0 {
                            strike = true
                        }
                    }
                #endif

                // Fallback dynamic key names (varies by environment).
                if !strike {
                    for keyName in [
                        "NSStrikethrough",
                        "NSStrikethroughStyle",
                        "NSUnderlineStrikethroughStyle",
                        "NSStrikethroughStyleAttributeName",
                    ] {
                        let k = NSAttributedString.Key(keyName)
                        if let value = attrs[k] {
                            if let num = value as? NSNumber, num.intValue != 0 {
                                strike = true
                                break
                            } else if let intVal = value as? Int, intVal != 0 {
                                strike = true
                                break
                            }
                        }
                    }
                }
            }

            // Code suppresses other inline wrappers & links.
            if code {
                bold = false
                italic = false
                strike = false
                detectedLink = nil
            }

            self.isBold = bold
            self.isItalic = italic
            self.isStrikethrough = strike
            self.isCode = code
            self.link = detectedLink
        }
    }

    // MARK: Attribute Keys (lazily referenced to avoid unknown symbol failures)

    private static var inlinePresentationKey:
        AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.Type
    {
        AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self
    }

    private static var linkKey: AttributeScopes.FoundationAttributes.LinkAttribute.Type {
        AttributeScopes.FoundationAttributes.LinkAttribute.self
    }

    // Raw key for strikethrough (equivalent to NSAttributedString.Key.strikethroughStyle)
    private static let strikeKey = NSAttributedString.Key("NSStrikethrough")
}

// MARK: - Future Extension Points
//
// 1. Structural pass for block-level intents (headings, lists).
// 2. Run coalescing for minimal marker emission.
// 3. Smarter context-aware escaping.
// 4. Fenced code blocks (multiline) & blockquotes.
// 5. Performance tuning (single allocation builders).
//
