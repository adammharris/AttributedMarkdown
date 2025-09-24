import XCTest

@testable import AttributedMarkdown

final class AttributedMarkdownTests: XCTestCase {

    // MARK: - Helpers

    /// Normalizes Markdown for comparison (currently identity; placeholder for future whitespace normalization).
    private func normalize(_ md: String) -> String {
        md
            .replacingOccurrences(of: "\r\n", with: "\n")
    }

    /// Assert that a markdown string round‑trips through AttributedString -> toMarkdown() unchanged.
    // New bridge-based round trip helper using swift-markdown parsing + AST serialization.
    private func assertRoundTripBridge(
        _ markdown: String, file: StaticString = #file, line: UInt = #line
    ) throws {
        let attr = AttributedString(inlineMarkdown: markdown)
        let back = attr.toMarkdownViaAST()
        XCTAssertEqual(
            normalize(markdown),
            normalize(back),
            "Bridge round-trip mismatch.\nOriginal: \(markdown)\nReturned: \(back)",
            file: file,
            line: line
        )
    }

    // MARK: - Inline Emphasis

    func testRoundTripBold() throws {
        try assertRoundTripBridge("**Hello**")
    }

    func testRoundTripItalic() throws {
        try assertRoundTripBridge("*Hello*")
    }

    func testRoundTripStrikethrough() throws {
        try assertRoundTripBridge("~~Hello~~")
    }

    func testRoundTripBoldItalicCombined() throws {
        // For combined emphasis we choose ***text*** as canonical for bold+italic (strong+em).
        try assertRoundTripBridge("***Hello***")
    }

    func testRoundTripStrikethroughBoldItalic() throws {
        try assertRoundTripBridge("~~***Hello***~~")
    }

    // MARK: - Code

    func testRoundTripInlineCodeSimple() throws {
        try assertRoundTripBridge("`code`")
    }

    func testRoundTripInlineCodeContainingBacktick() throws {
        try assertRoundTripBridge("``code`tick``")
    }

    // MARK: - Links

    func testRoundTripSimpleLink() throws {
        try assertRoundTripBridge("[Link](https://example.com)")
    }

    // MARK: - Strikethrough + Other

    func testRoundTripStrikethroughAndBold() throws {
        try assertRoundTripBridge("~~**Hello**~~")
    }

    // MARK: - Escaping

    func testEscapingSpecialCharactersLiteralAsterisk() throws {
        let md = #"Literal: \*star\* and backslash \\ and underscore \_ ok"#
        try assertRoundTripBridge(md)
    }

    func testEscapingBracketAndParenthesis() throws {
        let md = #"Escapes: \[brackets\] and \(parens\)"#
        try assertRoundTripBridge(md)
    }

    func testEscapingTildeInPlainText() throws {
        let md = #"Not strike: \~Hello\~ world"#
        try assertRoundTripBridge(md)
    }

    // MARK: - Plain Text (No Formatting)

    func testPlainTextNoFormatting() {
        let plain = AttributedString("Just plain text.")
        let md = plain.toMarkdown()
        XCTAssertEqual(md, "Just plain text.")
    }

    // Soft line break (single newlines within a paragraph) should be preserved.
    // The serializer now treats single newlines as soft breaks inside the same paragraph,
    // and only double newlines as hard paragraph separators.
    func testSoftLineBreakRoundTrip() throws {
        let md = "Line one\nLine two\nLine three\n"
        try assertRoundTripBridge(md)
    }

    // MARK: - Mixed Multiple Runs

    func testMultipleSequentialStyledRuns() throws {
        let md = "**Bold** *Italic* ~~Strike~~ `code`"
        try assertRoundTripBridge(md)
    }

    // MARK: - Nested Emphasis Variation (Parser Canonicalization)

    func testNestedItalicInsideBoldOriginalVariant() throws {
        let original = "**This *that***"
        let attr = AttributedString(inlineMarkdown: original)
        let back = attr.toMarkdown()
        let reparsed = AttributedString(inlineMarkdown: back)
        XCTAssertEqual(
            attr, reparsed,
            "Re-serialized markdown did not round-trip equivalently via inline bridge.\nOriginal MD: \(original)\nSerialized: \(back)"
        )
    }

    // MARK: - Headings & Lists (Block-Level)

