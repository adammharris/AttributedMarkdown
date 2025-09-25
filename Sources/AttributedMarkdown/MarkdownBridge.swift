import Foundation
import Markdown

#if canImport(UIKit)
    import UIKit
#endif
#if canImport(AppKit)
    import AppKit
#endif
#if canImport(SwiftUI)
    import SwiftUI
#endif

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

/// Metadata for block quotes (depth is 1-based nesting level).
public struct BlockQuoteMetadata: Hashable, Codable {
    public let depth: Int
}

/// Metadata for fenced code blocks.
public struct CodeBlockMetadata: Hashable, Codable {
    public let language: String?
    public let content: String
}

// MARK: - Custom Inline / Block Attribute Scope (Bold / Italic / Code / Strike / Headings / Lists / BlockQuote / CodeBlock)

extension AttributeScopes {

    /// Attribute scope for AttributedMarkdown custom inline markers.
    public struct AMInlineAttributes: AttributeScope {
        public let bold: BoldAttribute
        public let italic: ItalicAttribute
        public let code: CodeAttribute
        public let strike: StrikethroughAttribute
        public let heading: HeadingLevelAttribute
        public let listItem: ListItemAttribute
        public let blockQuote: BlockQuoteAttribute
        public let codeBlock: CodeBlockAttribute
        public let paragraph: ParagraphAttribute

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
        public struct BlockQuoteAttribute: AttributedStringKey {
            public static let name = "am.blockquote"
            public typealias Value = BlockQuoteMetadata
        }
        public struct CodeBlockAttribute: AttributedStringKey {
            public static let name = "am.codeblock"
            public typealias Value = CodeBlockMetadata
        }
        public struct ParagraphAttribute: AttributedStringKey {
            public static let name = "am.paragraph"
            public typealias Value = Int
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
        // Preserve a trailing single newline from the original source if the AST did not produce one.
        if markdown.hasSuffix("\n"), renderer.output.characters.last != "\n" {
            renderer.output.append(AttributedString("\n"))
        }
        return renderer.output
    }

    // MARK: Serialize (AttributedString -> Markdown)

    public static func serialize(_ attributed: AttributedString) -> String {
        InlineSerializer.serialize(attributed)
    }
}

// MARK: - Public Convenience Initializer & Serializer

extension AttributedString {

    /// Create an attributed string from Markdown using the swift-markdown parser and then
    /// normalize block quote depths line-by-line to preserve round-trip fidelity for
    /// nested quotes whose depth decreases (e.g. `> > Inner` followed by `> Back`).
    public init(inlineMarkdown markdown: String) {
        let provisional = MarkdownBridgeInline.parse(markdown)
        self = QuoteDepthNormalizer.normalize(original: markdown, provisional: provisional)
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
        var blockQuoteDepth: Int? = nil
        var codeBlockInfo: CodeBlockMetadata? = nil
        var paragraphID: Int? = nil
    }

    private var stack: [StyleContext] = [StyleContext()]
    var output = AttributedString()
    private var nextParagraphID: Int = 1

    // Entry traversal
    func visit(_ markup: Markup) {
        switch markup {
        case let doc as Markdown.Document:
            for child in doc.children { visit(child) }

        case let text as Markdown.Text:
            append(text.string)

        case _ as Markdown.SoftBreak:
            append("\n")

        case _ as Markdown.LineBreak:
            append("\n")

        case let strong as Markdown.Strong:
            with {
                $0.bold = true
            } body: {
                for c in strong.children { visit(c) }
            }

        case let em as Markdown.Emphasis:
            with {
                $0.italic = true
            } body: {
                for c in em.children { visit(c) }
            }

        case let strike as Markdown.Strikethrough:
            with {
                $0.strike = true
            } body: {
                for c in strike.children { visit(c) }
            }

        case let code as Markdown.InlineCode:
            with {
                $0.code = true
            } body: {
                append(code.code)
            }

        case let link as Markdown.Link:
            with {
                $0.link = URL(string: link.destination ?? "")
            } body: {
                for c in link.children { visit(c) }
            }

        case let heading as Markdown.Heading:
            emitHeading(heading)
        case let ulist as Markdown.UnorderedList:
            emitUnorderedList(ulist)
        case let olist as Markdown.OrderedList:
            emitOrderedList(olist)
        case let quote as Markdown.BlockQuote:
            emitBlockQuote(quote, depth: (stack.last?.blockQuoteDepth ?? 0) + 1)
        case let blockCode as Markdown.CodeBlock:
            emitFencedCodeBlock(blockCode)
        case let para as Markdown.Paragraph:
            let paragraphID = nextParagraphID
            nextParagraphID += 1
            with {
                $0.paragraphID = paragraphID
            } body: {
                for c in para.children { visit(c) }
            }
        default:
            for child in markup.children { visit(child) }
        }
    }

