//  LightNote+
//
//  NoteMarkdownPreviewCoordinator.swift
//  Preview interaction: edits, checklists, formatting and Markdown write-back.
//
// Created by mnrds
//

import SwiftUI
import Combine
import AppKit

extension NoteMarkdownPreview {
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var document: NoteDocument
        var documentID: String
        var onUserEdit: () -> Void
        var isUpdatingTextView = false
        var lastRenderedTextColor: NSColor?
        var lastRevision: Int?
        var lastFontScale: CGFloat?
        var lastSearchRequestID: UUID?
        private weak var textView: NSTextView?
        private var editorEditsSubscription: AnyCancellable?

        /// Re-renders after edits in the editor (split layout) once typing pauses.
        func attach(_ textView: NSTextView) {
            self.textView = textView
            editorEditsSubscription = document.userEdits
                .filter { $0 == .editor }
                .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
                .sink { [weak self] _ in self?.refreshFromDocument() }
        }

        private func refreshFromDocument() {
            guard let textView,
                  let textColor = lastRenderedTextColor,
                  pendingTextView == nil,
                  let clipView = textView.enclosingScrollView?.contentView else { return }
            // Keep the reader's place while the content is rebuilt.
            let origin = clipView.bounds.origin
            configure(textView, textColor: textColor)
            if let textContainer = textView.textContainer {
                textView.layoutManager?.ensureLayout(for: textContainer)
            }
            clipView.scroll(to: origin)
            textView.enclosingScrollView?.reflectScrolledClipView(clipView)
        }

        // Converting the attributed text back to Markdown walks the whole
        // document, so it runs once typing pauses instead of on every keystroke.
        private static let conversionDelay: Duration = .milliseconds(300)
        private var pendingConversionTask: Task<Void, Never>?
        private weak var pendingTextView: NSTextView?
        private var pendingRevision: Int?
        private var pendingDocumentID: String?

        init(
            document: NoteDocument,
            documentID: String,
            onUserEdit: @escaping () -> Void
        ) {
            self.document = document
            self.documentID = documentID
            self.onUserEdit = onUserEdit
        }

