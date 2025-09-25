import Foundation

#if canImport(SwiftUI)
    import SwiftUI
#endif

/// LineStructureNormalizer
///
/// Goal:
/// 1. Preserve (reconstruct) original blank line runs (multiple consecutive empty lines) that
///    were dropped by the Markdown → `AttributedString` bridge (which produces a
///    style‑annotated linear content sequence without explicit paragraph‐separating blank lines).
/// 2. Inject `InlinePresentationIntent` flags (strong / emphasis / code) derived from the
///    custom `AMInlineAttributes` so that SwiftUI's `TextEditor` can visually display bold,
///    italic, and code styles without the UI layer needing to know about custom attributes.
///
/// Rationale:
/// SwiftUI’s `TextEditor` only renders standard inline presentation attributes (and a few
/// other native styling attributes). Our bridge stores semantic formatting using custom
/// keys (`AMInlineAttributes.BoldAttribute`, etc.). Without translating those into
/// `InlinePresentationIntent`, all styled text appears plain in the editor.
/// Additionally, blank line separation between paragraphs is lost because the
/// intermediate attributed form only retains soft line breaks and structural newlines
/// (e.g., those for headings / lists / quotes), not author‑intentional empty paragraphs.
/// This normalizer heuristically re‑inserts those blank lines.
///
/// NOTE (Heuristic Nature):
/// Reconstructing blank line placement exactly is non‑trivial because the original Markdown
/// source includes formatting markers (`*`, `_`, `>`, list bullets, heading hashes, code
/// fences, etc.) that do not appear in the parsed `AttributedString` content. That
/// means we cannot reliably map raw source character offsets to styled content
/// offsets one‑for‑one. Instead, we:
///   1. Analyze the original Markdown to locate runs of consecutive blank lines.
///   2. Count non‑blank logical lines (lines with visible content) in both the
///      original and the provisional attributed text.
///   3. Insert missing blank newline runs into the attributed text at positions
///      relative to their preceding non‑blank line indices.
/// This approach preserves vertical rhythm for typical prose / journal scenarios
/// (paragraphs separated by one or more empty lines) while avoiding deep re‑parsing.
///
/// If future fidelity requires exact per‑line reconstruction (including quote / list
/// marker alignment), a more advanced “full rebuild” approach—similar to
/// `QuoteDepthNormalizer` but extended for all block types—can replace this heuristic.
///
/// Public API:
///   LineStructureNormalizer.normalize(original:provisional:)
///
/// Usage:
///   let parsed = AttributedString(inlineMarkdown: sourceMarkdown)
///   let display = LineStructureNormalizer.normalize(original: sourceMarkdown, provisional: parsed)
///   // Bind `display` to SwiftUI TextEditor
///
struct LineStructureNormalizer {

    // MARK: - Public Entry Point

    static func normalize(
        original: String,
        provisional: AttributedString
    ) -> AttributedString {

        // 1. Inject display intents so SwiftUI can render styling.
        var withIntents = injectInlinePresentationIntents(from: provisional)

        // 2. Reconstruct blank line runs (if any were lost).
        let blankRuns = detectBlankLineRuns(in: original)
        if blankRuns.isEmpty {
            return withIntents
        }

        return insertBlankLines(blankRuns, into: withIntents, original: original)
    }

    // MARK: - Blank Line Run Model

    /// Represents a sequence of one or more consecutive blank lines in the original markdown.
    /// - `precededByContentLineIndex` = index (0‑based) of the non‑blank *content* line immediately before this run.
    ///   If `nil`, the run occurs at the very start of the document.
    /// - `runLength` = number of blank lines (each blank line corresponds to one newline character that
    ///   represents an empty line; visually you usually see runLength vertical gaps).
    private struct BlankRun {
        let precededByContentLineIndex: Int?
        let runLength: Int
    }

    // MARK: - 1. Detect blank line runs in original source

