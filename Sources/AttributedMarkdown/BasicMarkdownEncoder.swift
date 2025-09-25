import Foundation

/// A lightweight Markdown encoder that targets the minimal feature set we care about for the
/// first milestone of DiaryX: bold, italic, and newline preservation. Everything else is emitted
/// as plain text with the necessary escaping so it does not accidentally turn into Markdown syntax.
///
/// This sits alongside the richer `toMarkdown()` pipeline but keeps the implementation easier to
/// audit while we iterate on the native TextEditor integration.
public struct BasicMarkdownEncoder {

    public init() {}

    /// Serializes the supplied attributed string to Markdown.
    /// - Parameter attributed: Source attributed string (typically produced by the SwiftUI editor).
    /// - Returns: Markdown string representing bold (`**`) and italic (`*`) markers; newline
    ///   characters are preserved verbatim.
    public func encode(_ attributed: AttributedString) -> String {
        var output = String()
        output.reserveCapacity(attributed.characters.count + attributed.characters.count / 4)

        // Track which emphasis markers are currently open so we can close/reopen as attributes change.
        enum Wrapper: String, CaseIterable {
            case bold = "**"
            case italic = "*"
        }

        func desiredWrappers(for style: RunStyle) -> [Wrapper] {
            var wrappers: [Wrapper] = []
            if style.isBold { wrappers.append(.bold) }
            if style.isItalic { wrappers.append(.italic) }
            return wrappers
        }

        var open: [Wrapper] = []

        for run in attributed.runs {
            let fragment = AttributedString(attributed[run.range])
            guard !fragment.characters.isEmpty else { continue }

            let style = RunStyle(run: run)
            let desired = desiredWrappers(for: style)

            // Diff currently open wrappers with the desired ones for this run.
            var commonPrefix = 0
            while commonPrefix < open.count,
                commonPrefix < desired.count,
                open[commonPrefix] == desired[commonPrefix]
            {
                commonPrefix += 1
            }

            if commonPrefix < open.count {
                for wrapper in open[commonPrefix...].reversed() {
                    output.append(wrapper.rawValue)
                }
                open.removeLast(open.count - commonPrefix)
            }

            if commonPrefix < desired.count {
                for wrapper in desired[commonPrefix...] {
                    output.append(wrapper.rawValue)
                    open.append(wrapper)
                }
            }

            output.append(escapePlain(String(fragment.characters)))
        }

        // Close any wrappers that remained open at the end of the string.
        if !open.isEmpty {
            for wrapper in open.reversed() {
                output.append(wrapper.rawValue)
            }
        }

        return output
    }
}

// MARK: - Public Convenience API

extension AttributedString {
    /// Convenience helper to run the basic encoder.
    public func toBasicMarkdown() -> String {
        BasicMarkdownEncoder().encode(self)
    }
}

// MARK: - Helpers

private struct RunStyle {
    let isBold: Bool
    let isItalic: Bool

    init(run: AttributedString.Runs.Run) {
        var bold = false
        var italic = false

        if let inlineIntent =
            run[AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self]
        {
            if inlineIntent.contains(.stronglyEmphasized) { bold = true }
            if inlineIntent.contains(.emphasized) { italic = true }
        }

        if run[AttributeScopes.AMInlineAttributes.BoldAttribute.self] == true {
            bold = true
        }
        if run[AttributeScopes.AMInlineAttributes.ItalicAttribute.self] == true {
            italic = true
        }

        isBold = bold
        isItalic = italic
    }
}

private func escapePlain(_ text: String) -> String {
    var escaped = String()
    escaped.reserveCapacity(text.count)
    for character in text {
        switch character {
        case "*", "_", "[", "]", "(", ")", "~", "`":
            escaped.append("\\\(character)")
        case "\\":
            escaped.append("\\\\")
        default:
            escaped.append(character)
        }
    }
    return escaped
}
