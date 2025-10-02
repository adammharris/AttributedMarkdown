import AttributedMarkdown
import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Rich-text editor that keeps a "live" buffer (TextEditor-bound) and a canonical semantic
/// representation for Markdown export. Inline formatting is derived from SwiftUI fonts while typing
/// and converted into Markdown-friendly intents on commit.
struct DocumentEditorView: View {
    // MARK: Environment & Focus
    @Environment(\.fontResolutionContext) private var fontResolutionContext
    @FocusState private var editorFocused: Bool

    // MARK: Dual Model State
    @State private var editorBuffer: AttributedString = AttributedString()
    @State private var canonical: AttributedString = AttributedString()

    // MARK: UI State
    @State private var draftTitle: String
    @State private var selection = AttributedTextSelection()
    @State private var pendingSerializationWork: DispatchWorkItem?

    // MARK: Callbacks
    var onTitleChange: ((String) -> Void)?
    var onContentChange: ((AttributedString) -> Void)?
    var onLiveContentChange: ((AttributedString) -> Void)?
    var onMarkdownChange: ((String) -> Void)?
    var onLiveMarkdownChange: ((String) -> Void)?

    // MARK: Configuration
    private let livePreviewDebounce: TimeInterval = 0.4

    // MARK: Init
    init(
        draftTitle: String,
        initialMarkdown: String,
        onTitleChange: ((String) -> Void)? = nil,
        onContentChange: ((AttributedString) -> Void)? = nil,
        onLiveContentChange: ((AttributedString) -> Void)? = nil,
        onMarkdownChange: ((String) -> Void)? = nil,
        onLiveMarkdownChange: ((String) -> Void)? = nil
    ) {
        _draftTitle = State(initialValue: draftTitle)

        let preparedMarkdown = Self.prepareMarkdownForEditorDisplay(initialMarkdown)
        let initialCanonical = AttributedString(inlineMarkdown: preparedMarkdown)
        _canonical = State(initialValue: initialCanonical)
        _editorBuffer = State(initialValue: Self.makeEditorBuffer(from: initialCanonical))

        self.onTitleChange = onTitleChange
        self.onContentChange = onContentChange
        self.onLiveContentChange = onLiveContentChange
        self.onMarkdownChange = onMarkdownChange
        self.onLiveMarkdownChange = onLiveMarkdownChange
    }

