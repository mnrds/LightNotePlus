//  LightNote+ 
//
//  NoteView.swift structure:
//  ├── Note formatting and Markdown editor
//  │   ├── NoteFormattingAction / NoteEditorFormatting
//  │   ├── NoteMarkdownEditor
//  │   └── MarkdownTextView
//  ├── Markdown preview
//  │   ├── NoteMarkdownBlock
//  │   └── NoteMarkdownPreview / PreviewMarkdownTextView
//  ├── Notes data and workspace
//  │   ├── NoteTreeItem / NoteHeading
//  │   └── NotesWorkspaceModel
//  └── Notes interface
//      ├── NoteTreeRow
//      ├── NoteFormattingToolbar
//      └── NoteView
//
// Created by mnrds
//

import SwiftUI
import Combine
import Foundation
import AppKit
import UniformTypeIdentifiers

private enum NoteFormattingAction {
    case bold
    case italic
    case title
    case separator
    case checklist
    case quote
    case link(url: String)
}

private struct NoteFormattingRequest {
    let id = UUID()
    let action: NoteFormattingAction
}

@MainActor
private final class NoteEditorFormatting: ObservableObject {
    @Published var request: NoteFormattingRequest?
    private var appliedRequestID: UUID?

    func perform(_ action: NoteFormattingAction) {
        request = NoteFormattingRequest(action: action)
    }

    func claim(_ request: NoteFormattingRequest) -> Bool {
        guard request.id != appliedRequestID else { return false }
        appliedRequestID = request.id
        return true
    }
}

private struct NoteMarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    let textColor: Color
    @ObservedObject var formatting: NoteEditorFormatting

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = MarkdownTextView()
        textView.delegate = context.coordinator
        textView.onInsertNewline = { context.coordinator.handleChecklistNewline(in: textView) }
        textView.onBold = { context.coordinator.format(textView, with: "**") }
        textView.onItalic = { context.coordinator.format(textView, with: "*") }
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
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
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MarkdownTextView else { return }
        context.coordinator.text = $text
        textView.textColor = NSColor(textColor)

        if textView.string != text {
            textView.string = text
        }

        guard let request = formatting.request, formatting.claim(request) else { return }
        switch request.action {
        case .bold:
            context.coordinator.format(textView, with: "**")
        case .italic:
            context.coordinator.format(textView, with: "*")
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
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
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
                of: #"^([ \t]*)- \[[ xX]\] "#,
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
                textView.textStorage?.replaceCharacters(
                    in: NSRange(location: lineRange.location, length: prefixLength),
                    with: ""
                )
                let caret = max(lineRange.location, selection.location - prefixLength)
                textView.setSelectedRange(NSRange(location: caret, length: selection.length))
                return false
            }

            textView.insertText(
                "\n\(String(prefix.dropLast(6)))- [ ] ",
                replacementRange: selection
            )
            return true
        }

        func format(_ textView: NSTextView, with marker: String) {
            let selectedRange = textView.selectedRange()
            let source = textView.string as NSString
            guard selectedRange.location != NSNotFound,
                  selectedRange.location <= source.length,
                  NSMaxRange(selectedRange) <= source.length else { return }

            let selectedText = source.substring(with: selectedRange)
            let replacement = "\(marker)\(selectedText)\(marker)"
            textView.insertText(replacement, replacementRange: selectedRange)

            let innerSelection = NSRange(
                location: selectedRange.location + (marker as NSString).length,
                length: (selectedText as NSString).length
            )
            textView.setSelectedRange(innerSelection)
        }

        func addTitle(to textView: NSTextView) {
            let source = textView.string as NSString
            let selection = textView.selectedRange()
            guard selection.location != NSNotFound,
                  selection.location <= source.length else { return }

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
            textView.insertText("---\n", replacementRange: NSRange(location: lineRange.location, length: 0))
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
            let destination = url.contains("://") ? url : "https://\(url)"
            let markdown = "[\(selectedText)](\(destination))"
            textView.insertText(markdown, replacementRange: selection)
        }
    }
}

private final class MarkdownTextView: NSTextView {
    var onInsertNewline: (() -> Bool)?
    var onBold: (() -> Void)?
    var onItalic: (() -> Void)?

