import Foundation
import Markdown

// MARK: - Shared Block Metadata Types (must appear before attribute declarations)

/// Metadata for list items (applied per run that belongs to a single list item).
/// `ordinal` is 1-based for ordered lists; for unordered lists it's the sequential
/// item index (used only for deterministic ordering when re‑emitting).
public struct ListMetadata: Hashable, Codable {
    public enum Kind: String, Codable, Hashable {
        case unordered
        case ordered
    }
    public let kind: Kind
    public let ordinal: Int
}

// MARK: - Custom Inline Attribute Scope (Bold / Italic / Code / Strikethrough)

extension AttributeScopes {

    /// Attribute scope for AttributedMarkdown custom inline markers.
    public struct AMInlineAttributes: AttributeScope {
        public let bold: BoldAttribute
        public let italic: ItalicAttribute
        public let code: CodeAttribute
        public let strike: StrikethroughAttribute
        public let heading: HeadingLevelAttribute
        public let listItem: ListItemAttribute

        public struct BoldAttribute: AttributedStringKey {
            public static let name = "am.bold"
            public typealias Value = Bool
        }
        public struct ItalicAttribute: AttributedStringKey {
            public static let name = "am.italic"
            public typealias Value = Bool
        }
        public struct CodeAttribute: AttributedStringKey {
            public static let name = "am.code"
            public typealias Value = Bool
        }
        public struct StrikethroughAttribute: AttributedStringKey {
            public static let name = "am.strike"
            public typealias Value = Bool
        }
        public struct HeadingLevelAttribute: AttributedStringKey {
            public static let name = "am.heading"
            public typealias Value = Int
        }
        public struct ListItemAttribute: AttributedStringKey {
            public static let name = "am.listitem"
            public typealias Value = ListMetadata
        }
    }

    public var amInline: AMInlineAttributes.Type { AMInlineAttributes.self }
}

// MARK: - Public Bridge API (Inline Only)

/// Inline-only bridge between Markdown <-> AttributedString using the official swift-markdown parser.
/// Supported subset (current phase):
///   - Bold (**)
///   - Italic (*)
///   - Strikethrough (~~)
///   - Inline code (`code`)
///   - Links [text](url)
///
/// Headings, lists, block quotes, and code blocks are intentionally deferred until the inline pass is stable.
///
/// Strategy:
///   1. Parse Markdown into a Markup AST (swift-markdown).
///   2. Traverse AST producing an `AttributedString` with custom inline attributes (and Foundation link attribute).
///   3. Serialize by scanning attributed runs, coalescing adjacent segments with identical inline attributes,
///      and emitting canonical Markdown markers in a deterministic outer->inner order:
///         strikethrough (~~) -> bold (**) -> italic (*)
///      Code spans supersede other formatting.
///      Links wrap already formatted inner content.
///   4. Plain text is escaped for characters that could prematurely introduce formatting.
public enum MarkdownBridgeInline {

    // MARK: Parse (Markdown -> AttributedString)

    public static func parse(_ markdown: String) -> AttributedString {
        let document = Document(parsing: markdown)
        let renderer = InlineAttributedStringRenderer()
        renderer.visit(document)
        return renderer.output
    }

    // MARK: Serialize (AttributedString -> Markdown)

    public static func serialize(_ attributed: AttributedString) -> String {
        InlineSerializer.serialize(attributed)
    }
}

// MARK: - Public Convenience Initializer & Serializer

extension AttributedString {

    /// Create an attributed string from Markdown using the swift-markdown parser and the inline custom attribute scope.
    public init(inlineMarkdown markdown: String) {
        self = MarkdownBridgeInline.parse(markdown)
    }

    /// Inline-only Markdown serialization (AST-backed attribute model).
    public func toMarkdownViaAST() -> String {
        MarkdownBridgeInline.serialize(self)
    }
}

// MARK: - AST -> AttributedString (Inline Renderer)

private final class InlineAttributedStringRenderer {

    struct StyleContext {
        var bold = false
        var italic = false
        var code = false
        var strike = false
        var link: URL? = nil
        var headingLevel: Int? = nil
        var listMetadata: ListMetadata? = nil
    }