    // MARK: Body
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            editor
            toolbar
        }
        .onChange(of: draftTitle) { _, newValue in
            onTitleChange?(newValue)
        }
        .onChange(of: editorBuffer) { _, newValue in
            logAttributes(for: newValue)
            scheduleLivePreview(for: newValue)
        }
        .onChange(of: editorFocused) { wasFocused, isFocused in
            if wasFocused == true && isFocused == false {
                commitCanonical()
            }
        }
    }

    // MARK: Subviews
    private var header: some View {
        TextField("Title", text: $draftTitle)
            .font(.title2.weight(.semibold))
            .textFieldStyle(.roundedBorder)
            .padding([.horizontal, .top])
    }

    private var editor: some View {
        TextEditor(text: $editorBuffer, selection: $selection)
            .focused($editorFocused)
            .padding(.horizontal, 4)
            .font(.body)
            .contextMenu {
                Button {
                    toggleFontTrait(.bold)
                } label: {
                    Label("Bold", systemImage: "bold")
                }

                Button {
                    toggleFontTrait(.italic)
                } label: {
                    Label("Italic", systemImage: "italic")
                }

                Button {
                    toggleStrikethrough()
                } label: {
                    Label("Strikethrough", systemImage: "strikethrough")
                }

                Button {
                    toggleInlineCode()
                } label: {
                    Label("Inline Code", systemImage: "chevron.left.slash.chevron.right")
                }
            }
    }

    private var toolbar: some View {
        HStack(spacing: 16) {
            Button {
                toggleFontTrait(.bold)
            } label: {
                Label("Bold", systemImage: "bold")
            }
            .keyboardShortcut("b", modifiers: [.command])

            Button {
                toggleFontTrait(.italic)
            } label: {
                Label("Italic", systemImage: "italic")
            }
            .keyboardShortcut("i", modifiers: [.command])

            Button {
                toggleStrikethrough()
            } label: {
                Label("Strikethrough", systemImage: "strikethrough")
            }
            .keyboardShortcut("x", modifiers: [.command, .shift])

            Button {
                toggleInlineCode()
            } label: {
                Label("Inline Code", systemImage: "chevron.left.slash.chevron.right")
            }
            .keyboardShortcut("c", modifiers: [.command, .option])

            Spacer()

            Button {
                commitCanonical()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: [.command])
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        #if canImport(AppKit)
            .background(Color(nsColor: NSColor.windowBackgroundColor))
        #else
            .background(Color(.secondarySystemBackground))
        #endif
    }

    // MARK: Live Preview (Debounced)
    private func scheduleLivePreview(for buffer: AttributedString) {
        pendingSerializationWork?.cancel()
        let snapshot = buffer
        let work = DispatchWorkItem {
            let normalized = snapshot.normalizedForMarkdown(swiftUIFontResolver: markdownResolver)
            let liveMD = normalized.toBasicMarkdown()
            onLiveMarkdownChange?(liveMD)
            onLiveContentChange?(snapshot)
        }
        pendingSerializationWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + livePreviewDebounce, execute: work)
    }

    // MARK: Commit (Canonical Update)
    private func commitCanonical() {
        pendingSerializationWork?.cancel()

        canonical = editorBuffer.normalizedForMarkdown(swiftUIFontResolver: markdownResolver)
        let md = canonical.toBasicMarkdown()

        onContentChange?(canonical)
        onMarkdownChange?(md)
    }

    // MARK: Formatting Actions
    private enum FontToggle { case bold, italic }

    private func toggleFontTrait(_ kind: FontToggle) {
        editorBuffer.transformAttributes(in: &selection) { container in
            guard container[AttributeScopes.AMInlineAttributes.CodeAttribute.self] != true else {
                return
            }
            let baseFont = container.font ?? .body
            let resolved = baseFont.resolve(in: fontResolutionContext)
            var wantsBold = resolved.isBold
            var wantsItalic = resolved.isItalic

            switch kind {
            case .bold:
                wantsBold.toggle()
            case .italic:
                wantsItalic.toggle()
            }

            var newFont: Font = .body
            if wantsBold {
                newFont = newFont.weight(.bold)
            }
            if wantsItalic {
                newFont = newFont.italic()
            }
            container.font = newFont
        }
    }

    private func toggleStrikethrough() {
        editorBuffer.transformAttributes(in: &selection) { container in
            guard container[AttributeScopes.AMInlineAttributes.CodeAttribute.self] != true else {
                return
            }
            let isActive = container[AttributeScopes.AMInlineAttributes.StrikethroughAttribute.self]
                == true || container.strikethroughStyle != nil
            if isActive {
                container[AttributeScopes.AMInlineAttributes.StrikethroughAttribute.self] = nil
                container.strikethroughStyle = nil
            } else {
                container[AttributeScopes.AMInlineAttributes.StrikethroughAttribute.self] = true
                container.strikethroughStyle = Text.LineStyle(pattern: .solid)
            }
        }
    }

    private func toggleInlineCode() {
        editorBuffer.transformAttributes(in: &selection) { container in
            let isActive = container[AttributeScopes.AMInlineAttributes.CodeAttribute.self] == true
            if isActive {
                container[AttributeScopes.AMInlineAttributes.CodeAttribute.self] = nil
                container.font = .body
            } else {
                container[AttributeScopes.AMInlineAttributes.CodeAttribute.self] = true
                container[AttributeScopes.AMInlineAttributes.StrikethroughAttribute.self] = nil
                container.strikethroughStyle = nil
                container.font = (container.font ?? .body).monospaced()
            }
        }
    }

    // MARK: Markdown Resolver (for live & commit serialization)
    private var markdownResolver: SwiftUIFontResolver {
        { run, _ in
            if let font = run[AttributeScopes.SwiftUIAttributes.FontAttribute.self] {
                let resolved = font.resolve(in: fontResolutionContext)
                return (resolved.isBold, resolved.isItalic)
            }
            if let intent =
                run[AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self]
            {
                return (intent.contains(.stronglyEmphasized), intent.contains(.emphasized))
            }
            return (false, false)
        }
    }

    // MARK: Instrumentation
    private func logAttributes(for buffer: AttributedString) {
        let characterCount = buffer.characters.count
        print("[DocumentEditor] editorBuffer changed - \(characterCount) chars, \(buffer.runs.count) runs")

        var offset = 0

        for (index, run) in buffer.runs.enumerated() {
            let fragment = AttributedString(buffer[run.range])
            let snippet = String(fragment.characters).replacingOccurrences(of: "\n", with: "\\n")
            let length = fragment.characters.count
            let lower = offset
            let upper = offset + length
            print("  [\(index)] range \(lower)..<\(upper) \"\(snippet)\"")
            offset = upper

            if let font = run[AttributeScopes.SwiftUIAttributes.FontAttribute.self] {
                let resolved = font.resolve(in: fontResolutionContext)
                print("    font bold:\(resolved.isBold) italic:\(resolved.isItalic)")
            }

            if let inlineIntent =
                run[AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self]
            {
                print("    inlineIntent: \(inlineIntent)")
            }

            if let presentation =
                run[AttributeScopes.FoundationAttributes.PresentationIntentAttribute.self]
            {
                print("    presentation: \(presentation)")
            }

            if let link = run[AttributeScopes.FoundationAttributes.LinkAttribute.self] {
                print("    link: \(link.absoluteString)")
            }

            #if canImport(AppKit)
                if let attachment =
                    run[AttributeScopes.AppKitAttributes.AttachmentAttribute.self]
                {
                    print("    attachment: \(attachment)")
                }
            #elseif canImport(UIKit)
                if let attachment =
                    run[AttributeScopes.UIKitAttributes.AttachmentAttribute.self]
                {
                    print("    attachment: \(attachment)")
                }
            #endif

            if run[AttributeScopes.AMInlineAttributes.CodeAttribute.self] == true {
                print("    attributedMarkdown.code: true")
            }
        }
    }
}

