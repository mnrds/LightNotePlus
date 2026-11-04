//  LightNote+/
//  ├── LightNote+/                  # Source files
//  │   ├── AppDelegate.swift           # App entry point//
//  │   ├── ContentView.swift           # Main Text-editor view with toolbar, tabs, and editor
//  │   ├── NoteView.swift              # Notes view with file tree and note editor
//  │   ├── ThemeManager.swift          # Dark/light theme management
//  │   ├── TabManager.swift            # Tab system for multiple files
//  │   ├── SyntaxHighlighter.swift     # Syntax highlighting (framework)
//  │   └── Info.plist                  # App configuration
//  └── LightNotePlus.xcodeproj/        # Xcode project files
//
// Created by mnrds
//

import SwiftUI
import Combine
import Foundation
import AppKit

private enum NoteFormattingAction {
    case bold
    case italic
    case title
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
    }
}

private final class MarkdownTextView: NSTextView {
    var onBold: (() -> Void)?
    var onItalic: (() -> Void)?

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
    var onBold: (() -> Void)?
    var onItalic: (() -> Void)?

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
}

private struct NoteMarkdownBlock: Identifiable {
    enum Kind {
        case heading(level: Int)
        case paragraph
        case unorderedItem(indent: Int)
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
        textView.onBold = { context.coordinator.toggleTrait(.boldFontMask, in: textView) }
        textView.onItalic = { context.coordinator.toggleTrait(.italicFontMask, in: textView) }
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
                inline = AttributedString(String(repeating: "─", count: 40))
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
            result.addAttribute(.foregroundColor, value: textColor, range: NSRange(location: 0, length: finalLength))
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
        var currentStyle: (bold: Bool, italic: Bool)?
        text.enumerateAttributes(in: range) { attributes, subrange, _ in
            let font = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 16)
            let traits = NSFontManager.shared.traits(of: font)
            let style = (
                bold: traits.contains(.boldFontMask),
                italic: traits.contains(.italicFontMask)
            )
            let string = (text.string as NSString).substring(with: subrange)
            if style.bold != currentStyle?.bold || style.italic != currentStyle?.italic {
                if let currentStyle {
                    if currentStyle.bold && currentStyle.italic { result += "***" }
                    else if currentStyle.bold { result += "**" }
                    else if currentStyle.italic { result += "*" }
                }
                if style.bold && style.italic { result += "***" }
                else if style.bold { result += "**" }
                else if style.italic { result += "*" }
                currentStyle = style
            }
            result += string
        }
        if let currentStyle {
            if currentStyle.bold && currentStyle.italic { result += "***" }
            else if currentStyle.bold { result += "**" }
            else if currentStyle.italic { result += "*" }
        }
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

@MainActor
final class NotesWorkspaceModel: ObservableObject {
    @Published private(set) var notes: [NoteTreeItem] = []
    @Published private(set) var selectedNoteURL: URL?
    @Published var content = ""
    @Published var errorMessage: String?

    // Documents/LightNotePlus/Notes
    let rootURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents", isDirectory: true)
        .appendingPathComponent("LightNotePlus", isDirectory: true)
        .appendingPathComponent("Notes", isDirectory: true)

    func loadWorkspace() {
        do {
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
            try refreshNotes()
        } catch {
            errorMessage = "Unable to rename the note: \(error.localizedDescription)"
        }
    }

    private func refreshNotes() throws {
        notes = try treeItems(in: rootURL)
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

struct NoteView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @ObservedObject var model: NotesWorkspaceModel
    @StateObject private var formatting = NoteEditorFormatting()
    @State private var renameTargetURL: URL?
    @State private var renameText = ""
    @State private var isRenamePresented = false
    @State private var isEditing = false

    private var separatorColor: Color {
        themeManager.currentTheme == .light
            ? Color.black.opacity(0.16)
            : Color.white.opacity(0.16)
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Notes")
                        .font(.headline)
                        .foregroundColor(themeManager.colors.text)
                    Spacer()
                    Button(action: model.createNote) {
                        Image(systemName: "plus")
                            .foregroundColor(themeManager.colors.text)
                    }
                    .buttonStyle(.plain)
                    .help("Create Note")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                Rectangle()
                    .fill(separatorColor)
                    .frame(height: 1)

                List {
                    OutlineGroup(model.notes, children: \.children) { item in
                        HStack(spacing: 6) {
                            Image(systemName: item.isDirectory ? "folder" : "doc.text")
                                .foregroundColor(themeManager.colors.tabText)
                            Text(item.name)
                                .lineLimit(1)
                                .foregroundColor(themeManager.colors.tabText)
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                        .listRowBackground(themeManager.colors.tabBackground)
                        .background(
                            model.selectedNoteURL == item.url
                                ? themeManager.colors.tabSelected.opacity(0.18)
                                : Color.clear
                        )
                        .onTapGesture {
                            if !item.isDirectory {
                                model.selectNote(item.url)
                            }
                        }
                        .contextMenu {
                            if !item.isDirectory {
                                Button("Rename…", systemImage: "pencil") {
                                    beginRenaming(item.url)
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
            .frame(minWidth: 170, idealWidth: 220, maxWidth: 300)
            .background(themeManager.colors.tabBackground)
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(separatorColor)
                    .frame(width: 1)
            }

            Group {
                if let selectedNoteURL = model.selectedNoteURL {
                    VStack(spacing: 0) {
                        HStack {
                            Text(selectedNoteURL.deletingPathExtension().lastPathComponent)
                                .font(.headline)
                            Spacer()
                            Button {
                                beginRenaming(selectedNoteURL)
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.plain)
                            .help("Rename Note")

                            Button(isEditing ? "Preview" : "Edit") {
                                isEditing.toggle()
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)

                        Rectangle()
                            .fill(separatorColor)
                            .frame(height: 1)

                        HStack(spacing: 12) {
                            Button {
                                formatting.perform(.bold)
                            } label: {
                                Image(systemName: "bold")
                                    .foregroundColor(themeManager.colors.text)
                            }
                            .keyboardShortcut("b", modifiers: .command)
                            .help("Bold (⌘B)")

                            Button {
                                formatting.perform(.italic)
                            } label: {
                                Image(systemName: "italic")
                                    .foregroundColor(themeManager.colors.text)
                            }
                            .keyboardShortcut("i", modifiers: .command)
                            .help("Italic (⌘I)")

                            Button {
                                formatting.perform(.title)
                            } label: {
                                Image(systemName: "textformat.size")
                                    .foregroundColor(themeManager.colors.text)
                            }
                            .help("Add Title")

                            Spacer()
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)

                        Rectangle()
                            .fill(separatorColor)
                            .frame(height: 1)

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
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "note.text")
                            .font(.largeTitle)
                        Text("Create a note or add a Markdown file to the Notes folder.")
                            .multilineTextAlignment(.center)
                            .foregroundColor(themeManager.colors.tabText)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity)
            .background(themeManager.colors.editorBackground)
            .onChange(of: model.content) { _, _ in
                model.saveCurrentNote()
            }
        }
        .environment(
            \.colorScheme,
            themeManager.currentTheme == .light ? .light : .dark
        )
        .onAppear(perform: model.loadWorkspace)
        .onChange(of: model.selectedNoteURL) { _, _ in
            isEditing = false
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
    }

    private func beginRenaming(_ url: URL) {
        renameTargetURL = url
        renameText = url.deletingPathExtension().lastPathComponent
        isRenamePresented = true
    }

    private func confirmRename() {
        guard let renameTargetURL else { return }
        model.renameNote(at: renameTargetURL, to: renameText)
        isRenamePresented = false
    }
}