        func scheduleMarkdownConversion(from textView: NSTextView) {
            pendingConversionTask?.cancel()
            pendingTextView = textView
            pendingRevision = document.revision
            pendingDocumentID = documentID
            document.setPendingEditsHandler { [weak self] in
                self?.flushPendingConversion()
            }
            pendingConversionTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: Self.conversionDelay)
                } catch {
                    return
                }
                self?.flushPendingConversion()
            }
        }

        /// Writes pending preview edits to the document immediately.
        func flushPendingConversion() {
            guard let textView = pendingTextView else {
                cancelPendingConversion()
                return
            }
            let revision = pendingRevision
            let targetDocumentID = pendingDocumentID
            cancelPendingConversion()
            // Drop the edit if the note was replaced or switched in the meantime.
            guard revision == document.revision,
                  targetDocumentID == documentID else { return }
            let markdown = NoteMarkdownPreview.markdown(from: textView.attributedString())
            document.applyUserEdit(markdown, from: .preview)
            onUserEdit()
        }

        func cancelPendingConversion() {
            pendingConversionTask?.cancel()
            pendingConversionTask = nil
            pendingTextView = nil
            pendingRevision = nil
            pendingDocumentID = nil
            document.setPendingEditsHandler(nil)
        }

        func performSearchIfNeeded(in textView: NSTextView, search: NoteSearchModel) {
            guard let request = search.request,
                  request.id != lastSearchRequestID else { return }
            lastSearchRequestID = request.id
            search.search(request, in: textView)
        }

        func configure(_ textView: NSTextView, textColor: NSColor) {
            cancelPendingConversion()
            let selection = textView.selectedRange()
            textView.undoManager?.removeAllActions()
            isUpdatingTextView = true
            textView.textStorage?.setAttributedString(
                NoteMarkdownPreview.attributedString(from: document.text, textColor: textColor)
            )
            textView.setSelectedRange(NSRange(location: min(selection.location, textView.string.utf16.count), length: 0))
            lastRevision = document.revision
            lastRenderedTextColor = textColor
            isUpdatingTextView = false
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdatingTextView,
                  let textView = notification.object as? NSTextView,
                  textView.isEditable else { return }
            formatTypedUnorderedList(in: textView)
            formatTypedBlockMarker(in: textView)
            scheduleMarkdownConversion(from: textView)
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL)
                ?? (link as? String).flatMap(URL.init(string:))
            guard let url, NoteLinkURL.allows(url) else { return true }
            NSWorkspace.shared.open(url)
            return true
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            let source = textView.string as NSString
            guard affectedCharRange.location != NSNotFound,
                  affectedCharRange.location <= source.length,
                  affectedCharRange.length <= source.length - affectedCharRange.location,
                  let textStorage = textView.textStorage else {
                return false
            }

            let lastAffectedLocation = affectedCharRange.length == 0
                ? affectedCharRange.location
                : affectedCharRange.location + affectedCharRange.length - 1
            var lineLocation = source.lineRange(
                for: NSRange(location: affectedCharRange.location, length: 0)
            ).location

            while lineLocation <= lastAffectedLocation, lineLocation < source.length {
                let lineRange = source.lineRange(
                    for: NSRange(location: lineLocation, length: 0)
                )
                let attributes = textStorage.attributes(at: lineLocation, effectiveRange: nil)
                if attributes[.noteParagraphKind] as? String == "divider" {
                    return false
                }

                let visiblePrefixLength = attributes[.noteVisiblePrefixLength] as? Int ?? 0
                if visiblePrefixLength > 0 {
                    let protectedRange = NSRange(
                        location: lineLocation,
                        length: min(visiblePrefixLength, lineRange.length)
                    )
                    if affectedCharRange.length == 0 {
                        if affectedCharRange.location < NSMaxRange(protectedRange) {
                            return false
                        }
                    } else if NSIntersectionRange(affectedCharRange, protectedRange).length > 0 {
                        return false
                    }
                }

                let nextLineLocation = NSMaxRange(lineRange)
                guard nextLineLocation > lineLocation else { break }
                lineLocation = nextLineLocation
            }

            return true
        }

        private func formatTypedUnorderedList(in textView: NSTextView) {
            guard let textStorage = textView.textStorage else { return }
            let source = textView.string as NSString
            let selection = textView.selectedRange()
            guard selection.location != NSNotFound,
                  selection.location <= source.length else { return }

            let lineRange = source.lineRange(
                for: NSRange(location: selection.location, length: 0)
            )
            let line = source.substring(with: lineRange) as NSString
            let paragraphKind = textStorage.attribute(
                .noteParagraphKind,
                at: lineRange.location,
                effectiveRange: nil
            ) as? String
            guard line.length >= 2,
                  ["-", "+", "*"].contains(line.substring(to: 1)),
                  line.substring(with: NSRange(location: 1, length: 1)) == " ",
                  paragraphKind != "unordered",
                  paragraphKind != "code" else {
                return
            }

            let marker = NSRange(location: lineRange.location, length: 2)
            let listPrefix = line.substring(to: 2)
            textStorage.replaceCharacters(in: marker, with: "•  ")
            let updatedLineRange = NSRange(
                location: lineRange.location,
                length: lineRange.length + 1
            )
            textStorage.addAttributes(
                [
                    .noteParagraphKind: "unordered",
                    .noteListPrefix: listPrefix,
                    .noteVisiblePrefixLength: 3
                ],
                range: updatedLineRange
            )
            textStorage.addAttribute(
                .font,
                value: NSFont.systemFont(ofSize: 16),
                range: NSRange(location: lineRange.location, length: 3)
            )
            textView.setSelectedRange(
                NSRange(
                    location: selection.location >= NSMaxRange(marker)
                        ? selection.location + 1
                        : selection.location,
                    length: selection.length
                )
            )
        }

        private static let headingMarker = try! NSRegularExpression(pattern: #"^(#{1,6}) "#)
        private static let quoteMarker = try! NSRegularExpression(pattern: #"^> "#)
        private static let orderedMarker = try! NSRegularExpression(pattern: #"^(\d{1,9})([.)]) "#)
        private static let firstNumber = try! NSRegularExpression(pattern: #"\d+"#)

        /// Matches the Markdown editor: typing "# "…"###### ", "> " or "1. " at
        /// the start of a plain line turns it into a heading, quote or ordered item.
        private func formatTypedBlockMarker(in textView: NSTextView) {
            guard let textStorage = textView.textStorage else { return }
            let source = textView.string as NSString
            let selection = textView.selectedRange()
            guard selection.location != NSNotFound,
                  selection.length == 0,
                  selection.location <= source.length else { return }
            let lineRange = source.lineRange(for: NSRange(location: selection.location, length: 0))
            guard lineRange.length >= 2 else { return }
            let attributes = textStorage.attributes(at: lineRange.location, effectiveRange: nil)
            let paragraphKind = attributes[.noteParagraphKind] as? String
            guard attributes[.noteHeadingLevel] == nil,
                  paragraphKind == nil || paragraphKind == "paragraph" || paragraphKind == "blankLine" else {
                return
            }

            let line = source.substring(with: lineRange)
            let lineNSRange = NSRange(location: 0, length: (line as NSString).length)
            // Convert only right after the marker's space was typed.
            func marker(_ expression: NSRegularExpression) -> NSTextCheckingResult? {
                guard let match = expression.firstMatch(in: line, range: lineNSRange),
                      selection.location == lineRange.location + match.range.length else { return nil }
                return match
            }

            if let match = marker(Self.headingMarker) {
                let level = match.range(at: 1).length
                textStorage.replaceCharacters(
                    in: NSRange(location: lineRange.location, length: match.range.length),
                    with: ""
                )
                textView.setSelectedRange(NSRange(location: lineRange.location, length: 0))
                setHeading(level: level, in: textView)
            } else if let match = marker(Self.quoteMarker) {
                textStorage.replaceCharacters(
                    in: NSRange(location: lineRange.location, length: match.range.length),
                    with: ""
                )
                let textColor = textView.textColor ?? NSColor.labelColor
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.firstLineHeadIndent = NoteMarkdownPreview.quoteIndent
                paragraphStyle.headIndent = NoteMarkdownPreview.quoteIndent
                let quoteAttributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 16),
                    .foregroundColor: textColor,
                    .noteParagraphKind: "quote",
                    .noteListPrefix: "> ",
                    .noteVisiblePrefixLength: 0,
                    .noteQuoteBackground: NoteMarkdownPreview.quoteBackground(for: textColor),
                    .paragraphStyle: paragraphStyle
                ]
                let remainingLength = lineRange.length - match.range.length
                if remainingLength > 0 {
                    textStorage.addAttributes(
                        quoteAttributes,
                        range: NSRange(location: lineRange.location, length: remainingLength)
                    )
                }
                var typingAttributes = textView.typingAttributes
                quoteAttributes.forEach { typingAttributes[$0.key] = $0.value }
                textView.typingAttributes = typingAttributes
                textView.setSelectedRange(NSRange(location: lineRange.location, length: 0))
            } else if let match = marker(Self.orderedMarker) {
                let markdownPrefix = (line as NSString).substring(with: match.range)
                let number = (line as NSString).substring(with: match.range(at: 1))
                let delimiter = (line as NSString).substring(with: match.range(at: 2))
                let visiblePrefix = "\(number)\(delimiter)  "
                let visibleLength = (visiblePrefix as NSString).length
                textStorage.replaceCharacters(
                    in: NSRange(location: lineRange.location, length: match.range.length),
                    with: visiblePrefix
                )
                textStorage.addAttributes(
                    [
                        .font: NSFont.systemFont(ofSize: 16),
                        .noteParagraphKind: "ordered",
                        .noteListPrefix: markdownPrefix,
                        .noteVisiblePrefixLength: visibleLength
                    ],
                    range: NSRange(
                        location: lineRange.location,
                        length: lineRange.length - match.range.length + visibleLength
                    )
                )
                textView.setSelectedRange(
                    NSRange(location: lineRange.location + visibleLength, length: 0)
                )
            }
        }

        /// "  3. " → "  4. " (also for the visible "3.  " prefix).
        private static func incrementedOrderedPrefix(_ prefix: String) -> String {
            let range = NSRange(location: 0, length: (prefix as NSString).length)
            guard let match = firstNumber.firstMatch(in: prefix, range: range),
                  let number = Int((prefix as NSString).substring(with: match.range)) else {
                return prefix
            }
            return (prefix as NSString).replacingCharacters(in: match.range, with: String(number + 1))
        }

        func handleNewline(in textView: PreviewMarkdownTextView) -> Bool {
            let source = textView.string as NSString
            let selection = textView.selectedRange()
            guard selection.location != NSNotFound,
                  selection.location <= source.length,
                  NSMaxRange(selection) <= source.length else {
                return false
            }

            guard source.length > 0 else { return false }
            let isTrailingEmptyLine = selection.location == source.length
                && source.character(at: source.length - 1) == 10
            let lineRange = isTrailingEmptyLine
                ? NSRange(location: source.length, length: 0)
                : source.lineRange(for: NSRange(location: selection.location, length: 0))
            let attributes: [NSAttributedString.Key: Any]
            if lineRange.location < source.length {
                attributes = textView.textStorage?.attributes(
                    at: lineRange.location,
                    effectiveRange: nil
                ) ?? [:]
            } else {
                attributes = [:]
            }
            if attributes[.noteHeadingLevel] != nil {
                textView.insertText("\n", replacementRange: selection)
                var typingAttributes = textView.typingAttributes
                typingAttributes[.font] = NSFont.systemFont(ofSize: 16)
                typingAttributes[.foregroundColor] = textView.textColor ?? NSColor.labelColor
                for key: NSAttributedString.Key in [
                    .noteParagraphKind,
                    .noteHeadingLevel,
                    .noteListPrefix,
                    .noteVisiblePrefixLength,
                    .noteChecklistChecked,
                    .link,
                    .underlineStyle
                ] {
                    typingAttributes.removeValue(forKey: key)
                }
                textView.typingAttributes = typingAttributes
                textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
                return true
            }

            let paragraphKind = attributes[.noteParagraphKind] as? String
            guard paragraphKind == "checklist"
                    || paragraphKind == "unordered"
                    || paragraphKind == "ordered" else {
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
                return true
            }

            let visiblePrefix = source.substring(
                with: NSRange(location: lineRange.location, length: prefixLength)
            )
            if paragraphKind == "ordered" {
                let markdownPrefix = attributes[.noteListPrefix] as? String ?? "1. "
                let nextVisiblePrefix = Self.incrementedOrderedPrefix(visiblePrefix)
                let nextAttributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 16),
                    .foregroundColor: textView.textColor ?? NSColor.labelColor,
                    .noteParagraphKind: "ordered",
                    .noteListPrefix: Self.incrementedOrderedPrefix(markdownPrefix),
                    .noteVisiblePrefixLength: (nextVisiblePrefix as NSString).length
                ]
                let insertion = NSMutableAttributedString(
                    string: "\n" + nextVisiblePrefix,
                    attributes: nextAttributes
                )
                textView.textStorage?.replaceCharacters(in: selection, with: insertion)
                textView.setSelectedRange(
                    NSRange(location: selection.location + insertion.length, length: 0)
                )
                textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
                return true
            }

            if paragraphKind == "unordered" {
                let markdownPrefix = attributes[.noteListPrefix] as? String ?? "- "
                let nextAttributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 16),
                    .foregroundColor: textView.textColor ?? NSColor.labelColor,
                    .noteParagraphKind: "unordered",
                    .noteListPrefix: markdownPrefix,
                    .noteVisiblePrefixLength: prefixLength
                ]
                let insertion = NSMutableAttributedString(
                    string: "\n" + visiblePrefix,
                    attributes: nextAttributes
                )
                textView.textStorage?.replaceCharacters(in: selection, with: insertion)
                textView.setSelectedRange(
                    NSRange(location: selection.location + insertion.length, length: 0)
                )
                textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
                return true
            }

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
            if let checkboxIndex = checkboxPrefix.firstIndex(where: { $0 == "☐" || $0 == "☑" }) {
                let checkboxOffset = checkboxPrefix[..<checkboxIndex].utf16.count
                insertion.addAttribute(
                    .font,
                    value: NSFont.systemFont(ofSize: 23),
                    range: NSRange(location: 1 + checkboxOffset, length: 1)
                )
            }
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

        func toggleDecoration(_ key: NSAttributedString.Key, in textView: NSTextView) {
            let markerKey: NSAttributedString.Key?
            if key == .underlineStyle {
                markerKey = .noteTextUnderline
            } else if key == .strikethroughStyle {
                markerKey = .noteTextStrikethrough
            } else {
                markerKey = nil
            }
            let range = textView.selectedRange()
            let length = (textView.string as NSString).length
            let isApplied: Bool
            if range.length > 0, range.location < length {
                let value = textView.textStorage?.attribute(
                    markerKey ?? key,
                    at: range.location,
                    effectiveRange: nil
                )
                isApplied = value as? Bool == true
            } else {
                let value = textView.typingAttributes[markerKey ?? key]
                isApplied = value as? Bool == true
            }

            if range.length > 0, NSMaxRange(range) <= length {
                if isApplied {
                    textView.textStorage?.removeAttribute(key, range: range)
                    if let markerKey {
                        textView.textStorage?.removeAttribute(markerKey, range: range)
                    }
                } else {
                    textView.textStorage?.addAttribute(
                        key,
                        value: NSUnderlineStyle.single.rawValue,
                        range: range
                    )
                    if let markerKey {
                        textView.textStorage?.addAttribute(markerKey, value: true, range: range)
                    }
                }
            }

            var typingAttributes = textView.typingAttributes
            if isApplied {
                typingAttributes.removeValue(forKey: key)
                if let markerKey {
                    typingAttributes.removeValue(forKey: markerKey)
                }
            } else {
                typingAttributes[key] = NSUnderlineStyle.single.rawValue
                if let markerKey {
                    typingAttributes[markerKey] = true
                }
            }
            textView.typingAttributes = typingAttributes
            textViewDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        }

        func setHeading(level: Int, in textView: NSTextView) {
            let source = textView.string as NSString
            let selection = textView.selectedRange()
            let location = min(selection.location, source.length)
            let isTrailingEmptyLine = location == source.length
                && source.length > 0
                && source.character(at: source.length - 1) == 10
            let lineRange = isTrailingEmptyLine
                ? NSRange(location: source.length, length: 0)
                : source.lineRange(for: NSRange(location: location, length: 0))
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
            let previousLineIsBlank: Bool
            if insertLocation > 0 {
                let previousLineRange = source.lineRange(
                    for: NSRange(location: insertLocation - 1, length: 0)
                )
                previousLineIsBlank = source.substring(with: previousLineRange)
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } else {
                previousLineIsBlank = false
            }
            let followingLineIsBlank: Bool
            if insertLocation < source.length {
                let followingLineRange = source.lineRange(
                    for: NSRange(location: insertLocation, length: 0)
                )
                followingLineIsBlank = source.substring(with: followingLineRange)
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } else {
                followingLineIsBlank = false
            }
            let previousTextHasNewline = source.substring(to: insertLocation).hasSuffix("\n")
            let leadingNewlines: String
            if insertLocation == 0 || previousLineIsBlank {
                leadingNewlines = ""
            } else {
                leadingNewlines = previousTextHasNewline ? "\n" : "\n\n"
            }
            let trailingNewlines = followingLineIsBlank ? "\n" : "\n\n"
            let separator = NSMutableAttributedString(string: leadingNewlines)
            separator.append(
                NSAttributedString(
                    string: "\u{200B}",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 16),
                        .foregroundColor: textView.textColor ?? NSColor.labelColor,
                        .noteParagraphKind: "divider"
                    ]
                )
            )
            separator.append(NSAttributedString(string: trailingNewlines))
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
                visiblePrefix: "",
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
            let currentLineIsEmpty = source.substring(with: lineRange)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16),
                .foregroundColor: textView.textColor ?? NSColor.labelColor,
                .noteParagraphKind: kind,
                .noteListPrefix: markdownPrefix,
                .noteVisiblePrefixLength: (visiblePrefix as NSString).length
            ]
            if kind == "quote" {
                let textColor = textView.textColor ?? NSColor.labelColor
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.firstLineHeadIndent = NoteMarkdownPreview.quoteIndent
                paragraphStyle.headIndent = NoteMarkdownPreview.quoteIndent
                attributes[.noteQuoteBackground] = NoteMarkdownPreview.quoteBackground(for: textColor)
                attributes[.paragraphStyle] = paragraphStyle
            }
            let leadingNewline = currentLineIsEmpty ? "" : "\n"
            let insertion = NSMutableAttributedString(string: leadingNewline)
            if !visiblePrefix.isEmpty {
                insertion.append(
                    NSMutableAttributedString(string: visiblePrefix, attributes: attributes)
                )
            }
            if kind == "checklist",
               let checkboxIndex = visiblePrefix.firstIndex(where: { $0 == "☐" || $0 == "☑" }) {
                let checkboxOffset = visiblePrefix[..<checkboxIndex].utf16.count
                insertion.addAttribute(
                    .font,
                    value: NSFont.systemFont(ofSize: 23),
                    range: NSRange(
                        location: (leadingNewline as NSString).length + checkboxOffset,
                        length: 1
                    )
                )
            }
            if let checklistChecked {
                insertion.addAttribute(
                    .noteChecklistChecked,
                    value: checklistChecked,
                    range: NSRange(
                        location: (leadingNewline as NSString).length,
                        length: (visiblePrefix as NSString).length
                    )
                )
            }
            if !hasTrailingNewline {
                insertion.append(NSAttributedString(string: "\n"))
            }
            textView.textStorage?.insert(insertion, at: insertLocation)
            let lineStart = insertLocation + (leadingNewline as NSString).length
            if visiblePrefix.isEmpty,
               let textStorage = textView.textStorage,
               lineStart < textStorage.length {
                textStorage.addAttributes(attributes, range: NSRange(location: lineStart, length: 1))
            }
            textView.setSelectedRange(
                NSRange(
                    location: lineStart + (visiblePrefix as NSString).length,
                    length: 0
                )
            )
            textViewDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        }

        func toggleChecklist(at lineRange: NSRange, in textView: NSTextView) {
            guard lineRange.length > 0 else { return }
            let visiblePrefixLength = textView.textStorage?.attribute(
                .noteVisiblePrefixLength,
                at: lineRange.location,
                effectiveRange: nil
            ) as? Int ?? 0
            guard visiblePrefixLength > 0,
                  visiblePrefixLength <= lineRange.length else { return }
            let visiblePrefix = (textView.string as NSString).substring(
                with: NSRange(location: lineRange.location, length: visiblePrefixLength)
            )
            let checkboxOffset = (visiblePrefix as NSString).range(
                of: "[☐☑]",
                options: .regularExpression
            ).location
            guard checkboxOffset != NSNotFound else { return }
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
            let checkboxRange = NSRange(location: lineRange.location + checkboxOffset, length: 1)
            let checkbox = NSAttributedString(
                string: updated ? "☑" : "☐",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 23),
                    .foregroundColor: textView.textColor ?? NSColor.labelColor,
                    .noteParagraphKind: "checklist",
                    .noteListPrefix: updated ? "- [x] " : "- [ ] ",
                    .noteVisiblePrefixLength: visiblePrefixLength,
                    .noteChecklistChecked: updated
                ]
            )
            textView.textStorage?.replaceCharacters(in: checkboxRange, with: checkbox)
            textView.layoutManager?.invalidateLayout(
                forCharacterRange: lineRange,
                actualCharacterRange: nil
            )
            textView.setNeedsDisplay(textView.bounds)
            if textView.isEditable {
                textViewDidChange(Notification(name: NSText.didChangeNotification, object: textView))
            } else {
                // Read-only preview: write the toggle back to the Markdown right away.
                scheduleMarkdownConversion(from: textView)
                flushPendingConversion()
            }
            NSAccessibility.post(element: textView, notification: .valueChanged)
        }

        func insertLink(in textView: NSTextView, url: String) {
            let selection = textView.selectedRange()
            let source = textView.string as NSString
            guard selection.location != NSNotFound,
                  selection.location <= source.length,
                  NSMaxRange(selection) <= source.length,
                  let destination = NoteLinkURL.make(from: url) else { return }
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
            var typingAttributes = textView.typingAttributes
            typingAttributes.removeValue(forKey: .link)
            typingAttributes.removeValue(forKey: .underlineStyle)
            typingAttributes[.foregroundColor] = textView.textColor ?? NSColor.labelColor
            textView.typingAttributes = typingAttributes
            textViewDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        }

    }
}