    private static func detectBlankLineRuns(in source: String) -> [BlankRun] {
        // Split into raw lines while preserving trailing newline information.
        // We'll treat a "blank line" as a line whose trimmed (whitespace) content is empty.
        var runs: [BlankRun] = []

        var currentLineContent = String()
        var contentLineCount = 0
        var idx = source.startIndex

        // Track consecutive blank lines after last content line.
        var pendingBlankCountAfterContent: Int = 0
        // Track leading blank lines before any content line.
        var leadingBlankCount: Int = 0
        var seenFirstContent = false

        func finalizeLine(isLast: Bool) {
            let trimmed = currentLineContent.trimmingCharacters(in: .whitespacesAndNewlines)

            let isBlank = trimmed.isEmpty
            if isBlank {
                if seenFirstContent {
                    pendingBlankCountAfterContent += 1
                } else {
                    leadingBlankCount += 1
                }
            } else {
                // Just transitioned from content line or leading blanks.
                if !seenFirstContent && leadingBlankCount > 0 {
                    // Leading blank run (no preceding content line)
                    runs.append(
                        BlankRun(precededByContentLineIndex: nil, runLength: leadingBlankCount))
                    leadingBlankCount = 0
                }
                // If we had a trailing group of blanks after previous content (already recorded on next content)
                // We only record blank runs when we encounter the *next* content line (so they belong between content lines).
                if pendingBlankCountAfterContent > 0 {
                    runs.append(
                        BlankRun(
                            precededByContentLineIndex: contentLineCount - 1,
                            runLength: pendingBlankCountAfterContent
                        )
                    )
                    pendingBlankCountAfterContent = 0
                }
                seenFirstContent = true
                contentLineCount += 1
            }

            currentLineContent.removeAll(keepingCapacity: true)
        }

        while idx < source.endIndex {
            let ch = source[idx]
            if ch == "\n" {
                finalizeLine(isLast: false)
            } else {
                currentLineContent.append(ch)
            }
            idx = source.index(after: idx)
        }
        // Final line (could be blank or content; if last line had no trailing newline and was blank sequence, treat accordingly).
        if !currentLineContent.isEmpty {
            finalizeLine(isLast: true)
        } else {
            // If file ends with newline(s) we have already processed them as blank lines above.
        }

        // If file ends with blank lines following a content line, they have not yet
        // been recorded (because we only emit on seeing next content). Record them now.
        if pendingBlankCountAfterContent > 0 {
            runs.append(
                BlankRun(
                    precededByContentLineIndex: contentLineCount - 1,
                    runLength: pendingBlankCountAfterContent
                )
            )
            pendingBlankCountAfterContent = 0
        }

        // If the document ended up containing only blank lines, capture them as a single leading run.
        if !seenFirstContent && leadingBlankCount > 0 {
            runs.append(BlankRun(precededByContentLineIndex: nil, runLength: leadingBlankCount))
        }

        return runs
    }

    // MARK: - 2. Insert blank lines (heuristic alignment)