    override func insertNewline(_ sender: Any?) {
        guard onInsertNewline?() != true else { return }
        super.insertNewline(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
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
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}

private final class PreviewMarkdownTextView: NSTextView {
    var onInsertNewline: (() -> Bool)?
    var onBold: (() -> Void)?
    var onItalic: (() -> Void)?
    var onToggleChecklist: ((NSRange) -> Void)?

    override func insertNewline(_ sender: Any?) {
        guard onInsertNewline?() != true else { return }
        super.insertNewline(sender)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let textStorage, let layoutManager, let textContainer else { return }

        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.enumerateAttribute(.noteParagraphKind, in: fullRange) { value, range, _ in
            guard value as? String == "divider", range.length > 0 else { return }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: range,
                actualCharacterRange: nil
            )
            let lineRect = layoutManager.boundingRect(
                forGlyphRange: glyphRange,
                in: textContainer
            )
            let origin = textContainerOrigin
            let y = lineRect.midY + origin.y
            let inset = origin.x
            let path = NSBezierPath()
            path.lineWidth = 1
            path.move(to: NSPoint(x: inset, y: y))
            path.line(to: NSPoint(x: max(inset, bounds.width - inset), y: y))
            (textColor ?? NSColor.separatorColor).withAlphaComponent(0.35).setStroke()
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let characterIndex = characterIndexForInsertion(at: point)
        let source = string as NSString
        if characterIndex < source.length {
            let lineRange = source.lineRange(
                for: NSRange(location: characterIndex, length: 0)
            )
            let attributes = textStorage?.attributes(at: characterIndex, effectiveRange: nil) ?? [:]
            let prefixLength = attributes[.noteVisiblePrefixLength] as? Int ?? 0
            let isChecklist = attributes[.noteChecklistChecked] != nil
            if isChecklist,
               characterIndex < lineRange.location + prefixLength {
                onToggleChecklist?(lineRange)
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
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
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}

private extension NSAttributedString.Key {
    static let noteParagraphKind = NSAttributedString.Key("LightNotePlus.ParagraphKind")
    static let noteHeadingLevel = NSAttributedString.Key("LightNotePlus.HeadingLevel")
    static let noteListPrefix = NSAttributedString.Key("LightNotePlus.ListPrefix")
    static let noteVisiblePrefixLength = NSAttributedString.Key("LightNotePlus.VisiblePrefixLength")
    static let noteChecklistChecked = NSAttributedString.Key("LightNotePlus.ChecklistChecked")
}

private struct NoteMarkdownBlock: Identifiable {
    enum Kind {
        case heading(level: Int)
        case paragraph
        case unorderedItem(indent: Int)
        case checklistItem(indent: Int, checked: Bool)
        case orderedItem(indent: Int, number: String)
        case quote
        case code
        case divider
    }

    let id: Int
    let kind: Kind
    let text: String
}

private struct NoteMarkdownPreview: NSViewRepresentable {
    @Binding var content: String
    let textColor: Color
    @ObservedObject var formatting: NoteEditorFormatting

    func makeCoordinator() -> Coordinator {
        Coordinator(content: $content)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PreviewMarkdownTextView()
        textView.delegate = context.coordinator
        textView.onInsertNewline = { context.coordinator.handleChecklistNewline(in: textView) }
        textView.onBold = { context.coordinator.toggleTrait(.boldFontMask, in: textView) }
        textView.onItalic = { context.coordinator.toggleTrait(.italicFontMask, in: textView) }
        textView.onToggleChecklist = { range in
            context.coordinator.toggleChecklist(at: range, in: textView)
        }
        textView.isRichText = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 40, height: 32)
        context.coordinator.configure(textView, markdown: content, textColor: NSColor(textColor))

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? PreviewMarkdownTextView else { return }
        context.coordinator.content = $content
        textView.textColor = NSColor(textColor)

        if content != context.coordinator.lastWrittenMarkdown {
            context.coordinator.configure(textView, markdown: content, textColor: NSColor(textColor))
        }

        guard let request = formatting.request, formatting.claim(request) else { return }
        switch request.action {
        case .bold:
            context.coordinator.toggleTrait(.boldFontMask, in: textView)
        case .italic:
            context.coordinator.toggleTrait(.italicFontMask, in: textView)
        case .title:
            context.coordinator.setHeading(level: 1, in: textView)
        case .separator:
            context.coordinator.insertSeparator(in: textView)
        case .checklist:
            context.coordinator.insertChecklistItem(in: textView)
        case .quote:
            context.coordinator.insertQuote(in: textView)
        case .link(let url):
            context.coordinator.insertLink(in: textView, url: url)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var content: Binding<String>
        var lastWrittenMarkdown: String?

        init(content: Binding<String>) {
            self.content = content
        }

        func configure(_ textView: NSTextView, markdown: String, textColor: NSColor) {
            let selection = textView.selectedRange()
            textView.textStorage?.setAttributedString(
                NoteMarkdownPreview.attributedString(from: markdown, textColor: textColor)
            )
            textView.setSelectedRange(NSRange(location: min(selection.location, textView.string.utf16.count), length: 0))
            lastWrittenMarkdown = markdown
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let markdown = NoteMarkdownPreview.markdown(from: textView.attributedString())
            lastWrittenMarkdown = markdown
            content.wrappedValue = markdown
        }

        func handleChecklistNewline(in textView: PreviewMarkdownTextView) -> Bool {
            let source = textView.string as NSString
            let selection = textView.selectedRange()
            guard selection.location != NSNotFound,
                  selection.location <= source.length,
                  NSMaxRange(selection) <= source.length,
                  source.length > 0 else {
                return false
            }

            let lineLocation = min(selection.location, source.length - 1)
            let lineRange = source.lineRange(
                for: NSRange(location: lineLocation, length: 0)
            )
            let attributes = textView.textStorage?.attributes(
                at: lineRange.location,
                effectiveRange: nil
            ) ?? [:]
            guard attributes[.noteParagraphKind] as? String == "checklist" else {
                return false
            }

            let prefixLength = attributes[.noteVisiblePrefixLength] as? Int ?? 0
            guard prefixLength > 0, prefixLength <= lineRange.length else { return false }
            let lineContentRange = NSRange(
                location: lineRange.location + prefixLength,
                length: max(0, lineRange.length - prefixLength
                    - (source.substring(with: lineRange).hasSuffix("\n") ? 1 : 0))
            )
            let lineContent = source.substring(with: lineContentRange)

            if lineContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                textView.textStorage?.replaceCharacters(
                    in: NSRange(location: lineRange.location, length: prefixLength),
                    with: ""
                )
                for key: NSAttributedString.Key in [
                    .noteParagraphKind,
                    .noteHeadingLevel,
                    .noteListPrefix,
                    .noteVisiblePrefixLength,
                    .noteChecklistChecked
                ] {
                    textView.typingAttributes.removeValue(forKey: key)
                }
                let caret = max(lineRange.location, selection.location - prefixLength)
                textView.setSelectedRange(NSRange(location: caret, length: selection.length))
                textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
                return false
            }

            let visiblePrefix = source.substring(
                with: NSRange(location: lineRange.location, length: prefixLength)
            )
            let checkboxPrefix: String
            if let checkboxRange = visiblePrefix.range(of: #"[☐☑]  $"#, options: .regularExpression) {
                checkboxPrefix = String(visiblePrefix[..<checkboxRange.lowerBound]) + "☐  "
            } else {
                checkboxPrefix = "☐  "
            }
            let markdownPrefix = attributes[.noteListPrefix] as? String ?? "- [ ] "
            let indentation = markdownPrefix.components(separatedBy: "- [").first ?? ""
            let nextAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16),
                .foregroundColor: textView.textColor ?? NSColor.labelColor,
                .noteParagraphKind: "checklist",
                .noteListPrefix: indentation + "- [ ] ",
                .noteVisiblePrefixLength: (checkboxPrefix as NSString).length,
                .noteChecklistChecked: false
            ]
            let insertion = NSMutableAttributedString(string: "\n" + checkboxPrefix, attributes: nextAttributes)
            textView.textStorage?.replaceCharacters(in: selection, with: insertion)
            textView.setSelectedRange(
                NSRange(location: selection.location + insertion.length, length: 0)
            )
            textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
            return true
        }

        func toggleTrait(_ trait: NSFontTraitMask, in textView: NSTextView) {
            let range = textView.selectedRange()
            let length = (textView.string as NSString).length
            let fontRange = range.length > 0
                ? range
                : NSRange(location: min(range.location, length), length: 0)
            let currentFont = textView.typingAttributes[.font] as? NSFont
                ?? textView.font
                ?? NSFont.systemFont(ofSize: 16)
            let hasTrait = NSFontManager.shared.traits(of: currentFont).contains(trait)
            let updatedFont = hasTrait
                ? NSFontManager.shared.convert(currentFont, toNotHaveTrait: trait)
                : NSFontManager.shared.convert(currentFont, toHaveTrait: trait)

            if fontRange.length > 0 {
                textView.textStorage?.addAttribute(.font, value: updatedFont, range: fontRange)
            }
            var attributes = textView.typingAttributes
            attributes[.font] = updatedFont
            textView.typingAttributes = attributes
            textViewDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        }

        func setHeading(level: Int, in textView: NSTextView) {
            let source = textView.string as NSString
            let selection = textView.selectedRange()
            let location = min(selection.location, source.length)
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            let contentRange = NSRange(
                location: lineRange.location,
                length: max(0, lineRange.length - (lineRange.length > 0 && source.substring(from: NSMaxRange(lineRange) - 1) == "\n" ? 1 : 0))
            )
            let font = NSFont.systemFont(ofSize: NoteMarkdownPreview.headingSize(level), weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textView.textColor ?? NSColor.labelColor,
                .noteHeadingLevel: level
            ]

            if contentRange.length > 0 {
                textView.textStorage?.addAttributes(attributes, range: contentRange)
            }
            var typingAttributes = textView.typingAttributes
            attributes.forEach { typingAttributes[$0.key] = $0.value }
            textView.typingAttributes = typingAttributes
            textViewDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        }

        func textViewDidChange(_ notification: Notification) {
            textDidChange(notification)
        }

        func insertSeparator(in textView: NSTextView) {
            let source = textView.string as NSString
            let selection = textView.selectedRange()
            let location = min(selection.location, source.length)
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            let hasTrailingNewline = lineRange.length > 0
                && source.character(at: NSMaxRange(lineRange) - 1) == 10
            let insertLocation = hasTrailingNewline ? NSMaxRange(lineRange) : source.length
            let separator = NSMutableAttributedString(
                string: (hasTrailingNewline ? "" : "\n") + "\u{200B}",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 16),
                    .foregroundColor: textView.textColor ?? NSColor.labelColor,
                    .noteParagraphKind: "divider"
                ]
            )
            separator.append(NSAttributedString(string: "\n"))
            textView.textStorage?.insert(separator, at: insertLocation)
            textView.setSelectedRange(NSRange(location: insertLocation + separator.length, length: 0))
            textViewDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        }

        func insertChecklistItem(in textView: NSTextView) {
            insertPrefixedLine(
                in: textView,
                visiblePrefix: "☐  ",
                markdownPrefix: "- [ ] ",
                kind: "checklist",
                checklistChecked: false
            )
        }

        func insertQuote(in textView: NSTextView) {
            insertPrefixedLine(
                in: textView,
                visiblePrefix: "▏  ",
                markdownPrefix: "> ",
                kind: "quote"
            )
        }

        private func insertPrefixedLine(
            in textView: NSTextView,
            visiblePrefix: String,
            markdownPrefix: String,
            kind: String,
            checklistChecked: Bool? = nil
        ) {
            let source = textView.string as NSString
            let selection = textView.selectedRange()
            let location = min(selection.location, source.length)
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            let hasTrailingNewline = lineRange.length > 0
                && source.character(at: NSMaxRange(lineRange) - 1) == 10
            let insertLocation = NSMaxRange(lineRange) - (hasTrailingNewline ? 1 : 0)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16),
                .foregroundColor: textView.textColor ?? NSColor.labelColor,
                .noteParagraphKind: kind,
                .noteListPrefix: markdownPrefix,
                .noteVisiblePrefixLength: (visiblePrefix as NSString).length
            ]
            let insertion = NSMutableAttributedString(string: "\n" + visiblePrefix + "\n", attributes: attributes)
            if let checklistChecked {
                insertion.addAttribute(
                    .noteChecklistChecked,
                    value: checklistChecked,
                    range: NSRange(location: 0, length: insertion.length)
                )
            }
            textView.textStorage?.insert(insertion, at: insertLocation)
            textView.setSelectedRange(NSRange(location: insertLocation + 1 + visiblePrefix.utf16.count, length: 0))
            textViewDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        }

        func toggleChecklist(at lineRange: NSRange, in textView: NSTextView) {
            guard lineRange.length > 0 else { return }
            let current = textView.textStorage?.attribute(
                .noteChecklistChecked,
                at: lineRange.location,
                effectiveRange: nil
            ) as? Bool ?? false
            let updated = !current
            textView.textStorage?.addAttribute(
                .noteChecklistChecked,
                value: updated,
                range: lineRange
            )
            textView.textStorage?.addAttribute(
                .noteListPrefix,
                value: updated ? "- [x] " : "- [ ] ",
                range: lineRange
            )
            textView.textStorage?.replaceCharacters(
                in: NSRange(location: lineRange.location, length: 1),
                with: updated ? "☑" : "☐"
            )
            textViewDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        }

        func insertLink(in textView: NSTextView, url: String) {
            let selection = textView.selectedRange()
            let source = textView.string as NSString
            guard selection.location != NSNotFound,
                  selection.location <= source.length,
                  NSMaxRange(selection) <= source.length,
                  let destination = URL(string: url.contains("://") ? url : "https://\(url)") else { return }
            let label = selection.length > 0 ? source.substring(with: selection) : "link text"
            let insertion = NSMutableAttributedString(
                string: label,
                attributes: [
                    .font: textView.typingAttributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 16),
                    .foregroundColor: NSColor.systemBlue,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .link: destination
                ]
            )
            textView.textStorage?.replaceCharacters(in: selection, with: insertion)
            textView.setSelectedRange(NSRange(location: selection.location + insertion.length, length: 0))
            textViewDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        }

    }

    private static func attributedString(from markdown: String, textColor: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let baseFont = NSFont.systemFont(ofSize: 16)
        let blocks = parse(markdown)

        for (index, block) in blocks.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n\n"))
            }

            let inline: AttributedString
            if case .code = block.kind {
                inline = AttributedString(block.text)
            } else if case .divider = block.kind {
                inline = AttributedString("\u{200B}")
            } else {
                inline = (try? AttributedString(
                    markdown: block.text,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                )) ?? AttributedString(block.text)
            }
            let rendered = NSMutableAttributedString(attributedString: NSAttributedString(inline))
            var markdownListPrefix: String?
            var visiblePrefix = ""
            switch block.kind {
            case .unorderedItem(let indent):
                markdownListPrefix = String(repeating: " ", count: indent * 2) + "- "
                visiblePrefix = String(repeating: "    ", count: indent) + "•  "
            case .checklistItem(let indent, let checked):
                markdownListPrefix = String(repeating: " ", count: indent * 2)
                    + (checked ? "- [x] " : "- [ ] ")
                visiblePrefix = String(repeating: "    ", count: indent)
                    + (checked ? "☑  " : "☐  ")
            case .orderedItem(let indent, let number):
                markdownListPrefix = String(repeating: " ", count: indent * 2) + "\(number). "
                visiblePrefix = String(repeating: "    ", count: indent) + "\(number).  "
            case .quote:
                visiblePrefix = "▏  "
            default:
                break
            }

            let inlineRange = NSRange(location: 0, length: rendered.length)
            rendered.enumerateAttribute(.inlinePresentationIntent, in: inlineRange) { value, range, _ in
                guard let rawIntent = value as? NSNumber, range.length > 0 else { return }
                let intent = InlinePresentationIntent(rawValue: rawIntent.uintValue)
                var traits: NSFontTraitMask = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
                if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
                let font = NSFontManager.shared.convert(baseFont, toHaveTrait: traits)
                rendered.addAttribute(.font, value: font, range: range)
            }
            rendered.enumerateAttribute(.link, in: inlineRange) { value, range, _ in
                guard let link = value, range.length > 0 else { return }
                rendered.addAttributes(
                    [
                        .link: link,
                        .foregroundColor: NSColor.systemBlue,
                        .underlineStyle: NSUnderlineStyle.single.rawValue
                    ],
                    range: range
                )
            }

            let paragraphKind: String
            let fontSize: CGFloat
            let headingLevel: Int?
            switch block.kind {
            case .heading(let level):
                paragraphKind = "heading"
                fontSize = headingSize(level)
                headingLevel = level
            case .paragraph:
                paragraphKind = "paragraph"
                fontSize = 16
                headingLevel = nil
            case .unorderedItem:
                paragraphKind = "unordered"
                fontSize = 16
                headingLevel = nil
            case .checklistItem(_, let checked):
                paragraphKind = "checklist"
                fontSize = 16
                headingLevel = nil
                rendered.addAttribute(
                    .noteChecklistChecked,
                    value: checked,
                    range: NSRange(location: 0, length: rendered.length)
                )
            case .orderedItem:
                paragraphKind = "ordered"
                fontSize = 16
                headingLevel = nil
            case .quote:
                paragraphKind = "quote"
                fontSize = 16
                headingLevel = nil
            case .code:
                paragraphKind = "code"
                fontSize = 13
                headingLevel = nil
            case .divider:
                paragraphKind = "divider"
                fontSize = 16
                headingLevel = nil
            }

            if !visiblePrefix.isEmpty {
                rendered.insert(NSAttributedString(string: visiblePrefix), at: 0)
            }
            let fullRange = NSRange(location: 0, length: rendered.length)
            if rendered.length > 0 {
                if !visiblePrefix.isEmpty {
                    rendered.addAttribute(
                        .noteVisiblePrefixLength,
                        value: (visiblePrefix as NSString).length,
                        range: fullRange
                    )
                }
                if let headingLevel {
                    rendered.addAttribute(.noteHeadingLevel, value: headingLevel, range: fullRange)
                }
                rendered.addAttribute(.noteParagraphKind, value: paragraphKind, range: fullRange)
                if case .checklistItem(_, let checked) = block.kind {
                    rendered.addAttribute(
                        .noteChecklistChecked,
                        value: checked,
                        range: fullRange
                    )
                }
                rendered.enumerateAttribute(.font, in: fullRange) { value, range, _ in
                    let oldFont = value as? NSFont ?? baseFont
                    let traits = NSFontManager.shared.traits(of: oldFont)
                    var newFont = NSFont.systemFont(ofSize: fontSize)
                    newFont = NSFontManager.shared.convert(newFont, toHaveTrait: traits)
                    if case .code = block.kind {
                        newFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
                    }
                    rendered.addAttribute(.font, value: newFont, range: range)
                }
                rendered.addAttribute(.foregroundColor, value: textColor, range: fullRange)
                if let markdownListPrefix {
                    rendered.addAttribute(.noteListPrefix, value: markdownListPrefix, range: fullRange)
                }
            }
            result.append(rendered)
        }

        let finalLength = result.length
        if finalLength > 0 {
            let fullRange = NSRange(location: 0, length: finalLength)
            result.addAttribute(.foregroundColor, value: textColor, range: fullRange)
            result.enumerateAttribute(.link, in: fullRange) { link, range, _ in
                guard link != nil else { return }
                result.addAttributes(
                    [
                        .foregroundColor: NSColor.systemBlue,
                        .underlineStyle: NSUnderlineStyle.single.rawValue
                    ],
                    range: range
                )
            }
        }
        return result
    }

    private static func markdown(from attributedText: NSAttributedString) -> String {
        let source = attributedText.string as NSString
        guard source.length > 0 else { return "" }
        var lines: [String] = []
        var location = 0
        var isInsideCodeBlock = false

        while location < source.length {
            let fullLineRange = source.lineRange(for: NSRange(location: location, length: 0))
            let lineRange = NSRange(
                location: fullLineRange.location,
                length: max(0, fullLineRange.length - (source.substring(with: fullLineRange).hasSuffix("\n") ? 1 : 0))
            )
            let line = (source.substring(with: lineRange) as NSString)
            let attributes = lineRange.length > 0
                ? attributedText.attributes(at: lineRange.location, effectiveRange: nil)
                : [:]
            let kind = attributes[.noteParagraphKind] as? String
            let headingLevel = attributes[.noteHeadingLevel] as? Int
            let visiblePrefixLength = attributes[.noteVisiblePrefixLength] as? Int ?? 0
            let checklistChecked = attributes[.noteChecklistChecked] as? Bool ?? false
            if kind == "code", !isInsideCodeBlock {
                lines.append("```")
                isInsideCodeBlock = true
            } else if kind != "code", isInsideCodeBlock {
                lines.append("```")
                isInsideCodeBlock = false
            }
            var prefix = ""
            if let headingLevel {
                prefix = String(repeating: "#", count: headingLevel) + " "
            } else if kind == "quote" {
                prefix = "> "
            } else if kind == "checklist" {
                prefix = checklistChecked ? "- [x] " : "- [ ] "
            } else if let listPrefix = attributes[.noteListPrefix] as? String {
                prefix = listPrefix
            } else if kind == "divider" {
                prefix = ""
            }

            let inlineRange = NSRange(
                location: min(lineRange.location + visiblePrefixLength, NSMaxRange(lineRange)),
                length: max(0, lineRange.length - visiblePrefixLength)
            )
            let inline = kind == "code"
                ? source.substring(with: lineRange)
                : markdownInline(from: attributedText, range: inlineRange)
            lines.append(kind == "divider" ? "---" : (kind == "code" ? inline : prefix + inline))
            location = NSMaxRange(fullLineRange)
        }

        if isInsideCodeBlock {
            lines.append("```")
        }
        return lines.joined(separator: "\n")
    }

    private static func markdownInline(from text: NSAttributedString, range: NSRange) -> String {
        guard range.length > 0 else { return "" }
        var result = ""
        var currentRun: (style: (bold: Bool, italic: Bool), link: String?, text: String)?

        func appendRun(_ run: (style: (bold: Bool, italic: Bool), link: String?, text: String)) {
            var value = run.text
            if run.style.bold && run.style.italic { value = "***\(value)***" }
            else if run.style.bold { value = "**\(value)**" }
            else if run.style.italic { value = "*\(value)*" }
            if let link = run.link {
                value = "[\(value)](\(link))"
            }
            result += value
        }

        text.enumerateAttributes(in: range) { attributes, subrange, _ in
            let font = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 16)
            let traits = NSFontManager.shared.traits(of: font)
            let style = (
                bold: traits.contains(.boldFontMask),
                italic: traits.contains(.italicFontMask)
            )
            let string = (text.string as NSString).substring(with: subrange)
            let link = (attributes[.link] as? URL)?.absoluteString
                ?? attributes[.link] as? String
            if let run = currentRun,
               run.style.bold == style.bold,
               run.style.italic == style.italic,
               run.link == link {
                currentRun = (style, link, run.text + string)
            } else {
                if let currentRun { appendRun(currentRun) }
                currentRun = (style, link, string)
            }
        }
        if let currentRun { appendRun(currentRun) }
        return result
    }

    private static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 30
        case 2: 25
        case 3: 21
        case 4: 18
        case 5: 16
        default: 14
        }
    }

    private static func parse(_ markdown: String) -> [NoteMarkdownBlock] {
        let lines = markdown.components(separatedBy: .newlines)
        var blocks: [NoteMarkdownBlock] = []
        var paragraphLines: [String] = []
        var codeLines: [String] = []
        var isInCodeBlock = false
        var codeFence = ""

        func append(_ kind: NoteMarkdownBlock.Kind, _ text: String) {
            blocks.append(NoteMarkdownBlock(id: blocks.count, kind: kind, text: text))
        }

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            append(.paragraph, paragraphLines.joined(separator: " "))
            paragraphLines.removeAll()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if isInCodeBlock {
                if trimmed.hasPrefix(codeFence) {
                    append(.code, codeLines.joined(separator: "\n"))
                    codeLines.removeAll()
                    isInCodeBlock = false
                } else {
                    codeLines.append(line)
                }
                continue
            }

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                codeFence = String(trimmed.prefix(3))
                isInCodeBlock = true
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            if let heading = match(trimmed, pattern: #"^(#{1,6})\s+(.+?)\s*#*\s*$"#) {
                flushParagraph()
                append(.heading(level: heading[1].count), heading[2])
            } else if trimmed.range(
                of: #"^((\*\s*){3,}|(-\s*){3,}|(_\s*){3,})$"#,
                options: .regularExpression
            ) != nil {
                flushParagraph()
                append(.divider, "")
            } else if let quote = match(trimmed, pattern: #"^>\s?(.*)$"#) {
                flushParagraph()
                append(.quote, quote[1])
            } else if let item = match(line, pattern: #"^(\s*)[-+*]\s+\[([ xX])\]\s*(.*)$"#) {
                flushParagraph()
                append(
                    .checklistItem(
                        indent: item[1].count / 2,
                        checked: item[2].lowercased() == "x"
                    ),
                    item[3]
                )
            } else if let item = match(line, pattern: #"^(\s*)[-+*]\s+(.+)$"#) {
                flushParagraph()
                append(.unorderedItem(indent: item[1].count / 2), item[2])
            } else if let item = match(line, pattern: #"^(\s*)(\d+)[.)]\s+(.+)$"#) {
                flushParagraph()
                append(.orderedItem(indent: item[1].count / 2, number: item[2]), item[3])
            } else {
                paragraphLines.append(trimmed)
            }
        }

        flushParagraph()
        if isInCodeBlock {
            append(.code, codeLines.joined(separator: "\n"))
        }
        return blocks
    }

    private static func match(_ string: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: string,
                range: NSRange(string.startIndex..., in: string)
              ) else {
            return nil
        }

        return (0..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: string) else { return nil }
            return String(string[range])
        }
    }
}