    func testHeadingLevelsRoundTrip() throws {
        let md = "# H1\n\n## H2\n\n### H3\n\n#### H4\n\n##### H5\n\n###### H6\n\n"
        try assertRoundTripBridge(md)
    }

    func testUnorderedListRoundTrip() throws {
        let md = "- one\n- two\n- three\n"
        try assertRoundTripBridge(md)
    }

    func testOrderedListCanonicalNumbering() throws {
        let source = "3. third\n4. fourth\n"
        let expected = "1. third\n2. fourth\n"
        let attr = AttributedString(inlineMarkdown: source)
        let back = attr.toMarkdown()
        XCTAssertEqual(expected, back, "Ordered list should be renumbered starting at 1.")
        try assertRoundTripBridge(expected)
    }

    func testInlineStylingInHeading() throws {
        let md = "## **Bold** and *italic* in heading\n\n"
        try assertRoundTripBridge(md)
    }

    func testInlineStylingInListItems() throws {
        let md = "- **Bold** item\n- *Italic* item\n- ~~***StrikeAll***~~ item\n"
        try assertRoundTripBridge(md)
    }

    // MARK: - Block Quotes

    func testSingleBlockQuote() throws {
        let md = "> Quoted line\n"
        try assertRoundTripBridge(md)
    }

    #if DEBUG
        /// DEBUG helper: dumps attributed runs (text + key block-level attributes) and the
        /// re-serialized markdown so we can inspect where block quote depth is lost.
        private func debugDumpMarkdownSegments(_ markdown: String) {
            let attr = AttributedString(inlineMarkdown: markdown)
            print("=== DEBUG INPUT ===")
            print(markdown)
            print("=== RUNS ===")
            var idx = 0
            for run in attr.runs {
                let slice = attr[run.range]
                let text = String(slice.characters)
                var flags: [String] = []
                if let bq = run[AttributeScopes.AMInlineAttributes.BlockQuoteAttribute.self] {
                    flags.append("bqDepth=\(bq.depth)")
                }
                if let lm = run[AttributeScopes.AMInlineAttributes.ListItemAttribute.self] {
                    flags.append("list=\(lm.kind == .ordered ? "ol" : "ul")#\(lm.ordinal)")
                }
                if let h = run[AttributeScopes.AMInlineAttributes.HeadingLevelAttribute.self] {
                    flags.append("h\(h)")
                }
                if run[AttributeScopes.AMInlineAttributes.CodeAttribute.self] == true {
                    flags.append("code")
                }
                if run[AttributeScopes.AMInlineAttributes.BoldAttribute.self] == true {
                    flags.append("bold")
                }
                if run[AttributeScopes.AMInlineAttributes.ItalicAttribute.self] == true {
                    flags.append("italic")
                }
                if run[AttributeScopes.AMInlineAttributes.StrikethroughAttribute.self] == true {
                    flags.append("strike")
                }
                if let link = run[AttributeScopes.FoundationAttributes.LinkAttribute.self] {
                    flags.append("link=\(link)")
                }
                print("[\(idx)] \"\(text)\" \(flags)")
                idx += 1
            }
            print("=== RE-SERIALIZED ===")
            print(attr.toMarkdownViaAST())
            print("=== END DEBUG ===")
        }
    #endif

    func testNestedBlockQuotes() throws {
        let md = "> Outer\n> > Inner\n> Back to outer\n"
        #if DEBUG
            debugDumpMarkdownSegments(md)
        #endif
        try assertRoundTripBridge(md)
    }

    func testBlockQuoteWithInlineStyles() throws {
        let md = "> **Bold** and *italic* and ~~strike~~ inside quote\n"
        try assertRoundTripBridge(md)
    }

    // MARK: - Fenced Code Blocks

    func testFencedCodeBlockSimple() throws {
        let md = "```\nprint(\"Hello\")\n```\n\n"
        try assertRoundTripBridge(md)
    }

    func testFencedCodeBlockWithLanguage() throws {
        let md = "```swift\nlet x = 1\n```\n\n"
        try assertRoundTripBridge(md)
    }

    func testFencedCodeBlockContainingBackticks() throws {
        let md = "````\n```\ninner fenced\n```\n````\n\n"
        try assertRoundTripBridge(md)
    }

    func testBlockQuoteContainingCodeBlock() throws {
        let md = "> Intro\n\n```swift\nprint(\"hi\")\n```\n\n"
        try assertRoundTripBridge(md)
    }
}