    private var stack: [StyleContext] = [StyleContext()]
    var output = AttributedString()

    // Entry traversal
    func visit(_ markup: Markup) {
        switch markup {
        case let doc as Document:
            for child in doc.children { visit(child) }

        case let text as Text:
            append(text.string)

        case let strong as Strong:
            with {
                $0.bold = true
            } body: {
                for c in strong.children { visit(c) }
            }

        case let em as Emphasis:
            with {
                $0.italic = true
            } body: {
                for c in em.children { visit(c) }
            }

        case let strike as Strikethrough:
            with {
                $0.strike = true
            } body: {
                for c in strike.children { visit(c) }
            }

        case let code as InlineCode:
            with {
                $0.code = true
            } body: {
                append(code.code)
            }

        case let link as Link:
            with {
                $0.link = URL(string: link.destination ?? "")
            } body: {
                for c in link.children { visit(c) }
            }

        case let heading as Heading:
            emitHeading(heading)
        case let ulist as UnorderedList:
            emitUnorderedList(ulist)
        case let olist as OrderedList:
            emitOrderedList(olist)
        default:
            for child in markup.children { visit(child) }
        }
    }

    // MARK: - Block helpers (moved outside switch for correct scope)

    private func appendNewlineIfNeeded() {
        if output.characters.last != "\n" {
            output.append(AttributedString("\n"))
        }
    }

    private func emitHeading(_ heading: Heading) {
        let level = max(1, min(heading.level, 6))
        with {
            $0.headingLevel = level
        } body: {
            for c in heading.children { visit(c) }
        }
        // One trailing blank line (heading line + empty line)
        appendNewlineIfNeeded()
        appendNewlineIfNeeded()
    }

    private func emitUnorderedList(_ list: UnorderedList) {
        var ordinal = 0
        for item in list.listItems {
            ordinal += 1
            handleListItem(item, ordered: false, startIndex: ordinal)
        }
        appendNewlineIfNeeded()
    }

    private func emitOrderedList(_ list: OrderedList) {
        // Canonical numbering: always restart at 1 regardless of source start index.
        var idx = 1
        for item in list.listItems {
            handleListItem(item, ordered: true, startIndex: idx)
            idx += 1
        }
        appendNewlineIfNeeded()
    }

    private func handleListItem(_ item: ListItem, ordered: Bool, startIndex: Int) {
        with {
            $0.listMetadata = ListMetadata(
                kind: ordered ? .ordered : .unordered, ordinal: startIndex)
        } body: {
            for child in item.children {
                visit(child)
            }
        }
        appendNewlineIfNeeded()
    }

    // Push / mutate context
    private func with(_ mutate: (inout StyleContext) -> Void, body: () -> Void) {
        var top = stack.last!
        mutate(&top)
        stack.append(top)
        body()
        _ = stack.popLast()
    }

    private func append(_ text: String) {
        guard !text.isEmpty else { return }
        var run = AttributedString(text)
        let ctx = stack.last!

        if ctx.bold {
            run[AttributeScopes.AMInlineAttributes.BoldAttribute.self] = true
        }
        if ctx.italic {
            run[AttributeScopes.AMInlineAttributes.ItalicAttribute.self] = true
        }
        if ctx.code {
            run[AttributeScopes.AMInlineAttributes.CodeAttribute.self] = true
        }
        if ctx.strike {
            run[AttributeScopes.AMInlineAttributes.StrikethroughAttribute.self] = true
        }
        if let link = ctx.link {
            run[AttributeScopes.FoundationAttributes.LinkAttribute.self] = link
        }
        if let heading = ctx.headingLevel {
            run[AttributeScopes.AMInlineAttributes.HeadingLevelAttribute.self] = heading
        }
        if let lm = ctx.listMetadata {
            run[AttributeScopes.AMInlineAttributes.ListItemAttribute.self] = lm
        }

        output.append(run)
    }
}

// MARK: - AttributedString -> Markdown Inline Serializer

private enum InlineSerializer {

    // (Using global ListMetadata defined above the attribute scope for block-level reconstruction)

    struct InlineFlags: Equatable {
        var bold = false
        var italic = false
        var code = false
        var strike = false
        var link: URL? = nil
        var headingLevel: Int? = nil
        var listMetadata: ListMetadata? = nil