struct NoteTreeItem: Identifiable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let children: [NoteTreeItem]?

    var id: String { url.absoluteString }
}

struct NoteHeading: Codable, Identifiable, Hashable {
    let id: UUID
    let title: String
}

private struct NotesSidebarMetadata: Codable {
    var headings: [NoteHeading]
    var noteAssignments: [String: UUID]
}

private struct NotesOrganizationExport: Codable {
    let version: Int
    let headings: [NoteHeading]
    let noteAssignments: [String: UUID]
}

private enum NotesOrganizationTransferError: LocalizedError {
    case unsupportedVersion
    case invalidHeadings
    case invalidAssignmentPath

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion:
            return "This notes organization file has an unsupported version."
        case .invalidHeadings:
            return "The notes organization file contains invalid or duplicate headings."
        case .invalidAssignmentPath:
            return "The notes organization file contains an invalid note path."
        }
    }
}

@MainActor
final class NotesWorkspaceModel: ObservableObject {
    @Published private(set) var notes: [NoteTreeItem] = []
    @Published private(set) var headings: [NoteHeading] = []
    @Published private(set) var noteAssignments: [String: UUID] = [:]
    @Published private(set) var selectedNoteURL: URL?
    @Published var content = ""
    @Published var errorMessage: String?
    private var loadedMetadataRootPath: String?
    private var hasSecurityScopedAccess = false

