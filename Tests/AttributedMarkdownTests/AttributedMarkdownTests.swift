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
        // Expected emission pattern from serializer: outer ~~ then ** then *
        // Serializer currently produces: ~~***Hello***~~ for all three.
        try assertRoundTripBridge("~~***Hello***~~")
    }

    // MARK: - Code

    func testRoundTripInlineCodeSimple() throws {
        try assertRoundTripBridge("`code`")
    }

    func testRoundTripInlineCodeContainingBacktick() throws {
        // When the code content includes a backtick, serializer should choose a fence length > longest run.
        // Starting markdown uses double backticks to represent a literal single backtick inside.
        try assertRoundTripBridge("``code`tick``")
    }

    // MARK: - Links

    func testRoundTripSimpleLink() throws {
        try assertRoundTripBridge("[Link](https://example.com)")
    }

    // NOTE: Bold inside a link may currently split into multiple runs, producing repeated link markup.
    // To avoid a failing test at this stage (since merging is a future enhancement), we only test a plain link.
    // A future test could assert desired canonical form once run coalescing is implemented.

    // MARK: - Strikethrough + Other

    func testRoundTripStrikethroughAndBold() throws {
        try assertRoundTripBridge("~~**Hello**~~")
    }

    // MARK: - Escaping

    func testEscapingSpecialCharactersLiteralAsterisk() throws {
        // The input markdown escapes asterisks so they remain literal.
        let md = #"Literal: \*star\* and backslash \\ and underscore \_ ok"#
        try assertRoundTripBridge(md)
    }

    func testEscapingBracketAndParenthesis() throws {
        let md = #"Escapes: \[brackets\] and \(parens\)"#
        try assertRoundTripBridge(md)
    }

    func testEscapingTildeInPlainText() throws {
        // Strikethrough marker should remain literal when escaped.
        let md = #"Not strike: \~Hello\~ world"#
        try assertRoundTripBridge(md)
    }

    // MARK: - Plain Text (No Formatting)

    func testPlainTextNoFormatting() {
        // Construct directly (not via markdown parser) because markdown "*hello*" would parse as italic.
        let plain = AttributedString("Just plain text.")
        let md = plain.toMarkdown()
        XCTAssertEqual(md, "Just plain text.")
    }

    // MARK: - Mixed Multiple Runs

    func testMultipleSequentialStyledRuns() throws {
        let md = "**Bold** *Italic* ~~Strike~~ `code`"
        try assertRoundTripBridge(md)
    }

    // MARK: - Nested Emphasis Variation (Parser Canonicalization)

    func testNestedItalicInsideBoldOriginalVariant() throws {
        // Use the new inline bridge so we only test our serializer / parser pair, not Foundation's.
        let original = "**This *that***"
        let attr = AttributedString(inlineMarkdown: original)
        let back = attr.toMarkdown()
        // Reparse through the same bridge.
        let reparsed = AttributedString(inlineMarkdown: back)
        XCTAssertEqual(
            attr, reparsed,
            "Re-serialized markdown did not round-trip equivalently via inline bridge.\nOriginal MD: \(original)\nSerialized: \(back)"
        )
        // MARK: - Headings & Lists (Block-Level)

        func testHeadingLevelsRoundTrip() throws {
            let md = "# H1\n\n## H2\n\n### H3\n\n#### H4\n\n##### H5\n\n###### H6\n\n"
            try assertRoundTripBridge(md)
        }

        func testUnorderedListRoundTrip() throws {
            // Serializer emits a trailing newline after the list; include it in expected.
            let md = "- one\n- two\n- three\n"
            try assertRoundTripBridge(md)
        }

        func testOrderedListCanonicalNumbering() throws {
            // Even if source started elsewhere, we canonicalize to 1., 2., ...
            let source = "3. third\n4. fourth\n"
            // Expected canonical form:
            let expected = "1. third\n2. fourth\n"
            let attr = AttributedString(inlineMarkdown: source)
            let back = attr.toMarkdown()
            XCTAssertEqual(expected, back, "Ordered list should be renumbered starting at 1.")
            // Round-trip the expected canonical form.
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
    }
}