// MARK: - Display Helpers
private extension DocumentEditorView {
    static func makeEditorBuffer(from canonical: AttributedString) -> AttributedString {
        guard !canonical.characters.isEmpty else { return canonical }

        var buffer = AttributedString()

        for run in canonical.runs {
            var fragment = AttributedString(canonical[run.range])

            let hasSemanticCode =
                run[AttributeScopes.AMInlineAttributes.CodeAttribute.self] == true
            let hasIntentCode =
                run[
                    AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self
                ]?.contains(.code) == true

            if !(hasSemanticCode || hasIntentCode) {
                var font = fragment.font ?? .body

                if let intent =
                    run[AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self]
                {
                    if intent.contains(.stronglyEmphasized) {
                        font = font.bold()
                    }
                    if intent.contains(.emphasized) {
                        font = font.italic()
                    }
                }

                fragment.font = font
            }

            fragment.font = fragment.font ?? .body

            fragment[
                AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self
            ] = nil
            fragment[AttributeScopes.AMInlineAttributes.BoldAttribute.self] = nil
            fragment[AttributeScopes.AMInlineAttributes.ItalicAttribute.self] = nil
            fragment[AttributeScopes.AMInlineAttributes.StrikethroughAttribute.self] = nil
            fragment[AttributeScopes.AMInlineAttributes.HeadingLevelAttribute.self] = nil
            fragment[AttributeScopes.AMInlineAttributes.ListItemAttribute.self] = nil
            fragment[AttributeScopes.AMInlineAttributes.BlockQuoteAttribute.self] = nil
            fragment[AttributeScopes.AMInlineAttributes.CodeBlockAttribute.self] = nil
            fragment[AttributeScopes.AMInlineAttributes.ParagraphAttribute.self] = nil

            buffer.append(fragment)
        }

        return buffer
    }

    static func prepareMarkdownForEditorDisplay(_ markdown: String) -> String {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.contains("\n\n") else { return normalized }

        var result = String()
        result.reserveCapacity(normalized.count + normalized.count / 8)

        var consecutiveNewlines = 0

        for character in normalized {
            if character == "\n" {
                consecutiveNewlines += 1
                if consecutiveNewlines == 1 {
                    result.append("\n")
                } else {
                    result.append("<br>\n")
                }
            } else {
                consecutiveNewlines = 0
                result.append(character)
            }
        }

        return result
    }
}

#Preview {
    DocumentEditorView(
        draftTitle: "Sample",
        initialMarkdown: """
            *This* is a test

            **This** is a test

            This is a test
            """,
        onMarkdownChange: { md in
            print("Committed MD:\n\(md)")
        },
        onLiveMarkdownChange: { md in
            print("Live MD:\n\(md)")
        }
    )
}