    @Published private(set) var rootURL: URL

    private static let defaultRootURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents", isDirectory: true)
        .appendingPathComponent("LightNotePlus", isDirectory: true)
        .appendingPathComponent("Notes", isDirectory: true)
    private static let notesFolderBookmarkKey = "notes.folder.bookmark"

    init() {
        if let bookmark = UserDefaults.standard.data(forKey: Self.notesFolderBookmarkKey) {
            do {
                var isStale = false
                let savedURL = try URL(
                    resolvingBookmarkData: bookmark,
                    options: [.withSecurityScope, .withoutUI],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                rootURL = savedURL.standardizedFileURL
                hasSecurityScopedAccess = rootURL.startAccessingSecurityScopedResource()
                if isStale {
                    try saveNotesFolderBookmark(for: rootURL)
                }
                return
            } catch {
                UserDefaults.standard.removeObject(forKey: Self.notesFolderBookmarkKey)
                rootURL = Self.defaultRootURL
                errorMessage = "Unable to restore the saved Notes folder: \(error.localizedDescription)"
                return
            }
        }
        rootURL = Self.defaultRootURL
    }

    private var sidebarMetadataKey: String {
        "notes.sidebar.metadata.\(rootURL.standardizedFileURL.path)"
    }

    func setNotesFolder(_ url: URL) throws {
        errorMessage = nil
        let folderURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CocoaError(.fileReadNoSuchFile)
        }

        let startedAccess = folderURL.startAccessingSecurityScopedResource()
        do {
            try saveNotesFolderBookmark(for: folderURL)
        } catch {
            if startedAccess {
                folderURL.stopAccessingSecurityScopedResource()
            }
            throw error
        }

        if hasSecurityScopedAccess {
            rootURL.stopAccessingSecurityScopedResource()
        }
        rootURL = folderURL
        hasSecurityScopedAccess = startedAccess
        loadedMetadataRootPath = nil
        headings = []
        noteAssignments = [:]
        notes = []
        selectedNoteURL = nil
        content = ""
        loadWorkspace()
    }