    // MARK: - Block helpers (moved outside switch for correct scope)

    private func emitHeading(_ heading: Markdown.Heading) {
        let level = max(1, min(heading.level, 6))
        with {
            $0.headingLevel = level
        } body: {
            for c in heading.children { visit(c) }
        }
    }

    private func emitUnorderedList(_ list: Markdown.UnorderedList) {
        var ordinal = 0
        for item in list.listItems {
            ordinal += 1
            handleListItem(item, ordered: false, startIndex: ordinal)
        }
        // Newlines (with list metadata) are appended per item inside handleListItem.
    }

    private func emitOrderedList(_ list: Markdown.OrderedList) {
        // Canonical numbering: always restart at 1 regardless of source start index.
        var idx = 1
        for item in list.listItems {
            handleListItem(item, ordered: true, startIndex: idx)
            idx += 1
        }
        // Newlines (with list metadata) are appended per item inside handleListItem.
    }

    private func handleListItem(_ item: Markdown.ListItem, ordered: Bool, startIndex: Int) {
        let metadata = ListMetadata(kind: ordered ? .ordered : .unordered, ordinal: startIndex)
        with {
            $0.listMetadata = metadata
        } body: {
            for child in item.children {
                visit(child)
            }
        }
        // Append newline carrying list metadata so collector keeps it within the list block (no blank line separation).
        var nl = AttributedString("\n")
        nl[AttributeScopes.AMInlineAttributes.ListItemAttribute.self] = metadata
        output.append(nl)
    }

    // BlockQuote
    private func emitBlockQuote(_ quote: Markdown.BlockQuote, depth: Int) {
        // Apply depth metadata to every appended run inside the quote; no placeholder run.
        let childrenArray = Array(quote.children)
        for child in childrenArray {
            with {
                $0.blockQuoteDepth = depth
            } body: {
                visit(child)
            }
            // Do not append raw newlines here; BlockRenderer will manage spacing.
        }
        // Spacing handled in renderer; don't append extra blank line here.
    }

