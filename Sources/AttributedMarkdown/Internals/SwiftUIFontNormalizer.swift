import Foundation

/// SwiftUI font normalization utilities (resolver-based).
///
/// Motivation:
/// When editing with SwiftUI's native TextEditor using AttributedString, the editor often applies
/// SwiftUI-specific font attributes (e.g., bold/italic) instead of semantic inline editing intents.
/// The AttributedMarkdown serializer prefers semantic markers (Foundation's InlinePresentationIntent)
/// to produce canonical Markdown (** for bold, * for italic).
///
/// This file provides a resolver-driven normalizer so that apps can supply their own logic
/// to determine whether a given run should be considered bold and/or italic, without this package
/// taking a direct dependency on SwiftUI or any of its resolution APIs.
///
/// Typical usage (in your app):
/// - Build a resolver closure that inspects run attributes (including any SwiftUI-specific ones),
///   and returns booleans (isBold, isItalic). For example, your resolver might:
///     - Look for a SwiftUI Font attribute and/or resolve it (if you have a resolution mechanism)
///     - Look at platform font traits by bridging to NSAttributedString and checking bold/italic traits
/// - Pass this resolver to `normalizedForMarkdown(swiftUIFontResolver:)` or directly to
///   `toMarkdown(swiftUIFontResolver:)`.
///
/// Behavior:
/// - If a run is already marked as inline code (via semantic attributes or InlinePresentationIntent),
///   this normalizer does not add emphasis flags (code supersedes emphasis).
/// - Existing InlinePresentationIntent flags are preserved; the resolver only inserts stronglyEmphasized
///   and/or emphasized when it returns true. It will not remove existing flags if the resolver returns false.
/// - This module does not import SwiftUI; you own the resolver logic so you can use SwiftUI in the app target.
enum SwiftUIFontNormalizer {
    /// Internal core normalization implementation.
    static func normalize(
        _ input: AttributedString,
        using resolver: SwiftUIFontResolver
    ) -> AttributedString {
        var output = AttributedString()

        for run in input.runs {
            var fragment = AttributedString(input[run.range])

            // If run is code, do not apply emphasis via resolver.
            let hasSemanticCode =
                run[AttributeScopes.AMInlineAttributes.CodeAttribute.self] == true
            let hasIntentCode =
                run[
                    AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self
                ]?.contains(.code) == true

            if !hasSemanticCode && !hasIntentCode {
                let decision = resolver(run, input[run.range])

                if decision.isBold || decision.isItalic {
                    var intent =
                        fragment[
                            AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute
                                .self
                        ] ?? InlinePresentationIntent()

                    if decision.isBold {
                        intent.insert(.stronglyEmphasized)
                    }
                    if decision.isItalic {
                        intent.insert(.emphasized)
                    }
                    if !intent.isEmpty {
                        fragment[
                            AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute
                                .self
                        ] = intent
                    }
                }
            }

            output.append(fragment)
        }

        return output
    }
}

/// Resolver that decides whether a run should be considered bold and/or italic.
/// - Parameters:
///   - run: The current attributed run with its attributes.
///   - slice: The substring for the run (text content and attributes).
/// - Returns: A pair of booleans (isBold, isItalic). Return true to insert the corresponding
///            InlinePresentationIntent flag; returning false leaves the flag unchanged.
public typealias SwiftUIFontResolver =
    (_ run: AttributedString.Runs.Run, _ slice: AttributedSubstring) -> (
        isBold: Bool, isItalic: Bool
    )

extension AttributedString {
    /// Returns a copy of this AttributedString with semantic inline intents inferred via a resolver.
    /// - Parameter swiftUIFontResolver: A closure that inspects each run and indicates whether it
    ///   should be bold and/or italic. See `SwiftUIFontResolver` for details.
    /// - Returns: Normalized AttributedString suitable for Markdown serialization.
    public func normalizedForMarkdown(
        swiftUIFontResolver: SwiftUIFontResolver
    ) -> AttributedString {
        SwiftUIFontNormalizer.normalize(self, using: swiftUIFontResolver)
    }

    /// Convenience overload: normalizes via resolver, then serializes to Markdown.
    /// - Parameter swiftUIFontResolver: A closure that inspects each run and indicates whether it
    ///   should be bold and/or italic. See `SwiftUIFontResolver` for details.
    /// - Returns: Markdown string.
    public func toMarkdown(
        swiftUIFontResolver: SwiftUIFontResolver
    ) -> String {
        SwiftUIFontNormalizer.normalize(self, using: swiftUIFontResolver).toMarkdown()
    }
}