    func resetNotesFolder() throws {
        errorMessage = nil
        if hasSecurityScopedAccess {
            rootURL.stopAccessingSecurityScopedResource()
        }
        UserDefaults.standard.removeObject(forKey: Self.notesFolderBookmarkKey)
        rootURL = Self.defaultRootURL
        hasSecurityScopedAccess = false
        loadedMetadataRootPath = nil
        headings = []
        noteAssignments = [:]
        notes = []
        selectedNoteURL = nil
        content = ""
        loadWorkspace()
    }

    private func saveNotesFolderBookmark(for url: URL) throws {
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmark, forKey: Self.notesFolderBookmarkKey)
    }

    func loadWorkspace() {
        do {
            loadSidebarMetadata()
            try FileManager.default.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true
            )
            try refreshNotes()
            if let selectedNoteURL,
               FileManager.default.fileExists(atPath: selectedNoteURL.path) {
                selectNote(selectedNoteURL)
            } else if let firstNote = firstNoteURL(in: notes) {
                selectNote(firstNote)
            } else {
                selectedNoteURL = nil
                content = ""
            }
        } catch {
            errorMessage = "Unable to load the notes folder: \(error.localizedDescription)"
        }
    }

    func notes(inHeading headingID: UUID?) -> [NoteTreeItem] {
        filteredTree(notes, headingID: headingID)
    }

    func exportOrganization() throws -> Data {
        let rootPath = rootURL.standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        var relativeAssignments: [String: UUID] = [:]

        for (path, headingID) in noteAssignments {
            guard path.hasPrefix(rootPrefix) else {
                throw NotesOrganizationTransferError.invalidAssignmentPath
            }
            relativeAssignments[String(path.dropFirst(rootPrefix.count))] = headingID
        }

        let export = NotesOrganizationExport(
            version: 1,
            headings: headings,
            noteAssignments: relativeAssignments
        )
        return try JSONEncoder().encode(export)
    }

    func importOrganization(from data: Data) throws {
        let organization = try JSONDecoder().decode(NotesOrganizationExport.self, from: data)
        guard organization.version == 1 else {
            throw NotesOrganizationTransferError.unsupportedVersion
        }

        let headingIDs = organization.headings.map(\.id)
        let headingTitles = organization.headings.map {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        guard organization.headings.allSatisfy({
            !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }),
        Set(headingIDs).count == headingIDs.count,
        Set(headingTitles).count == headingTitles.count else {
            throw NotesOrganizationTransferError.invalidHeadings
        }

        let validHeadingIDs = Set(headingIDs)
        var importedAssignments: [String: UUID] = [:]
        for (relativePath, headingID) in organization.noteAssignments {
            guard !relativePath.isEmpty,
                  !relativePath.hasPrefix("/"),
                  !relativePath.split(separator: "/").contains(".."),
                  validHeadingIDs.contains(headingID) else {
                throw NotesOrganizationTransferError.invalidAssignmentPath
            }

            let noteURL = URL(fileURLWithPath: relativePath, relativeTo: rootURL)
                .standardizedFileURL
            let rootPath = rootURL.standardizedFileURL.path
            let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            guard noteURL.path.hasPrefix(rootPrefix),
                  noteURL.pathExtension.lowercased() == "md" else {
                throw NotesOrganizationTransferError.invalidAssignmentPath
            }
            importedAssignments[noteKey(for: noteURL)] = headingID
        }

        let previousHeadings = headings
        let previousAssignments = noteAssignments
        headings = organization.headings
        noteAssignments = importedAssignments
        do {
            try saveSidebarMetadata()
        } catch {
            headings = previousHeadings
            noteAssignments = previousAssignments
            throw error
        }
    }

    func createHeading(named proposedTitle: String) {
        errorMessage = nil
        let title = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            errorMessage = "Enter a heading name."
            return
        }
        guard !headings.contains(where: {
            $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame
        }) else {
            errorMessage = "A heading with that name already exists."
            return
        }

        let heading = NoteHeading(id: UUID(), title: title)
        headings.append(heading)
        do {
            try saveSidebarMetadata()
        } catch {
            headings.removeAll { $0.id == heading.id }
            errorMessage = "Unable to save the note headings: \(error.localizedDescription)"
        }
    }

    func renameHeading(_ heading: NoteHeading, to proposedTitle: String) {
        errorMessage = nil
        let title = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            errorMessage = "Enter a heading name."
            return
        }
        guard !headings.contains(where: {
            $0.id != heading.id
                && $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame
        }) else {
            errorMessage = "A heading with that name already exists."
            return
        }
        guard let index = headings.firstIndex(where: { $0.id == heading.id }) else {
            errorMessage = "The heading no longer exists."
            return
        }

        let previousHeading = headings[index]
        headings[index] = NoteHeading(id: heading.id, title: title)
        do {
            try saveSidebarMetadata()
        } catch {
            headings[index] = previousHeading
            errorMessage = "Unable to save the renamed heading: \(error.localizedDescription)"
        }
    }

    func deleteHeading(_ heading: NoteHeading) {
        let previousHeadings = headings
        let previousAssignments = noteAssignments
        headings.removeAll { $0.id == heading.id }
        noteAssignments = noteAssignments.filter { $0.value != heading.id }
        do {
            try saveSidebarMetadata()
        } catch {
            headings = previousHeadings
            noteAssignments = previousAssignments
            errorMessage = "Unable to save the note headings: \(error.localizedDescription)"
        }
    }

    func canMoveHeading(_ headingID: UUID, by offset: Int) -> Bool {
        guard let index = headings.firstIndex(where: { $0.id == headingID }) else {
            return false
        }
        return headings.indices.contains(index + offset)
    }

    func moveHeading(_ headingID: UUID, by offset: Int) {
        guard let index = headings.firstIndex(where: { $0.id == headingID }) else {
            return
        }
        let destination = index + offset
        guard headings.indices.contains(destination) else { return }

        let previousHeadings = headings
        headings.swapAt(index, destination)
        do {
            try saveSidebarMetadata()
        } catch {
            headings = previousHeadings
            errorMessage = "Unable to save the heading order: \(error.localizedDescription)"
        }
    }

    func moveNote(_ url: URL, to headingID: UUID?) {
        let key = noteKey(for: url)
        guard allNoteURLs(in: notes).contains(where: { noteKey(for: $0) == key }) else {
            errorMessage = "The selected note is not in the Notes folder."
            return
        }
        guard headingID == nil || headings.contains(where: { $0.id == headingID }) else {
            errorMessage = "The selected heading no longer exists."
            return
        }

        let previousAssignment = noteAssignments[key]
        if let headingID {
            noteAssignments[key] = headingID
        } else {
            noteAssignments.removeValue(forKey: key)
        }
        do {
            try saveSidebarMetadata()
        } catch {
            noteAssignments[key] = previousAssignment
            errorMessage = "Unable to save the note organization: \(error.localizedDescription)"
        }
    }

    func noteContainsText(at url: URL) -> Bool? {
        guard allNoteURLs(in: notes).contains(where: { noteKey(for: $0) == noteKey(for: url) }) else {
            errorMessage = "The selected note is not in the Notes folder."
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            return !data.isEmpty
        } catch {
            errorMessage = "Unable to read the note before deleting it: \(error.localizedDescription)"
            return nil
        }
    }

    func deleteNote(at url: URL) {
        let key = noteKey(for: url)
        guard allNoteURLs(in: notes).contains(where: { noteKey(for: $0) == key }) else {
            errorMessage = "The selected note is not in the Notes folder."
            return
        }

        do {
            try FileManager.default.removeItem(at: url)
            noteAssignments.removeValue(forKey: key)
            if selectedNoteURL == url {
                selectedNoteURL = nil
                content = ""
            }
            try saveSidebarMetadata()
            try refreshNotes()
            if selectedNoteURL == nil, let firstNote = firstNoteURL(in: notes) {
                selectNote(firstNote)
            }
        } catch {
            errorMessage = "Unable to delete the note: \(error.localizedDescription)"
        }
    }

    func createNote() {
        do {
            try FileManager.default.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true
            )

            var fileURL = rootURL.appendingPathComponent("Untitled.md")
            var number = 2
            while FileManager.default.fileExists(atPath: fileURL.path) {
                fileURL = rootURL.appendingPathComponent("Untitled \(number).md")
                number += 1
            }

            try Data().write(to: fileURL, options: .atomic)
            try refreshNotes()
            selectNote(fileURL)
        } catch {
            errorMessage = "Unable to create a note: \(error.localizedDescription)"
        }
    }

    func selectNote(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            guard let noteContent = String(data: data, encoding: .utf8) else {
                errorMessage = "The note is not valid UTF-8 text."
                return
            }

            selectedNoteURL = url
            content = noteContent
        } catch {
            errorMessage = "Unable to open the note: \(error.localizedDescription)"
        }
    }

    func clearSelection() {
        selectedNoteURL = nil
        content = ""
    }

    func saveCurrentNote() {
        guard let selectedNoteURL else { return }

        do {
            try content.write(to: selectedNoteURL, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Unable to save the note: \(error.localizedDescription)"
        }
    }

    func renameNote(at url: URL, to proposedName: String) {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let noteName = name.lowercased().hasSuffix(".md")
            ? String(name.dropLast(3))
            : name

        guard !noteName.isEmpty,
              noteName != ".",
              noteName != "..",
              !noteName.contains("/") else {
            errorMessage = "Enter a valid note name."
            return
        }

        let newURL = url
            .deletingLastPathComponent()
            .appendingPathComponent(noteName)
            .appendingPathExtension("md")
        guard newURL != url else { return }
        guard !FileManager.default.fileExists(atPath: newURL.path) else {
            errorMessage = "A note with that name already exists."
            return
        }

        do {
            try FileManager.default.moveItem(at: url, to: newURL)
            if selectedNoteURL == url {
                selectedNoteURL = newURL
            }
            if let assignment = noteAssignments.removeValue(forKey: noteKey(for: url)) {
                noteAssignments[noteKey(for: newURL)] = assignment
                try saveSidebarMetadata()
            }
            try refreshNotes()
        } catch {
            errorMessage = "Unable to rename the note: \(error.localizedDescription)"
        }
    }

    private func refreshNotes() throws {
        notes = try treeItems(in: rootURL)
        let validKeys = Set(allNoteURLs(in: notes).map(noteKey(for:)))
        let validHeadingIDs = Set(headings.map(\.id))
        let previousAssignments = noteAssignments
        noteAssignments = noteAssignments.filter {
            validKeys.contains($0.key) && validHeadingIDs.contains($0.value)
        }
        if noteAssignments != previousAssignments {
            try saveSidebarMetadata()
        }
    }

    private func loadSidebarMetadata() {
        let rootPath = rootURL.standardizedFileURL.path
        guard loadedMetadataRootPath != rootPath else { return }
        loadedMetadataRootPath = rootPath
        headings = []
        noteAssignments = [:]
        guard let data = UserDefaults.standard.data(forKey: sidebarMetadataKey) else { return }

        do {
            let metadata = try JSONDecoder().decode(NotesSidebarMetadata.self, from: data)
            headings = metadata.headings
            noteAssignments = metadata.noteAssignments
        } catch {
            errorMessage = "Unable to load note organization: \(error.localizedDescription)"
        }
    }

    private func saveSidebarMetadata() throws {
        let metadata = NotesSidebarMetadata(
            headings: headings,
            noteAssignments: noteAssignments
        )
        let data = try JSONEncoder().encode(metadata)
        UserDefaults.standard.set(data, forKey: sidebarMetadataKey)
    }

    private func noteKey(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func allNoteURLs(in items: [NoteTreeItem]) -> [URL] {
        items.flatMap { item in
            if item.isDirectory {
                return allNoteURLs(in: item.children ?? [])
            }
            return [item.url]
        }
    }

    private func filteredTree(_ items: [NoteTreeItem], headingID: UUID?) -> [NoteTreeItem] {
        items.compactMap { item in
            if item.isDirectory {
                let children = filteredTree(item.children ?? [], headingID: headingID)
                guard !children.isEmpty else { return nil }
                return NoteTreeItem(
                    url: item.url,
                    name: item.name,
                    isDirectory: true,
                    children: children
                )
            }

            let assignedHeading = noteAssignments[noteKey(for: item.url)]
            guard assignedHeading == headingID else { return nil }
            return item
        }
    }

    private func treeItems(in directory: URL) throws -> [NoteTreeItem] {
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var items: [NoteTreeItem] = []

        for url in fileURLs {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { continue }

            if values.isDirectory == true {
                items.append(
                    NoteTreeItem(
                        url: url,
                        name: url.lastPathComponent,
                        isDirectory: true,
                        children: try treeItems(in: url)
                    )
                )
            } else if url.pathExtension.lowercased() == "md" {
                items.append(
                    NoteTreeItem(
                        url: url,
                        name: url.deletingPathExtension().lastPathComponent,
                        isDirectory: false,
                        children: nil
                    )
                )
            }
        }

        return items.sorted {
            if $0.isDirectory != $1.isDirectory {
                return $0.isDirectory
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func firstNoteURL(in items: [NoteTreeItem]) -> URL? {
        for item in items {
            if item.isDirectory, let noteURL = firstNoteURL(in: item.children ?? []) {
                return noteURL
            }
            if !item.isDirectory {
                return item.url
            }
        }
        return nil
    }
}

private struct NoteTreeRow: View {
    let item: NoteTreeItem
    let isSelected: Bool
    let colors: ThemeColors
    let headings: [NoteHeading]
    let currentHeadingID: UUID?
    let onSelect: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onMove: (UUID?) -> Void

    private var rowContent: some View {
        HStack(spacing: 6) {
            Image(systemName: item.isDirectory ? "folder" : "doc.text")
                .foregroundColor(colors.tabText)
            Text(item.name)
                .lineLimit(1)
                .foregroundColor(colors.tabText)
        }
    }

    var body: some View {
        Group {
            if item.isDirectory {
                rowContent
            } else {
                rowContent
                    .onDrag {
                        NSItemProvider(object: item.url as NSURL)
                    }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .listRowBackground(colors.tabBackground)
        .background(isSelected ? colors.tabSelected.opacity(0.18) : Color.clear)
        .onTapGesture {
            if !item.isDirectory {
                onSelect()
            }
        }
        .contextMenu {
            if !item.isDirectory {
                Button("Rename…", systemImage: "pencil", action: onRename)
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                Menu("Move to") {
                    Button {
                        onMove(nil)
                    } label: {
                        if currentHeadingID == nil {
                            Label("Unsorted", systemImage: "checkmark")
                        } else {
                            Text("Unsorted")
                        }
                    }

                    if !headings.isEmpty {
                        Divider()
                    }

                    ForEach(headings) { heading in
                        Button {
                            onMove(heading.id)
                        } label: {
                            if currentHeadingID == heading.id {
                                Label(heading.title, systemImage: "checkmark")
                            } else {
                                Text(heading.title)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct NoteFormattingToolbar: View {
    let colors: ThemeColors
    let formatting: NoteEditorFormatting
    let onLink: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            formatButton("bold", help: "Bold (⌘B)", shortcut: "b") {
                formatting.perform(.bold)
            }
            formatButton("italic", help: "Italic (⌘I)", shortcut: "i") {
                formatting.perform(.italic)
            }
            formatButton("textformat.size", help: "Add Title") {
                formatting.perform(.title)
            }
            formatButton("line.3.horizontal", help: "Insert Separator") {
                formatting.perform(.separator)
            }
            formatButton("checklist", help: "Insert Checklist Item") {
                formatting.perform(.checklist)
            }
            formatButton("text.quote", help: "Insert Quote") {
                formatting.perform(.quote)
            }
            formatButton("link", help: "Insert Hyperlink", action: onLink)
            Spacer()
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func formatButton(
        _ symbol: String,
        help: String,
        shortcut: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundColor(colors.text)
        }
        .help(help)
        .applyShortcut(shortcut)
    }
}

private extension View {
    @ViewBuilder
    func applyShortcut(_ shortcut: String?) -> some View {
        if let character = shortcut?.first {
            self.keyboardShortcut(KeyEquivalent(character), modifiers: .command)
        } else {
            self
        }
    }
}

struct NoteView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @ObservedObject var model: NotesWorkspaceModel
    @StateObject private var formatting = NoteEditorFormatting()
    @State private var renameTargetURL: URL?
    @State private var renameText = ""
    @State private var isRenamePresented = false
    @State private var deleteTargetURL: URL?
    @State private var isDeleteConfirmationPresented = false
    @State private var headingTitle = ""
    @State private var headingToRename: NoteHeading?
    @State private var isHeadingPresented = false
    @State private var targetedHeadingID: UUID?
    @State private var collapsedHeadingIDs = Set<UUID>()
    @State private var openNoteURLs: [URL] = []
    @State private var isSidebarVisible = true
    @State private var isSearchPresented = false
    @State private var searchText = ""
    @State private var searchResults: (query: String, notePaths: Set<String>)?
    @State private var searchTask: Task<Void, Never>?
    @State private var searchReadTask: Task<(Set<String>, String?), Never>?
    @State private var isLinkPresented = false
    @State private var linkURL = ""
    @State private var isEditing = false

    private var separatorColor: Color {
        themeManager.currentTheme == .light
            ? Color.black.opacity(0.16)
            : Color.white.opacity(0.16)
    }

    private var wordCount: Int {
        model.content.split(whereSeparator: \.isWhitespace).count
    }

    private var characterCount: Int {
        model.content.count
    }

    var body: some View {
        HSplitView {
            if isSidebarVisible {
                sidebar
            }
            editorPane
        }
        .environment(
            \.colorScheme,
            themeManager.currentTheme == .light ? .light : .dark
        )
        .onAppear {
            model.loadWorkspace()
            if let selectedNoteURL = model.selectedNoteURL {
                openNoteURLs = [selectedNoteURL]
            }
        }
        .onChange(of: model.selectedNoteURL) { _, selectedNoteURL in
            isEditing = false
            openNoteURLs.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
            if let selectedNoteURL,
               !openNoteURLs.contains(where: { $0 == selectedNoteURL }) {
                openNoteURLs.append(selectedNoteURL)
            }
        }
        .sheet(isPresented: $isRenamePresented) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Rename Note")
                    .font(.headline)

                TextField("Note name", text: $renameText)
                    .onSubmit {
                        confirmRename()
                    }

                HStack {
                    Spacer()
                    Button("Cancel") {
                        isRenamePresented = false
                    }
                    .keyboardShortcut(.cancelAction)

                    Button("Rename", action: confirmRename)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 320)
        }
        .sheet(isPresented: $isHeadingPresented) {
            VStack(alignment: .leading, spacing: 12) {
                Text(headingToRename == nil ? "New Heading" : "Rename Heading")
                    .font(.headline)

                TextField("Heading name", text: $headingTitle)
                    .onSubmit {
                        confirmHeading()
                    }

                HStack {
                    Spacer()
                    Button("Cancel") {
                        isHeadingPresented = false
                        headingToRename = nil
                    }
                    .keyboardShortcut(.cancelAction)

                    Button(headingToRename == nil ? "Create" : "Rename", action: confirmHeading)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 320)
        }
        .sheet(isPresented: $isLinkPresented) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Insert Hyperlink")
                    .font(.headline)

                TextField("https://example.com", text: $linkURL)
                    .onSubmit {
                        confirmLink()
                    }

                HStack {
                    Spacer()
                    Button("Cancel") {
                        isLinkPresented = false
                    }
                    .keyboardShortcut(.cancelAction)

                    Button("Insert", action: confirmLink)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 360)
        }
        .alert(
            "Notes",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        model.errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog(
            "Delete “\(deleteTargetURL?.deletingPathExtension().lastPathComponent ?? "note")”?",
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let deleteTargetURL {
                    model.deleteNote(at: deleteTargetURL)
                }
                self.deleteTargetURL = nil
            }
            Button("Cancel", role: .cancel) {
                deleteTargetURL = nil
            }
        } message: {
            Text("This note contains text. This action cannot be undone.")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("Notes")
                    .font(.headline)
                    .foregroundColor(themeManager.colors.text)
                Spacer(minLength: 0)
                sidebarButton("doc.badge.plus", help: "New Note") {
                    model.createNote()
                }
                sidebarButton("folder.badge.plus", help: "New Heading") {
                    headingToRename = nil
                    headingTitle = ""
                    isHeadingPresented = true
                }
                sidebarButton(
                    isSearchPresented ? "xmark" : "magnifyingglass",
                    help: isSearchPresented ? "Close Search" : "Search Notes"
                ) {
                    isSearchPresented.toggle()
                    if !isSearchPresented {
                        searchText = ""
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            if isSearchPresented {
                TextField("Search notes", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .onChange(of: searchText) { _, query in
                        updateSearchResults(for: query)
                    }
            }

            Rectangle()
                .fill(separatorColor)
                .frame(height: 1)

            List {
                if !filteredNotes(in: nil).isEmpty {
                    Section {
                        noteRows(in: nil)
                    } header: {
                        Text("Unsorted")
                            .foregroundColor(themeManager.colors.tabText)
                    }
                }

                ForEach(model.headings) { heading in
                    if normalizedSearchText.isEmpty
                        || heading.title.localizedCaseInsensitiveContains(normalizedSearchText)
                        || !filteredNotes(in: heading.id).isEmpty {
                        Section {
                            if !collapsedHeadingIDs.contains(heading.id) {
                                noteRows(in: heading.id)
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Image(systemName: "folder")
                                    .font(.system(size: 14))
                                    .foregroundColor(themeManager.colors.tabText)
                                    .frame(width: 18)

                                Text(heading.title)
                                    .font(.system(size: 14))
                                    .lineLimit(1)
                                    .foregroundColor(themeManager.colors.tabText)

                                Spacer(minLength: 0)

                                if !model.notes(inHeading: heading.id).isEmpty {
                                    Button {
                                        if collapsedHeadingIDs.contains(heading.id) {
                                            collapsedHeadingIDs.remove(heading.id)
                                        } else {
                                            collapsedHeadingIDs.insert(heading.id)
                                        }
                                    } label: {
                                        Image(systemName: collapsedHeadingIDs.contains(heading.id) ? "plus" : "minus")
                                            .font(.system(size: 14))
                                            .foregroundColor(themeManager.colors.tabText)
                                            .frame(width: 24, height: 24)
                                            .contentShape(Rectangle())
                                    }
                                    .contentShape(Rectangle())
                                    .buttonStyle(.plain)
                                    .help(
                                        collapsedHeadingIDs.contains(heading.id)
                                            ? "Show notes"
                                            : "Hide notes"
                                    )
                                }
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 3)
                            .background(
                                targetedHeadingID == heading.id
                                    ? themeManager.colors.tabSelected.opacity(0.25)
                                    : Color.clear
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .contentShape(Rectangle())
                            .onDrop(
                                of: [UTType.fileURL],
                                isTargeted: Binding(
                                    get: { targetedHeadingID == heading.id },
                                    set: { targetedHeadingID = $0 ? heading.id : nil }
                                ),
                                perform: { handleNoteDrop($0, to: heading.id) }
                            )
                            .contextMenu {
                                Button("Move Up", systemImage: "arrow.up") {
                                    model.moveHeading(heading.id, by: -1)
                                }
                                .disabled(!model.canMoveHeading(heading.id, by: -1))

                                Button("Move Down", systemImage: "arrow.down") {
                                    model.moveHeading(heading.id, by: 1)
                                }
                                .disabled(!model.canMoveHeading(heading.id, by: 1))

                                Divider()

                                Button("Rename Heading…", systemImage: "pencil") {
                                    beginRenamingHeading(heading)
                                }

                                Button("Delete Heading", systemImage: "trash", role: .destructive) {
                                    model.deleteHeading(heading)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(themeManager.colors.tabBackground)
            .environment(
                \.colorScheme,
                themeManager.currentTheme == .light ? .light : .dark
            )
        }
        .frame(minWidth: 190, idealWidth: 250, maxWidth: 340)
        .background(themeManager.colors.tabBackground)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(separatorColor)
                .frame(width: 1)
        }
    }

    private var editorPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(openNoteURLs, id: \.standardizedFileURL.path) { url in
                            noteTab(for: url)
                        }
                    }
                }
                .scrollIndicators(.hidden)

                Button(action: model.createNote) {
                    Image(systemName: "plus")
                        .foregroundColor(themeManager.colors.tabText)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .help("New Note")

                Spacer(minLength: 0)

                Button {
                    isSidebarVisible.toggle()
                } label: {
                    Image(systemName: "sidebar.left")
                        .foregroundColor(themeManager.colors.tabText)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .help(isSidebarVisible ? "Hide Sidebar" : "Show Sidebar")

                if let selectedNoteURL = model.selectedNoteURL {
                    Button {
                        beginRenaming(selectedNoteURL)
                    } label: {
                        Image(systemName: "pencil")
                            .foregroundColor(themeManager.colors.tabText)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .help("Rename Note")

                    Button(isEditing ? "Preview" : "Edit") {
                        isEditing.toggle()
                    }
                    .buttonStyle(.bordered)
                    .padding(.trailing, 12)
                }
            }
            .frame(height: 44)
            .background(themeManager.colors.tabBackground)

            Rectangle()
                .fill(separatorColor)
                .frame(height: 1)

            NoteFormattingToolbar(
                colors: themeManager.colors,
                formatting: formatting,
                onLink: {
                    linkURL = "https://"
                    isLinkPresented = true
                }
            )

            Rectangle()
                .fill(separatorColor)
                .frame(height: 1)

            Group {
                if model.selectedNoteURL != nil {
                    if isEditing {
                        NoteMarkdownEditor(
                            text: $model.content,
                            textColor: themeManager.colors.editorText,
                            formatting: formatting
                        )
                    } else {
                        NoteMarkdownPreview(
                            content: $model.content,
                            textColor: themeManager.colors.editorText,
                            formatting: formatting
                        )
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "note.text")
                            .font(.largeTitle)
                            .foregroundColor(themeManager.colors.tabText)
                        Text("Select a note or create a new one")
                            .foregroundColor(themeManager.colors.tabText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity)
            .background(themeManager.colors.editorBackground)
            .onChange(of: model.content) { _, _ in
                model.saveCurrentNote()
            }

            HStack {
                Spacer()
                Text("Words: \(wordCount)  |  Characters: \(characterCount)")
                    .font(.system(size: 11))
                    .foregroundColor(themeManager.colors.tabText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(themeManager.colors.tabBackground)
        }
        .background(themeManager.colors.editorBackground)
    }

    private func noteTab(for url: URL) -> some View {
        let isSelected = model.selectedNoteURL == url
        return ZStack(alignment: .trailing) {
            Button {
                openNote(url)
            } label: {
                HStack {
                    Text(url.deletingPathExtension().lastPathComponent)
                        .lineLimit(1)
                        .foregroundColor(isSelected ? themeManager.colors.text : themeManager.colors.tabText)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 40)
                .contentShape(Rectangle())
                .padding(.leading, 14)
                .padding(.trailing, 36)
            }
            .buttonStyle(.plain)

            Button {
                closeNoteTab(url)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(themeManager.colors.tabText)
                    .padding(.trailing, 12)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
            .help("Close Note")
            .padding(.trailing, 4)
        }
        .frame(width: 180, height: 42)
        .background(isSelected ? themeManager.colors.editorBackground : Color.clear)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(separatorColor)
                .frame(width: 1)
        }
    }

    private func sidebarButton(
        _ symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundColor(themeManager.colors.tabText)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func openNote(_ url: URL) {
        guard model.selectedNoteURL != url else { return }
        if let keyWindow = NSApp.keyWindow {
            keyWindow.endEditing(for: nil)
            keyWindow.makeFirstResponder(nil)
        }
        model.saveCurrentNote()
        model.selectNote(url)
        if !openNoteURLs.contains(where: { $0 == url }) {
            openNoteURLs.append(url)
        }
    }

    private func closeNoteTab(_ url: URL) {
        guard let index = openNoteURLs.firstIndex(of: url) else { return }
        let wasSelected = model.selectedNoteURL == url
        openNoteURLs.remove(at: index)
        guard wasSelected else { return }

        if openNoteURLs.isEmpty {
            model.clearSelection()
        } else {
            openNote(openNoteURLs[min(index, openNoteURLs.count - 1)])
        }
    }

    private func filteredNotes(in headingID: UUID?) -> [NoteTreeItem] {
        let items = model.notes(inHeading: headingID)
        let query = normalizedSearchText
        guard !query.isEmpty else { return items }
        if let headingID,
           let heading = model.headings.first(where: { $0.id == headingID }),
           heading.title.localizedCaseInsensitiveContains(query) {
            return items
        }
        if let searchResults, searchResults.query == query {
            return filterTree(items) { searchResults.notePaths.contains($0.url.standardizedFileURL.path) }
        }
        return filterTree(items) { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private func filterTree(
        _ items: [NoteTreeItem],
        matching predicate: (NoteTreeItem) -> Bool
    ) -> [NoteTreeItem] {
        items.compactMap { item in
            if item.isDirectory {
                let children = filterTree(item.children ?? [], matching: predicate)
                guard !children.isEmpty else { return nil }
                return NoteTreeItem(
                    url: item.url,
                    name: item.name,
                    isDirectory: true,
                    children: children
                )
            }
            return predicate(item) ? item : nil
        }
    }

    private func updateSearchResults(for proposedQuery: String) {
        searchTask?.cancel()
        searchReadTask?.cancel()
        let query = proposedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = nil
            return
        }

        let noteURLs = allNoteURLs(in: model.notes)
        searchTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            let readTask = Task.detached(priority: .userInitiated) {
                var matchingPaths = Set<String>()
                var firstReadError: String?

                for url in noteURLs {
                    guard !Task.isCancelled else { break }
                    if url.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(query) {
                        matchingPaths.insert(url.standardizedFileURL.path)
                        continue
                    }

                    do {
                        let contents = try String(contentsOf: url, encoding: .utf8)
                        if contents.localizedCaseInsensitiveContains(query) {
                            matchingPaths.insert(url.standardizedFileURL.path)
                        }
                    } catch {
                        firstReadError = firstReadError
                            ?? "Unable to search \(url.lastPathComponent): \(error.localizedDescription)"
                    }
                }
                return (matchingPaths, firstReadError)
            }
            searchReadTask = readTask
            let result = await readTask.value

            guard !Task.isCancelled,
                  normalizedSearchText == query else {
                return
            }
            searchResults = (query, result.0)
            if let error = result.1 {
                model.errorMessage = error
            }
        }
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func allNoteURLs(in items: [NoteTreeItem]) -> [URL] {
        items.flatMap { item in
            item.isDirectory ? allNoteURLs(in: item.children ?? []) : [item.url]
        }
    }

    private func beginRenaming(_ url: URL) {
        renameTargetURL = url
        renameText = url.deletingPathExtension().lastPathComponent
        isRenamePresented = true
    }

    private func beginRenamingHeading(_ heading: NoteHeading) {
        headingToRename = heading
        headingTitle = heading.title
        isHeadingPresented = true
    }

    private func confirmRename() {
        guard let renameTargetURL else { return }
        model.renameNote(at: renameTargetURL, to: renameText)
        isRenamePresented = false
    }

    private func requestDelete(_ url: URL) {
        guard let containsText = model.noteContainsText(at: url) else { return }
        if containsText {
            deleteTargetURL = url
            isDeleteConfirmationPresented = true
        } else {
            model.deleteNote(at: url)
        }
    }

    private func confirmLink() {
        let destination = linkURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty else { return }
        formatting.perform(.link(url: destination))
        isLinkPresented = false
    }

    private func handleNoteDrop(_ providers: [NSItemProvider], to headingID: UUID) -> Bool {
        let fileURLType = UTType.fileURL.identifier
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(fileURLType)
        }) else {
            return false
        }

        provider.loadItem(forTypeIdentifier: fileURLType, options: nil) { item, error in
            let url = (item as? URL) ?? (item as? Data).flatMap {
                URL(dataRepresentation: $0, relativeTo: nil)
            }
            Task { @MainActor in
                if let error {
                    model.errorMessage = "Unable to read the dropped note: \(error.localizedDescription)"
                } else if let url {
                    model.moveNote(url, to: headingID)
                } else {
                    model.errorMessage = "Unable to read the dropped note URL."
                }
            }
        }
        return true
    }

    @ViewBuilder
    private func noteRows(in headingID: UUID?) -> some View {
        OutlineGroup(filteredNotes(in: headingID), children: \.children) { item in
            NoteTreeRow(
                item: item,
                isSelected: model.selectedNoteURL == item.url,
                colors: themeManager.colors,
                headings: model.headings,
                currentHeadingID: model.noteAssignments[item.url.standardizedFileURL.path],
                onSelect: { openNote(item.url) },
                onRename: { beginRenaming(item.url) },
                onDelete: { requestDelete(item.url) },
                onMove: { model.moveNote(item.url, to: $0) }
            )
        }
    }

    private func confirmHeading() {
        if let headingToRename {
            model.renameHeading(headingToRename, to: headingTitle)
        } else {
            model.createHeading(named: headingTitle)
        }
        isHeadingPresented = false
        headingToRename = nil
    }
}
