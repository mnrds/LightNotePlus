//  LightNote+
//
//  NoteMarkdownEditor.swift
//  Plain-text Markdown editor (NSTextView) for notes.
//
// Created by mnrds
//

import SwiftUI
import Combine
import AppKit

// Connects the editable Markdown text view to SwiftUI.
struct NoteMarkdownEditor: NSViewRepresentable {
    let document: NoteDocument
    /// Changes only when the note text is replaced outside the editor.
    let revision: Int
    let documentID: String
    let textColor: Color
    /// Multiplier for the 14 pt base font (Settings × View zoom).
    let fontScale: CGFloat
    let onUserEdit: () -> Void
    @ObservedObject var formatting: NoteEditorFormatting
    @ObservedObject var search: NoteSearchModel
    @Environment(\.isPaneActive) private var isPaneActive

    static let baseFontSize: CGFloat = 14

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document, documentID: documentID, onUserEdit: onUserEdit)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = MarkdownTextView()
        textView.onToggleChecklist = { [weak textView] in
            guard let textView else { return false }
            return context.coordinator.toggleChecklist(in: textView)
        }
        textView.canToggleChecklist = { [weak textView] in
            guard let textView else { return false }
            return context.coordinator.checklistMatches(in: textView).isEmpty == false
        }
        textView.delegate = context.coordinator
        textView.onInsertNewline = { [weak textView] in
            guard let textView else { return false }
            return context.coordinator.handleChecklistNewline(in: textView)
        }
        textView.onBold = { [weak textView] in
            guard let textView else { return }
            context.coordinator.format(textView, opening: "**", closing: "**")
        }
        textView.onItalic = { [weak textView] in
            guard let textView else { return }
            context.coordinator.format(textView, opening: "*", closing: "*")
        }
        context.coordinator.attach(textView)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: Self.baseFontSize * fontScale, weight: .regular)
        context.coordinator.lastFontScale = fontScale
        textView.textColor = NSColor(textColor)
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 12, height: 12)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        scrollView.isHidden = !isPaneActive
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MarkdownTextView else { return }
        if scrollView.isHidden == isPaneActive {
            scrollView.isHidden = !isPaneActive
        }
        context.coordinator.document = document
        context.coordinator.onUserEdit = onUserEdit
        textView.textColor = NSColor(textColor)
        if context.coordinator.lastFontScale != fontScale {
            context.coordinator.lastFontScale = fontScale
            textView.font = .monospacedSystemFont(ofSize: Self.baseFontSize * fontScale, weight: .regular)
        }

        let documentChanged = context.coordinator.documentID != documentID
        if documentChanged {
            textView.undoManager?.removeAllActions(withTarget: textView)
            context.coordinator.documentID = documentID
            context.coordinator.lastSearchRequestID = nil
        }

        // User edits flow from the text view into the document, so the text only
        // needs to be compared when it was replaced from outside (open, reload).
        if documentChanged || context.coordinator.lastRevision != revision {
            context.coordinator.lastRevision = revision
            if textView.string != document.text {
                context.coordinator.isUpdatingTextView = true
                textView.string = document.text
                context.coordinator.isUpdatingTextView = false
            }
        }
        context.coordinator.performSearchIfNeeded(in: textView, search: search)
        formatting.applyFocusIfRequested(to: textView, documentID: documentID)

        guard let request = formatting.request,
              formatting.claim(request, for: documentID) else { return }
        switch request.action {
        case .bold:
            context.coordinator.format(textView, opening: "**", closing: "**")
        case .italic:
            context.coordinator.format(textView, opening: "*", closing: "*")
        case .underline:
            context.coordinator.format(textView, opening: "<u>", closing: "</u>")
        case .strikethrough:
            context.coordinator.format(textView, opening: "~~", closing: "~~")
        case .title:
            context.coordinator.addTitle(to: textView)
        case .separator:
            context.coordinator.insertSeparator(in: textView)
        case .checklist:
            context.coordinator.prefixLines(in: textView, with: "- [ ] ")
        case .quote:
            context.coordinator.prefixLines(in: textView, with: "> ")
        case .link(let url):
            context.coordinator.insertLink(in: textView, url: url)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var document: NoteDocument
        var documentID: String
        var onUserEdit: () -> Void
        var isUpdatingTextView = false
        var lastSearchRequestID: UUID?
        var lastRevision: Int?
        var lastFontScale: CGFloat?
        private weak var textView: NSTextView?
        private var previewEditsSubscription: AnyCancellable?

        /// Follows edits made in the preview (split layout), e.g. checkbox toggles.
        func attach(_ textView: NSTextView) {
            self.textView = textView
            previewEditsSubscription = document.userEdits
                .filter { $0 == .preview }
                .sink { [weak self] _ in self?.syncFromDocument() }
        }

        private func syncFromDocument() {
            guard let textView, textView.string != document.text else { return }
            let selection = textView.selectedRange()
            let length = (document.text as NSString).length
            isUpdatingTextView = true
            if textView.shouldChangeText(
                in: NSRange(location: 0, length: (textView.string as NSString).length),
                replacementString: document.text
            ) {
                textView.string = document.text
                textView.didChangeText()
            }
            isUpdatingTextView = false
            textView.setSelectedRange(
                NSRange(location: min(selection.location, length), length: 0)
            )
        }

        // The " " / "x" inside "- [ ]" or "1. [x]" at the start of a line.
        private static let checkboxExpression = try! NSRegularExpression(
            pattern: #"^[ \t]*(?:[-+*]|\d+[.)]) \[([ xX])\]"#,
            options: [.anchorsMatchLines]
        )

        init(document: NoteDocument, documentID: String, onUserEdit: @escaping () -> Void) {
            self.document = document
            self.documentID = documentID
            self.onUserEdit = onUserEdit
        }

        func performSearchIfNeeded(in textView: NSTextView, search: NoteSearchModel) {
            guard let request = search.request,
                  request.id != lastSearchRequestID else { return }
            lastSearchRequestID = request.id
            search.search(request, in: textView)
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdatingTextView,
                  let textView = notification.object as? NSTextView else { return }
            document.applyUserEdit(textView.string, from: .editor)
            onUserEdit()
        }

        /// Checkbox state ranges on the lines touched by the selection.
        func checklistMatches(in textView: NSTextView) -> [NSRange] {
            let source = textView.string as NSString
            let selection = textView.selectedRange()
            guard selection.location != NSNotFound,
                  NSMaxRange(selection) <= source.length else { return [] }
            let linesRange = source.lineRange(for: selection)
            return Self.checkboxExpression
                .matches(in: textView.string, range: linesRange)
                .map { $0.range(at: 1) }
        }

        /// Toggles the checklist items on the selected lines (⌘↩ or the
        /// VoiceOver action). Checks all of them unless all are already checked.
        @discardableResult
        func toggleChecklist(in textView: NSTextView) -> Bool {
            let source = textView.string as NSString
            let ranges = checklistMatches(in: textView)
            guard !ranges.isEmpty else { return false }
            let allChecked = ranges.allSatisfy { source.substring(with: $0) != " " }
            let replacement = allChecked ? " " : "x"
            for range in ranges.reversed() where allChecked || source.substring(with: range) == " " {
                guard textView.shouldChangeText(in: range, replacementString: replacement) else { continue }
                textView.textStorage?.replaceCharacters(in: range, with: replacement)
                textView.didChangeText()
            }
            return true
        }

        func handleChecklistNewline(in textView: NSTextView) -> Bool {
            let source = textView.string as NSString
            let selection = textView.selectedRange()
            guard selection.location != NSNotFound,
                  selection.location <= source.length,
                  NSMaxRange(selection) <= source.length else {
                return false
            }

            let lineRange = source.lineRange(
                for: NSRange(location: selection.location, length: 0)
            )
            let line = source.substring(with: lineRange)
            guard let markerRange = line.range(
                of: #"^([ \t]*[-+*]) \[[ xX]\] "#,
                options: .regularExpression
            ) else {
                return false
            }

            let prefix = String(line[markerRange])
            let prefixLength = (prefix as NSString).length
            let lineContentRange = NSRange(
                location: lineRange.location + prefixLength,
                length: max(0, lineRange.length - prefixLength
                    - (line.hasSuffix("\n") ? 1 : 0))
            )
            let lineContent = source.substring(with: lineContentRange)

            if lineContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                textView.insertText(
                    "",
                    replacementRange: NSRange(location: lineRange.location, length: prefixLength)
                )
                let caret = max(lineRange.location, selection.location - prefixLength)
                textView.setSelectedRange(NSRange(location: caret, length: 0))
                return true
            }

            let nextItemPrefix = prefix.replacingOccurrences(
                of: #"\[[ xX]\]"#,
                with: "[ ]",
                options: .regularExpression
            )
            textView.insertText(
                "\n\(nextItemPrefix)",
                replacementRange: selection
            )
            return true
        }

        func format(_ textView: NSTextView, opening: String, closing: String) {
            let selectedRange = textView.selectedRange()
            let source = textView.string as NSString
            guard selectedRange.location != NSNotFound,
                  selectedRange.location <= source.length,
                  NSMaxRange(selectedRange) <= source.length else { return }

            let selectedText = source.substring(with: selectedRange)
            guard !selectedText.isEmpty else {
                let replacement = "\(opening)\(closing)"
                textView.insertText(replacement, replacementRange: selectedRange)
                textView.setSelectedRange(
                    NSRange(
                        location: selectedRange.location + (opening as NSString).length,
                        length: 0
                    )
                )
                return
            }
            let parts = NoteInlineWhitespace.split(selectedText)
            guard !parts.content.isEmpty else { return }
            let replacement = "\(parts.leading)\(opening)\(parts.content)\(closing)\(parts.trailing)"
            textView.insertText(replacement, replacementRange: selectedRange)

            let innerSelection = NSRange(
                location: selectedRange.location
                    + (parts.leading as NSString).length
                    + (opening as NSString).length,
                length: (parts.content as NSString).length
            )
            textView.setSelectedRange(innerSelection)
        }

        func addTitle(to textView: NSTextView) {
            let source = textView.string as NSString
            let selection = textView.selectedRange()
            guard selection.location != NSNotFound,
                  selection.location <= source.length,
                  source.length > 0 else { return }

            let lineRange = source.lineRange(
                for: NSRange(location: selection.location, length: 0)
            )
            let line = source.substring(with: lineRange)
            guard !line.hasPrefix("# ") else { return }

            textView.insertText("# ", replacementRange: NSRange(location: lineRange.location, length: 0))
            textView.setSelectedRange(
                NSRange(location: selection.location + 2, length: selection.length)
            )
        }

        func insertSeparator(in textView: NSTextView) {
            let source = textView.string as NSString
            let location = min(textView.selectedRange().location, source.length)
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            let insertionLocation = lineRange.location
            let previousLineIsBlank: Bool
            if insertionLocation > 0 {
                let previousLineRange = source.lineRange(
                    for: NSRange(location: insertionLocation - 1, length: 0)
                )
                previousLineIsBlank = source.substring(with: previousLineRange)
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } else {
                previousLineIsBlank = false
            }
            let followingLineIsBlank = insertionLocation < source.length
                && source.substring(with: lineRange)
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasPreviousLine = insertionLocation > 0
            let leadingNewline = hasPreviousLine && !previousLineIsBlank ? "\n" : ""
            let trailingNewlines = followingLineIsBlank ? "\n" : "\n\n"
            textView.insertText(
                "\(leadingNewline)---\(trailingNewlines)",
                replacementRange: NSRange(location: insertionLocation, length: 0)
            )
        }

        func prefixLines(in textView: NSTextView, with prefix: String) {
            let source = textView.string as NSString
            let selection = textView.selectedRange()
            guard selection.location != NSNotFound, selection.location <= source.length else { return }
            let first = source.lineRange(for: NSRange(location: selection.location, length: 0))
            let lastLocation = selection.length == 0
                ? selection.location
                : min(NSMaxRange(selection) - 1, source.length)
            let last = source.lineRange(for: NSRange(location: lastLocation, length: 0))
            let linesRange = NSRange(
                location: first.location,
                length: NSMaxRange(last) - first.location
            )
            let selectedLines = source.substring(with: linesRange)
            let hasTrailingNewline = selectedLines.hasSuffix("\n")
            var lines = selectedLines.components(separatedBy: .newlines)
            if lines.last?.isEmpty == true { lines.removeLast() }
            var replacement = lines.map { prefix + $0 }.joined(separator: "\n")
            if hasTrailingNewline {
                replacement.append("\n")
            }
            textView.insertText(replacement, replacementRange: linesRange)
        }

        func insertLink(in textView: NSTextView, url: String) {
            let selection = textView.selectedRange()
            let source = textView.string as NSString
            guard selection.location != NSNotFound,
                  selection.location <= source.length,
                  NSMaxRange(selection) <= source.length else { return }
            let selectedText = selection.length > 0
                ? source.substring(with: selection)
                : "link text"
            guard let destination = NoteLinkURL.make(from: url) else { return }
            let markdown = "[\(selectedText)](\(destination.absoluteString))"
            textView.insertText(markdown, replacementRange: selection)
        }
    }
}

// Handles editor keyboard shortcuts and checklist line breaks.
final class MarkdownTextView: NSTextView {
    var onInsertNewline: (() -> Bool)?
    var onBold: (() -> Void)?
    var onItalic: (() -> Void)?
    var onToggleChecklist: (() -> Bool)?
    var canToggleChecklist: (() -> Bool)?

    // Lets VoiceOver users toggle a checklist item (VO-⌘-Space, Actions).
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        var actions = super.accessibilityCustomActions() ?? []
        if canToggleChecklist?() == true {
            actions.append(
                NSAccessibilityCustomAction(name: "Toggle Checklist Item") { [weak self] in
                    self?.onToggleChecklist?() ?? false
                }
            )
        }
        return actions
    }

    override func insertNewline(_ sender: Any?) {
        guard onInsertNewline?() != true else { return }
        super.insertNewline(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.option),
              !event.modifierFlags.contains(.control) else {
            return super.performKeyEquivalent(with: event)
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "b":
            onBold?()
            return true
        case "i":
            onItalic?()
            return true
        case "\r":
            return onToggleChecklist?() == true || super.performKeyEquivalent(with: event)
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}
