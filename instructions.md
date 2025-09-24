
You are to implement a Swift Package called AttributedMarkdown.

Its purpose:
	•	Provide a two-way bridge between Markdown and AttributedString.
	•	Apple’s Foundation already supports AttributedString(markdown:) (Markdown → AttributedString).
	•	The missing piece: a non-lossy serializer for the Markdown subset → AttributedString.toMarkdown().

⸻

Requirements

Package Setup
	•	Create a Swift Package Manager (SPM) project named AttributedMarkdown.
	•	Targets:
	•	AttributedMarkdown (library target).
	•	AttributedMarkdownTests (unit tests).

Core Functionality

Implement an extension to AttributedString:

extension AttributedString {
    func toMarkdown() -> String
}

This should serialize the attributed runs back into Markdown text.

Supported Markdown features

Start with this subset:
	•	Bold → **text**
	•	Italic → *text*
	•	Strikethrough → ~~text~~
	•	Links → [text](url)
	•	Inline code → backticks
	•	Headings (H1–H3) → #, ##, ###
	•	Unordered lists → - item
	•	Ordered lists → 1. item

Constraints
	•	Serializer must be deterministic: always emit the same Markdown markers for the same attributes.
	•	Round-trip safety:
	•	For supported features, try AttributedString(markdown: md).toMarkdown() should equal md (ignoring whitespace differences).
	•	Unsupported attributes (color, font size, etc.) should be ignored gracefully — not break serialization.

⸻

Testing
	•	Write unit tests in AttributedMarkdownTests.
	•	Cover:
	•	Bold, italic, strikethrough, links, inline code, headings, lists.
	•	Nesting (e.g. bold+italic inside the same run).
	•	Escaping: special characters like *, _, [, ], ` should be escaped when they appear in plain text.
	•	Add round-trip tests:

func testRoundTripBold() throws {
    let md = "**Hello**"
    let attr = try AttributedString(markdown: md)
    let back = attr.toMarkdown()
    XCTAssertEqual(md, back)
}



⸻

Deliverables
	•	A working Swift package with:
	•	Sources/AttributedMarkdown/AttributedMarkdown.swift
	•	Tests/AttributedMarkdownTests/AttributedMarkdownTests.swift
	•	Documented toMarkdown() method.
	•	Example in README:

let md = "**Bold text** and *italic text*"
let attr = try AttributedString(markdown: md)
print(attr.toMarkdown()) // "**Bold text** and *italic text*"



⸻

Stretch Goals (if time allows)
	•	Add support for blockquotes (>).
	•	Add support for fenced code blocks.
	•	Provide an initializer init(markdown:options:) wrapper around Apple’s parser for consistency.
	•	Provide convenience helpers for detecting if an AttributedString run is Markdown-safe.

⸻

Important:
Focus on making the core toMarkdown() serializer robust and testable for the chosen subset before adding extras.

⸻

👉 This prompt gives the agent everything: scope, features, constraints, tests, and output structure.

⸻