    // Fenced Code Block
    private func emitFencedCodeBlock(_ block: Markdown.CodeBlock) {
        // Store the raw code content (not fenced here). Fencing handled in serializer.
        let lang = block.language?.isEmpty == false ? block.language : nil
        let info = CodeBlockMetadata(language: lang, content: block.code)
        with {
            $0.codeBlockInfo = info
        } body: {
            // Append the actual code text so downstream block collection knows position.
            append(block.code)
        }
        // Do not force extra blank lines here; BlockRenderer manages spacing.
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
        if let depth = ctx.blockQuoteDepth {
            run[AttributeScopes.AMInlineAttributes.BlockQuoteAttribute.self] = BlockQuoteMetadata(
                depth: depth)
        }
        if let cb = ctx.codeBlockInfo {
            run[AttributeScopes.AMInlineAttributes.CodeBlockAttribute.self] = cb
        }
        if let paragraphID = ctx.paragraphID {
            run[AttributeScopes.AMInlineAttributes.ParagraphAttribute.self] = paragraphID
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
        var blockQuoteDepth: Int? = nil
        var codeBlock: CodeBlockMetadata? = nil
        var paragraphID: Int? = nil

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
        let segments = collectSegments(from: attributed)
        let blocks = BlockCollector.buildBlocks(from: segments)
        return BlockCollector.BlockRenderer.render(blocks)
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
        if let bq = run[AttributeScopes.AMInlineAttributes.BlockQuoteAttribute.self] {
            out.blockQuoteDepth = bq.depth
        }
        if let cb = run[AttributeScopes.AMInlineAttributes.CodeBlockAttribute.self] {
            out.codeBlock = cb
        }
        if let paragraphID = run[AttributeScopes.AMInlineAttributes.ParagraphAttribute.self] {
            out.paragraphID = paragraphID
        }
        if let link = run[AttributeScopes.FoundationAttributes.LinkAttribute.self] {
            out.link = link
        }
        // Fallback: Foundation InlinePresentationIntent (when editor sets semantic intents)
        if let intent = run[
            AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self]
        {
            if intent.contains(.stronglyEmphasized) { out.bold = true }
            if intent.contains(.emphasized) { out.italic = true }
            if intent.contains(.code) { out.code = true }
        }
        if let h = run[AttributeScopes.AMInlineAttributes.HeadingLevelAttribute.self] {
            out.headingLevel = h
        }
        if let lm = run[AttributeScopes.AMInlineAttributes.ListItemAttribute.self] {
            out.listMetadata = lm
        }
#if canImport(SwiftUI)
        if let swiftFont = run[AttributeScopes.SwiftUIAttributes.FontAttribute.self] {
            let traits = SwiftUIFontTraits.resolve(swiftFont)
            if !out.bold && traits.bold { out.bold = true }
            if !out.italic && traits.italic { out.italic = true }
        }
#endif
        // Code overrides other styling semantics (code text not wrapped by emphasis markers).
        if out.code {
            out.bold = false
            out.italic = false
            out.strike = false
        }
        return out
    }

    // MARK: - Segment & Block Modeling (new)
    struct Segment {
        let text: String
        let flags: InlineFlags
    }

    enum Block {
        case heading(level: Int, segments: [Segment])
        case unorderedList(items: [[Segment]])
        case orderedList(items: [[Segment]])
        case blockQuote(depth: Int, lines: [[Segment]])
        case codeBlock(language: String?, content: String)
        case paragraph([Segment])
        case blank(runLength: Int)  // exact count of consecutive newline characters
    }

    // Collect raw segments (no grouping yet)
    private static func collectSegments(from attributed: AttributedString) -> [Segment] {
        var result: [Segment] = []
        // Bridge to NSAttributedString once to enable platform trait fallbacks (bold/italic/strike/link).
        let ns = NSAttributedString(attributed)
        var utf16Offset = 0
        for run in attributed.runs {
            var flags = extract(run)
            let slice = attributed[run.range]
            let text = String(slice.characters)
            guard !text.isEmpty else {
                // Still advance offset for consistency
                utf16Offset += text.utf16.count
                continue
            }

            // Fallbacks: derive styling from platform attributes when semantic attributes are absent.
            let attrs = ns.attributes(at: utf16Offset, effectiveRange: nil)

            #if canImport(UIKit)
                if let font = attrs[.font] as? UIFont {
                    let traits = font.fontDescriptor.symbolicTraits
                    if !flags.bold && traits.contains(.traitBold) { flags.bold = true }
                    if !flags.italic && traits.contains(.traitItalic) { flags.italic = true }
                }
            #elseif canImport(AppKit)
                if let font = attrs[.font] as? NSFont {
                    let traits = font.fontDescriptor.symbolicTraits
                    if !flags.bold && traits.contains(.bold) { flags.bold = true }
                    if !flags.italic && traits.contains(.italic) { flags.italic = true }
                }
            #endif

            if !flags.strike {
                if let num = attrs[.strikethroughStyle] as? NSNumber, num.intValue != 0 {
                    flags.strike = true
                } else {
                    for keyName in [
                        "NSStrikethrough",
                        "NSStrikethroughStyle",
                        "NSUnderlineStrikethroughStyle",
                        "NSStrikethroughStyleAttributeName",
                    ] {
                        let k = NSAttributedString.Key(keyName)
                        if let v = attrs[k] {
                            if let n = v as? NSNumber, n.intValue != 0 {
                                flags.strike = true
                                break
                            }
                            if let i = v as? Int, i != 0 {
                                flags.strike = true
                                break
                            }
                        }
                    }
                }
            }

            if flags.link == nil, let url = attrs[.link] as? URL {
                flags.link = url
            }

            result.append(Segment(text: text, flags: flags))
            utf16Offset += text.utf16.count
        }
        return result
    }

    // BlockCollector: turns flat segments into structural blocks
    private struct BlockCollector {
        static func buildBlocks(from segments: [Segment]) -> [Block] {
            var blocks: [Block] = []
            var i = 0
            while i < segments.count {
                let seg = segments[i]

                // Code block
                if let cb = seg.flags.codeBlock {
                    blocks.append(.codeBlock(language: cb.language, content: cb.content))
                    i += 1
                    continue
                }

                // Heading
                if let level = seg.flags.headingLevel {
                    var headingSegs: [Segment] = []
                    var j = i
                    while j < segments.count, segments[j].flags.headingLevel == level {
                        headingSegs.append(segments[j])
                        j += 1
                    }
                    blocks.append(.heading(level: level, segments: headingSegs))
                    i = j
                    continue
                }

                // List
                if let lm = seg.flags.listMetadata {
                    let isOrdered = lm.kind == .ordered
                    var allItems: [[Segment]] = []
                    var j = i
                    var currentOrdinal = lm.ordinal
                    var currentItem: [Segment] = []

                    func flushItem() {
                        if !currentItem.isEmpty {
                            allItems.append(currentItem)
                            currentItem.removeAll()
                        }
                    }

                    while j < segments.count {
                        let s = segments[j]
                        guard let meta = s.flags.listMetadata, meta.kind == lm.kind else { break }
                        if meta.ordinal != currentOrdinal {
                            flushItem()
                            currentOrdinal = meta.ordinal
                        }
                        currentItem.append(s)
                        j += 1
                    }
                    flushItem()
                    blocks.append(
                        isOrdered ? .orderedList(items: allItems) : .unorderedList(items: allItems))
                    i = j
                    continue
                }

                // Block quote
                if let depth = seg.flags.blockQuoteDepth {
                    var lines: [[Segment]] = []
                    var currentLine: [Segment] = []
                    var j = i

                    func flushLine() {
                        if !currentLine.isEmpty {
                            lines.append(currentLine)
                            currentLine.removeAll()
                        }
                    }

                    while j < segments.count {
                        let s = segments[j]
                        guard s.flags.blockQuoteDepth == depth else { break }
                        let parts = s.text.split(separator: "\n", omittingEmptySubsequences: false)
                        for (idx, part) in parts.enumerated() {
                            if !part.isEmpty {
                                currentLine.append(
                                    Segment(
                                        text: String(part), flags: stripBlockAttributes(s.flags)))
                            }
                            if idx < parts.count - 1 {
                                flushLine()
                            }
                        }
                        j += 1
                    }
                    flushLine()
                    if !lines.isEmpty {
                        blocks.append(.blockQuote(depth: depth, lines: lines))
                        i = j
                        continue
                    }
                }

                // Paragraph with explicit paragraph metadata (from inline renderer)
                if let paragraphID = seg.flags.paragraphID {
                    var collected: [Segment] = []
                    var j = i
                    while j < segments.count {
                        let candidate = segments[j]
                        guard candidate.flags.paragraphID == paragraphID else { break }
                        collected.append(candidate)
                        j += 1
                    }
                    if !collected.isEmpty {
                        blocks.append(.paragraph(collected))
                        i = j
                        continue
                    }
                }

                // Newline handling (preserve exact counts) with special casing for block quote internal separators.
                if seg.text == "\n" || seg.text == "\r\n" {
                    var runLen = 0
                    var j = i
                    while j < segments.count {
                        let t = segments[j].text
                        if t == "\n" || t == "\r\n" {
                            runLen += 1
                            j += 1
                        } else {
                            break
                        }
                    }

                    if runLen == 1 {
                        // Determine context around this single newline.
                        let prevIsQuote: Bool = {
                            if let last = blocks.last, case .blockQuote = last { return true }
                            return false
                        }()
                        let nextIsQuote: Bool = {
                            if j < segments.count {
                                return segments[j].flags.blockQuoteDepth != nil
                            }
                            return false
                        }()

                        if prevIsQuote || nextIsQuote {
                            // Internal block quote line separator: consume without emitting a blank block.
                            i += 1
                            continue
                        }

                        // Could be a soft break in an existing paragraph when styles match.
                        if case .paragraph(let prevSegs)? = blocks.last,
                            let lastSeg = prevSegs.last,
                            lastSeg.flags.styleOnlyKey == seg.flags.styleOnlyKey
                        {
                            var updated = prevSegs
                            let tail = updated.removeLast()
                            updated.append(Segment(text: tail.text + "\n", flags: tail.flags))
                            blocks.removeLast()
                            blocks.append(.paragraph(updated))
                            i += 1
                            continue
                        }

                        // Standalone blank line (structural break).
                        blocks.append(.blank(runLength: 1))
                        i = j
                        continue
                    } else {
                        // Two or more consecutive newlines: exact blank run.
                        // If the first newline would have been an internal quote separator we still
                        // treat the whole run as blank vertical spacing (rare case).
                        blocks.append(.blank(runLength: runLen))
                        i = j
                        continue
                    }
                }

                // Paragraph accumulation with simplified soft break handling.
                // Strategy:
                //  - A single newline after text is merged into the previous segment's text as a literal '\n'.
                //  - Two consecutive newline segments (or a segment that is exactly "\n" followed by another) terminate the paragraph (hard break).
                var para: [Segment] = []
                var j = i
                while j < segments.count {
                    let s = segments[j]
                    // Structural boundaries end the paragraph.
                    if s.flags.headingLevel != nil || s.flags.listMetadata != nil
                        || s.flags.blockQuoteDepth != nil || s.flags.codeBlock != nil
                    {
                        break
                    }

                    // Standalone newline segment
                    if s.text == "\n" || s.text == "\r\n" {
                        let nextIsNewline =
                            (j + 1 < segments.count)
                            && (segments[j + 1].text == "\n" || segments[j + 1].text == "\r\n")
                        if nextIsNewline {
                            // Hard break: stop paragraph; outer loop handles blank.
                            break
                        } else {
                            // Soft break: merge into previous segment only when style flags match.
                            if let last = para.last,
                                last.flags.styleOnlyKey == s.flags.styleOnlyKey
                            {
                                let popped = para.removeLast()
                                para.append(
                                    Segment(text: popped.text + "\n", flags: popped.flags))
                                j += 1
                                continue
                            } else {
                                // Style mismatch indicates structural break; end paragraph here so the
                                // newline can be handled by the outer loop (e.g. paragraph separator).
                                break
                            }
                        }
                    }

                    // Segment with embedded newlines (split into soft / hard)
                    if s.text.contains("\n") || s.text.contains("\r\n") {
                        let normalized = s.text.replacingOccurrences(of: "\r\n", with: "\n")
                        var remainder = normalized[normalized.startIndex..<normalized.endIndex]
                        var encounteredHard = false
                        while let nl = remainder.firstIndex(of: "\n") {
                            let before = remainder[..<nl]
                            let afterStart = remainder.index(after: nl)
                            if !before.isEmpty {
                                para.append(Segment(text: String(before), flags: s.flags))
                            }
                            // Look ahead to detect double newline
                            if afterStart < remainder.endIndex, remainder[afterStart] == "\n" {
                                // Hard break -> paragraph ends (ignore subsequent content; outer loop will see next newline)
                                encounteredHard = true
                                remainder = remainder[afterStart...]  // leave next newline for outer loop
                                break
                            } else {
                                // Soft break: merge newline into previous segment
                                if let last = para.popLast() {
                                    para.append(Segment(text: last.text + "\n", flags: last.flags))
                                } else {
                                    // No previous content; ignore
                                }
                                remainder = remainder[afterStart...]
                            }
                        }
                        if !encounteredHard, !remainder.isEmpty {
                            para.append(Segment(text: String(remainder), flags: s.flags))
                        }
                        j += 1
                        if encounteredHard { break }
                        continue
                    }

                    // Regular text segment
                    para.append(s)
                    j += 1
                }

                if !para.isEmpty {
                    // Do not emit a paragraph that is purely a single newline (already merged logic avoids this).
                    if !(para.count == 1 && (para[0].text == "\n" || para[0].text == "\r\n")) {
                        blocks.append(.paragraph(para))
                    }
                    i = j
                    continue
                }

                // Fallback
                blocks.append(.paragraph([seg]))
                i += 1
            }

            // Exact preservation mode: return collected blocks unmodified (quote internal newlines already filtered inline)
            return blocks
        }

        // Rendering
        struct BlockRenderer {
            static func isStructural(_ block: Block) -> Bool {
                switch block {
                case .heading, .unorderedList, .orderedList, .codeBlock, .blockQuote:
                    return true
                default:
                    return false
                }
            }

            static func render(_ blocks: [Block]) -> String {
                var out = String()
                for (idx, block) in blocks.enumerated() {
                    let isLast = idx == blocks.count - 1
                    switch block {
                    case .heading(let level, let segs):
                        out.append(renderHeadingBlock(level: level, segs: segs))
                    case .unorderedList(let items):
                        out.append(
                            renderListBlock(items: items, ordered: false, nextIsBlock: !isLast))
                    case .orderedList(let items):
                        out.append(
                            renderListBlock(items: items, ordered: true, nextIsBlock: !isLast))
                    case .blockQuote(let depth, let lines):
                        // Only add an extra blank line after a block quote if the next block is a different structural type.
                        let addBlankAfter: Bool = {
                            guard !isLast else { return false }
                            switch blocks[idx + 1] {
                            case .blockQuote: return false
                            default: return true
                            }
                        }()
                        out.append(
                            renderQuote(depth: depth, lines: lines, nextIsBlock: addBlankAfter))
                    case .codeBlock(let lang, let content):
                        out.append(renderCodeBlock(lang: lang, content: content))
                    case .paragraph(let segs):
                        // Safeguard: ensure a newline separates a preceding block quote from a following paragraph
                        if idx > 0 {
                            if case .blockQuote = blocks[idx - 1], !out.hasSuffix("\n") {
                                out.append("\n")
                            }
                        }
                        out.append(renderParagraph(segs))
                        if !isLast {
                            switch blocks[idx + 1] {
                            case .blank:
                                break
                            default:
                                if out.hasSuffix("\n") {
                                    if !out.hasSuffix("\n\n") {
                                        out.append("\n")
                                    }
                                } else {
                                    out.append("\n\n")
                                }
                            }
                        }
                    case .blank(let runLength):
                        out.append(String(repeating: "\n", count: runLength))
                    }
                }
                // Normalize only triple+ consecutive blanks to avoid runaway spacing.
                while out.hasSuffix("\n\n\n") { out.removeLast() }
                return out
            }

            private static func joinInline(_ segs: [Segment]) -> String {
                var rendered = String()
                var i = 0
                while i < segs.count {
                    let f = segs[i].flags
                    if f.code {
                        rendered.append(renderCodeSegment(segs[i].text, f))
                        i += 1
                        continue
                    }
                    let keyBold = f.bold
                    let keyStrike = f.strike
                    let keyLink = f.link
                    var group: [Segment] = []
                    var j = i
                    while j < segs.count {
                        let nf = segs[j].flags
                        if nf.code || nf.bold != keyBold || nf.strike != keyStrike
                            || nf.link != keyLink
                        {
                            break
                        }
                        group.append(segs[j])
                        j += 1
                    }
                    var inner = String()
                    for g in group {
                        let esc = escapePlain(g.text)
                        if g.flags.italic {
                            inner.append("*\(esc)*")
                        } else {
                            inner.append(esc)
                        }
                    }
                    if keyBold { inner = "**\(inner)**" }
                    if keyStrike { inner = "~~\(inner)~~" }
                    if let link = keyLink {
                        inner = "[\(inner)](\(escapeLinkDestination(link)))"
                    }
                    rendered.append(inner)
                    i = j
                }
                return rendered
            }

            private static func renderParagraph(_ segs: [Segment]) -> String {
                guard !segs.isEmpty else { return "" }
                // Do not synthesize trailing newlines; exact newline runs are emitted by .blank(runLength:)
                return joinInline(segs)
            }

            private static func renderHeadingBlock(level: Int, segs: [Segment]) -> String {
                let body = joinInline(segs).trimmingCharacters(in: .newlines)
                let hashes = String(repeating: "#", count: max(1, min(level, 6)))
                return "\(hashes) \(body)\n\n"
            }

            private static func renderListBlock(
                items: [[Segment]], ordered: Bool, nextIsBlock: Bool
            ) -> String {
                var out = String()
                for (idx, item) in items.enumerated() {
                    let body = joinInline(item)
                    let bodyTrimmed = body.trimmingCharacters(in: .newlines)
                    let bullet = ordered ? "\(idx + 1)." : "-"
                    out.append("\(bullet) \(bodyTrimmed)\n")
                }
                if nextIsBlock { out.append("\n") }
                return out
            }

            private static func renderQuote(depth: Int, lines: [[Segment]], nextIsBlock: Bool)
                -> String
            {
                var out = String()
                let prefixBase = String(repeating: "> ", count: depth)
                for line in lines {
                    let body = joinInline(line)
                    out.append("\(prefixBase)\(body)\n")
                }
                if nextIsBlock { out.append("\n") }
                return out
            }

            private static func renderCodeBlock(lang: String?, content: String) -> String {
                let longest = longestBacktickRun(in: content)
                let fence = String(repeating: "`", count: max(3, longest + 1))
                var header = fence
                if let l = lang, !l.isEmpty { header += l }
                var body = content
                if !body.hasSuffix("\n") { body.append("\n") }
                return "\(header)\n\(body)\(fence)\n\n"
            }
        }
        // Helper to strip block-only attributes when embedding segment text inside larger block contexts.
        private static func stripBlockAttributes(_ f: InlineFlags) -> InlineFlags {
            var c = f
            c.headingLevel = nil
            c.listMetadata = nil
            c.blockQuoteDepth = nil
            c.codeBlock = nil
            return c
        }
        // Render plain styled (non-heading / non-list / non-blockQuote / non-codeblock) text segment with inline wrappers
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

#if canImport(SwiftUI)
    private enum SwiftUIFontTraits {
        static func resolve(_ font: SwiftUI.Font) -> (bold: Bool, italic: Bool) {
            var bold = false
            var italic = false
            inspect(font, bold: &bold, italic: &italic, depth: 0)
            return (bold, italic)
        }

        private static func inspect(_ value: Any, bold: inout Bool, italic: inout Bool, depth: Int) {
            guard depth < 16 else { return }
            let typeDescription = String(describing: type(of: value))
            if typeDescription.contains("Bold") { bold = true }
            if typeDescription.contains("Italic") { italic = true }

            let mirror = Mirror(reflecting: value)
            for child in mirror.children {
                inspect(child.value, bold: &bold, italic: &italic, depth: depth + 1)
            }
        }
    }
#endif

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
    //     Implemented via custom blockQuote and codeBlock metadata attributes.
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
}
