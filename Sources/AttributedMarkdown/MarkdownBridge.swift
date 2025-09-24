import Foundation
import Markdown

// MARK: - Custom Inline Attribute Scope (Bold / Italic / Code / Strikethrough)

extension AttributeScopes {

    /// Attribute scope for AttributedMarkdown custom inline markers.
    public struct AMInlineAttributes: AttributeScope {
        public let bold: BoldAttribute
        public let italic: ItalicAttribute
        public let code: CodeAttribute
        public let strike: StrikethroughAttribute

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

        default:
            // Recurse generically for other inline / mixed nodes (they will just flatten).
            for child in markup.children { visit(child) }
        }
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

        output.append(run)
    }
}

// MARK: - AttributedString -> Markdown Inline Serializer

private enum InlineSerializer {

    struct InlineFlags: Equatable {
        var bold = false
        var italic = false
        var code = false
        var strike = false
        var link: URL? = nil

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
        // Collect contiguous segments with identical style flags.
        var segments: [(InlineFlags, String)] = []
        for run in attributed.runs {
            let flags = extract(run)
            let text = String(attributed[run.range].characters)
            guard !text.isEmpty else { continue }

            if let last = segments.last, last.0 == flags {
                // Merge
                segments[segments.count - 1].1.append(text)
            } else {
                segments.append((flags, text))
            }
        }

        // Emit
        var result = String()
        for (flags, text) in segments {
            result.append(renderSegment(text, flags))
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
        if let link = run[AttributeScopes.FoundationAttributes.LinkAttribute.self] {
            out.link = link
        }
        // Code overrides other styling semantics (code text not wrapped by emphasis markers).
        if out.code {
            out.bold = false
            out.italic = false
            out.strike = false
        }
        return out
    }

    private static func renderSegment(_ raw: String, _ flags: InlineFlags) -> String {
        if flags.code {
            let fenced = wrapCode(raw)
            if let link = flags.link {
                return "[\(fenced)](\(escapeLinkDestination(link)))"
            }
            return fenced
        }

        var core = escapePlain(raw)

        // Apply inner wrappers first (bold, italic), then outer strike for canonical form so the emitted
        // Markdown shows strike as the outermost wrapper: ~~**text**~~ or ~~***text***~~.
        if flags.bold {
            core = "**\(core)**"
        }
        if flags.italic {
            core = "*\(core)*"
        }
        if flags.strike {
            core = "~~\(core)~~"
        }
        if let link = flags.link {
            core = "[\(core)](\(escapeLinkDestination(link)))"
        }
        return core
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
// - Headings / Lists / Blockquotes:
//     Will require either custom attributes or mapping to PresentationIntent (once consistently available).
// - Fenced Code Blocks:
//     Need block-level detection; a heuristic: multi-line code segments originally parsed as CodeBlock can be
//     tagged via a custom attribute. Absent that, inline code remains the only emission.
// - Run Coalescing:
//     Already coalesces identical styles for cleaner output.
// - Smart Escapes:
//     Could reduce over-escaping by context analysis (e.g., not escaping * inside code).
// - Performance:
//     Current implementation is suitable for typical UI/editor content sizes. For very large documents
//     consider a single pass building ranges with a small builder object.
//
// This phase focuses on reliability & determinism for inline round-trips.
//