    private static func insertBlankLines(
        _ runs: [BlankRun],
        into attributed: AttributedString,
        original: String
    ) -> AttributedString {

        // Collect indices of newline characters in the provisional attributed text.
        // Each newline corresponds (heuristically) to the end of a "content line" or structural line.
        let provisionalString = String(attributed.characters)
        var newlinePositions: [Int] = []
        newlinePositions.reserveCapacity(32)
        for (i, ch) in provisionalString.enumerated() where ch == "\n" {
            newlinePositions.append(i)
        }

        // Heuristic assumption:
        // content line index 'k' (0-based) ends at newlinePositions[k] if that index exists.
        // If provisional text has fewer newlinePositions than content lines counted in original,
        // we will append missing newline(s) at the end.

        var mutable = attributed
        // We'll insert from last to first to keep earlier indices stable.
        let descending = runs.enumerated().reversed()

        for (_, run) in descending {
            let blankCount = run.runLength
            guard blankCount > 0 else { continue }

            // Build insertion string = blankCount newline characters (each blank line is one "\n").
            let insertion = AttributedString(String(repeating: "\n", count: blankCount))

            if let preceding = run.precededByContentLineIndex {
                // Need to find insertion point: immediately after the newline ending that content line.
                if preceding < newlinePositions.count {
                    let utf16Offset = newlinePositions[preceding] + 1  // after the newline char
                    if let insertionIndex = stringIndex(
                        in: mutable,
                        atUTF16Offset: utf16Offset
                    ) {
                        mutable.insert(insertion, at: insertionIndex)
                        // Adjust stored newlinePositions for indices > preceding
                        for i in (preceding + 1)..<newlinePositions.count {
                            newlinePositions[i] += blankCount  // we added blankCount chars
                        }
                    } else {
                        // Fallback: append at end if index resolution failed
                        mutable.append(insertion)
                    }
                } else {
                    // Not enough newline markers present; append at end
                    mutable.append(insertion)
                }
            } else {
                // Leading blank lines: insert at start.
                // Leading blank lines: insert at start (AttributedString.startIndex is already valid)
                let start = mutable.startIndex
                mutable.insert(insertion, at: start)
                // Shift all newline positions
                for i in 0..<newlinePositions.count {
                    newlinePositions[i] += blankCount
                }
            }
        }

        return mutable
    }

    // MARK: - 3. Inject Inline Presentation Intents

    private static func injectInlinePresentationIntents(from attr: AttributedString)
        -> AttributedString
    {
        var rebuilt = AttributedString()
        // (reserveCapacity unavailable on AttributedString; skip for portability)

        for run in attr.runs {
            var fragment = AttributedString(attr[run.range])

            // Derive InlinePresentationIntent from custom attributes.
            var intent =
                fragment[
                    AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self]
                ?? InlinePresentationIntent()

            if run[AttributeScopes.AMInlineAttributes.CodeAttribute.self] == true {
                intent.insert(.code)
                // Code supersedes emphasis (avoid double styling ambiguity).
                intent.remove(.stronglyEmphasized)
                intent.remove(.emphasized)
            } else {
                if run[AttributeScopes.AMInlineAttributes.BoldAttribute.self] == true {
                    intent.insert(.stronglyEmphasized)
                }
                if run[AttributeScopes.AMInlineAttributes.ItalicAttribute.self] == true {
                    intent.insert(.emphasized)
                }
            }

            if !intent.isEmpty {
                fragment[
                    AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self
                ] = intent
            }

            // Optional: map custom strike to Foundation strikethrough style (if supported).
            // Strikethrough: SwiftUI TextEditor does not rely on NSAttributedString raw key here; leave custom attribute only.

            rebuilt.append(fragment)
        }
        return rebuilt
    }

    // MARK: - Utility: Convert UTF16 offset -> AttributedString.Index

    /// Convert a UTF16 offset (relative to the `AttributedString`'s full string view) into an `AttributedString.Index`.
    /// Returns nil if the offset is out of range.
    private static func stringIndex(in attr: AttributedString, atUTF16Offset offset: Int)
        -> AttributedString.Index?
    {
        let full = String(attr.characters)
        guard offset >= 0, offset <= full.utf16.count else { return nil }
        let stringIdx = String.Index(utf16Offset: offset, in: full)
        return AttributedString.Index(stringIdx, within: attr)
    }
}

// MARK: - Convenience Extension

extension AttributedString {
    /// Produce a display‑ready `AttributedString` with:
    ///  - Bold / italic / code mapped into `InlinePresentationIntent`
    ///  - Blank line runs re‑inserted (heuristically) from the original Markdown
    ///
    /// This does NOT mutate the receiver; it returns a new value.
    public func normalizedForDisplayPreservingBlankLines(originalMarkdown: String)
        -> AttributedString
    {
        LineStructureNormalizer.normalize(original: originalMarkdown, provisional: self)
    }
}