        var styleOnlyKey: StyleKey {
            StyleKey(bold: bold, italic: italic, code: code, strike: strike, link: link != nil)
        }

        struct StyleKey: Hashable {
            let bold: Bool
            let italic: Bool
            let code: Bool
            let strike: Bool
            let link: Bool
        }
    }

    static func serialize(_ attributed: AttributedString) -> String {
        // Phase 1: collect raw segments (merging identical inline flags).
        var segments: [(InlineFlags, String)] = []
        for run in attributed.runs {
            let flags = extract(run)
            let text = String(attributed[run.range].characters)
            guard !text.isEmpty else { continue }
            if let last = segments.last, last.0 == flags {
                segments[segments.count - 1].1.append(text)
            } else {
                segments.append((flags, text))
            }
        }

        // Phase 2: canonical emission with grouping to allow a single outer bold (and/or strike + link)
        // with nested *italic* spans inside, producing the desired form:
        //   **This *that*** (instead of **This *****that***)
        var result = String()
        var i = 0
        while i < segments.count {
            let (flags, text) = segments[i]

            // Code segments remain isolated (with optional link wrapping).
            if flags.code {
                result.append(renderCodeSegment(text, flags))
                i += 1
                continue
            }
            // Block-level: heading
            if let h = flags.headingLevel {
                result.append(renderHeading(h, text: text, flags: flags))
                i += 1
                continue
            }
            if let lm = flags.listMetadata {
                result.append(renderListItem(lm, text: text, flags: flags))
                i += 1
                continue
            }

            // Group by non-italic style signature (bold / strike / link), excluding code & block-level.
            let keyBold = flags.bold
            let keyStrike = flags.strike
            let keyLink = flags.link

            var group: [(InlineFlags, String)] = []
            var j = i
            while j < segments.count {
                let next = segments[j]
                let nf = next.0
                if !nf.code && nf.bold == keyBold && nf.strike == keyStrike && nf.link == keyLink {
                    group.append(next)
                    j += 1
                } else {
                    break
                }
            }

            // Build inner content (italic spans wrapped individually).
            var inner = String()
            inner.reserveCapacity(group.reduce(0) { $0 + $1.1.count + 4 })

            for (gFlags, gText) in group {
                let esc = escapePlain(gText)
                if gFlags.italic {
                    inner.append("*\(esc)*")
                } else {
                    inner.append(esc)
                }
            }

            // Wrap outer styles (strike then bold) around the entire grouped region.
            // Canonical wrapper order: italic already applied inside, then bold, then strike outermost, then link.
            if keyBold {
                inner = "**\(inner)**"
            }
            if keyStrike {
                inner = "~~\(inner)~~"
            }
            if let link = keyLink {
                inner = "[\(inner)](\(escapeLinkDestination(link)))"
            }

            result.append(inner)
            i = j
        }

        return result
    }

    private static func extract(_ run: AttributedString.Runs.Run) -> InlineFlags {
        var out = InlineFlags()
        if run[AttributeScopes.AMInlineAttributes.BoldAttribute.self] == true { out.bold = true }
        if run[AttributeScopes.AMInlineAttributes.ItalicAttribute.self] == true {
            out.italic = true
        }
        if run[AttributeScopes.AMInlineAttributes.CodeAttribute.self] == true { out.code = true }
        if run[AttributeScopes.AMInlineAttributes.StrikethroughAttribute.self] == true {
            out.strike = true
        }
        if let h = run[AttributeScopes.AMInlineAttributes.HeadingLevelAttribute.self] {
            out.headingLevel = h
        }
        if let lm = run[AttributeScopes.AMInlineAttributes.ListItemAttribute.self] {
            out.listMetadata = lm
        }
        if let link = run[AttributeScopes.FoundationAttributes.LinkAttribute.self] {
            out.link = link
        }
        if let h = run[AttributeScopes.AMInlineAttributes.HeadingLevelAttribute.self] {
            out.headingLevel = h
        }
        if let lm = run[AttributeScopes.AMInlineAttributes.ListItemAttribute.self] {
            out.listMetadata = lm
        }
        // Code overrides other styling semantics (code text not wrapped by emphasis markers).
        if out.code {
            out.bold = false
            out.italic = false
            out.strike = false
        }
        return out
    }

