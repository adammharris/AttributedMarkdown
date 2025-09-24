# AttributedMarkdown

A Swift Package providing a deterministic, non-lossy bridge from `AttributedString` back to a Markdown subset. Foundation already parses Markdown into `AttributedString`; this package supplies the missing `AttributedString.toMarkdown()` serializer.

## Features (Current Scope)

- Inline styles: bold (**), italic (*), strikethrough (~~)
- Inline code spans (backticks, with automatic fence length handling for embedded backticks)
- Links `[text](url)`
- Deterministic marker ordering (~~ > ** > *)
- Escaping of special characters in plain text: `\`, `*`, `_`, `[`, `]`, `` ` ``, `(`, `)`, `~`

## Planned (Roadmap / Stretch)

- Headings (#, ##, ###) via `PresentationIntent`
- Ordered / unordered lists
- Blockquotes
- Fenced code blocks (multiline)
- Run coalescing for cleaner minimal markup
- Additional context-aware escaping logic

## Installation

Add the dependency in `Package.swift`:

    .package(url: "https://example.com/AttributedMarkdown.git", branch: "main")

Then add `"AttributedMarkdown"` to your target dependencies.

## Usage

Basic round trip:

    import AttributedMarkdown

    let md = "**Bold text** and *italic text*"
    let attr = try AttributedString(markdown: md)
    print(attr.toMarkdown()) // "**Bold text** and *italic text*"

Inline code with embedded backticks is fenced safely:

    let code = "`echo \\`whoami\\``"
    let attr = try AttributedString(markdown: "``\(code)``")
    print(attr.toMarkdown()) // `` `echo \`whoami\`` ``

Links:

    let linkMD = "[Apple](https://www.apple.com)"
    let linkAttr = try AttributedString(markdown: linkMD)
    assert(linkAttr.toMarkdown() == linkMD)

Mixed styling (bold + italic + strikethrough) is serialized in a fixed outer→inner order:

    let combo = try AttributedString(markdown: "~~***Wow***~~")
    print(combo.toMarkdown()) // "~~***Wow***~~"

## Determinism & Round-Trip Goals

For the supported subset you should expect (ignoring inconsequential whitespace):

    let original = "**Hello**"
    let attr = try AttributedString(markdown: original)
    let back = attr.toMarkdown()
    precondition(original == back)

Unsupported attributes (fonts, colors, etc.) are ignored—they do not break serialization.

## Testing

Run the test suite:

    swift test

Tests cover:

- Individual styles (bold / italic / strikethrough / code / link)
- Nesting combinations
- Escaping edge cases
- Round-trip integrity

## Contributing

Contributions that expand the supported Markdown subset while maintaining determinism and round-trip safety are welcome. Please accompany changes with tests.

## License

MIT (add license file as desired).