    // Render a heading line
    private static func renderHeading(_ level: Int, text: String, flags: InlineFlags) -> String {
        var innerFlags = flags
        innerFlags.headingLevel = nil
        innerFlags.listMetadata = nil
        let rendered = renderPlainStyled(text, flags: innerFlags)
        let hashes = String(repeating: "#", count: max(1, min(level, 6)))
        // Heading line plus a blank line after.
        return "\(hashes) \(rendered)\n\n"
    }

    // Render a list item line
    private static func renderListItem(_ meta: ListMetadata, text: String, flags: InlineFlags)
        -> String
    {
        var innerFlags = flags
        innerFlags.listMetadata = nil
        innerFlags.headingLevel = nil
        let body = renderPlainStyled(text, flags: innerFlags)
        let prefix: String
        switch meta.kind {
        case .unordered: prefix = "- "
        case .ordered: prefix = "\(meta.ordinal). "
        }
        return "\(prefix)\(body)\n"
    }

    // Render plain styled (non-heading / non-list) text segment with inline wrappers
    private static func renderPlainStyled(_ raw: String, flags: InlineFlags) -> String {
        if flags.code {
            return renderCodeSegment(raw, flags)
        }
        var core = escapePlain(raw)
        if flags.italic {
            core = "*\(core)*"
        }
        if flags.bold {
            core = "**\(core)**"
        }
        if flags.strike {
            core = "~~\(core)~~"
        }
        if let link = flags.link {
            core = "[\(core)](\(escapeLinkDestination(link)))"
        }
        return core
    }

    // Render a code segment (code supersedes other style wrappers; link may wrap it).
    private static func renderCodeSegment(_ raw: String, _ flags: InlineFlags) -> String {
        let fenced = wrapCode(raw)
        if let link = flags.link {
            return "[\(fenced)](\(escapeLinkDestination(link)))"
        }
        return fenced
    }

    // MARK: Escaping

    private static func escapePlain(_ text: String) -> String {
        var out = String()
        out.reserveCapacity(text.count)
        for ch in text {
            switch ch {
            case "\\", "*", "_", "[", "]", "(", ")", "`", "~":
                out.append("\\\(ch)")
            default:
                out.append(ch)
            }
        }
        return out
    }

    private static func wrapCode(_ text: String) -> String {
        // Determine shortest fence not colliding with internal backtick runs.
        let longest = longestBacktickRun(in: text)
        let fence = String(repeating: "`", count: longest + 1)
        return fence + text + fence
    }

    private static func longestBacktickRun(in text: String) -> Int {
        var cur = 0
        var best = 0
        for ch in text {
            if ch == "`" {
                cur += 1
                best = max(best, cur)
            } else {
                cur = 0
            }
        }
        return best
    }

    private static func escapeLinkDestination(_ url: URL) -> String {
        // Minimal escaping: spaces, parentheses, brackets.
        var out = String()
        let raw = url.absoluteString
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
}

// MARK: - (Optional) Legacy Compatibility Shim
// If you want the main toMarkdown() (from earlier version) to now use the AST approach,
// you can uncomment the following extension:
//
// extension AttributedString {
//     public func toMarkdown() -> String {
//         self.toMarkdownViaAST()
//     }
// }
//
// For now we leave the original toMarkdown() (from the previous file) untouched so
// that incremental migration is straightforward.

// MARK: - Notes / Future Extensions
//
// - Block Quotes & Fenced Code Blocks:
//     Not yet implemented; would require additional block metadata (e.g. quote depth, code language).
// - Run Coalescing:
//     Already coalesces identical styles for cleaner output.
// - Smart Escapes:
//     Could reduce over-escaping by context analysis (e.g., not escaping * inside code).
// - Performance:
//     Current implementation is suitable for typical UI/editor content sizes. For very large documents
//     consider a single pass building ranges with a small builder object.
// - Attribute Strategy:
//     Headings (H1–H6) and lists now round-trip via custom attributes (am.heading / am.listitem).
//
// This phase currently focuses on reliable inline + basic block (headings, lists) round-trips.
//
