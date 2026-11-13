//  LightNote+
//
//  NotePreviewTextView.swift
//  Preview text view, its attribute keys and parsed Markdown blocks.
//
// Created by mnrds
//

import SwiftUI
import AppKit

// Preview rendering and interaction details such as dividers and quote backgrounds.
final class PreviewMarkdownTextView: NSTextView {
    var onInsertNewline: (() -> Bool)?
    var onBold: (() -> Void)?
    var onItalic: (() -> Void)?
    var onToggleChecklist: ((NSRange) -> Void)?

    /// Line range of the checklist item at the insertion point, if any.
    var checklistLineAtSelection: NSRange? {
        let source = string as NSString
        let location = selectedRange().location
        guard location != NSNotFound, location < source.length,
              textStorage?.attribute(.noteChecklistChecked, at: location, effectiveRange: nil) != nil
                || (location > 0 && textStorage?.attribute(
                    .noteChecklistChecked, at: location - 1, effectiveRange: nil) != nil) else {
            return nil
        }
        let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
        guard textStorage?.attribute(.noteChecklistChecked, at: lineRange.location, effectiveRange: nil) != nil else {
            return nil
        }
        return lineRange
    }

    @discardableResult
    func toggleChecklistAtSelection() -> Bool {
        guard let lineRange = checklistLineAtSelection else { return false }
        onToggleChecklist?(lineRange)
        return true
    }

    // Lets VoiceOver users toggle a checklist item (VO-⌘-Space, Actions).
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        var actions = super.accessibilityCustomActions() ?? []
        if checklistLineAtSelection != nil {
            actions.append(
                NSAccessibilityCustomAction(name: "Toggle Checklist Item") { [weak self] in
                    self?.toggleChecklistAtSelection() ?? false
                }
            )
        }
        return actions
    }

    override func insertNewline(_ sender: Any?) {
        guard isEditable else {
            super.insertNewline(sender)
            return
        }
        guard onInsertNewline?() != true else { return }
        super.insertNewline(sender)
    }

    // Quote backgrounds are drawn here so they appear above the view's own
    // background fill but below the text.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let textStorage, let layoutManager, let textContainer else { return }

        let fullRange = NSRange(location: 0, length: textStorage.length)
        let containerOrigin = textContainerOrigin
        textStorage.enumerateAttribute(.noteQuoteBackground, in: fullRange) { value, range, _ in
            guard let color = value as? NSColor, range.length > 0 else { return }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: range,
                actualCharacterRange: nil
            )
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
                lineRect, _, _, _, _ in
                let backgroundRect = NSRect(
                    x: containerOrigin.x,
                    y: lineRect.minY + containerOrigin.y,
                    width: textContainer.containerSize.width,
                    height: lineRect.height
                )
                guard backgroundRect.intersects(rect) else { return }
                color.setFill()
                backgroundRect.fill()
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let textStorage, let layoutManager, let textContainer else { return }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        let containerOrigin = textContainerOrigin

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
            let y = lineRect.midY + containerOrigin.y
            let inset = containerOrigin.x
            let path = NSBezierPath()
            path.lineWidth = 1
            path.move(to: NSPoint(x: inset, y: y))
            path.line(to: NSPoint(x: max(inset, self.bounds.width - inset), y: y))
            (self.textColor ?? NSColor.separatorColor).withAlphaComponent(0.35).setStroke()
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
            // Checkboxes toggle in the read-only preview too; the coordinator
            // writes the change back to the Markdown source.
            if isChecklist,
               characterIndex < lineRange.location + prefixLength {
                onToggleChecklist?(lineRange)
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘↩ toggles the checklist item at the insertion point, also when read-only.
        if window?.firstResponder === self,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "\r",
           toggleChecklistAtSelection() {
            return true
        }
        guard isEditable else {
            return super.performKeyEquivalent(with: event)
        }
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

extension NSAttributedString.Key {
    static let noteParagraphKind = NSAttributedString.Key("LightNotePlus.ParagraphKind")
    static let noteHeadingLevel = NSAttributedString.Key("LightNotePlus.HeadingLevel")
    static let noteListPrefix = NSAttributedString.Key("LightNotePlus.ListPrefix")
    static let noteVisiblePrefixLength = NSAttributedString.Key("LightNotePlus.VisiblePrefixLength")
    static let noteChecklistChecked = NSAttributedString.Key("LightNotePlus.ChecklistChecked")
    static let noteTextUnderline = NSAttributedString.Key("LightNotePlus.TextUnderline")
    static let noteTextStrikethrough = NSAttributedString.Key("LightNotePlus.TextStrikethrough")
    static let noteFontSize = NSAttributedString.Key("LightNotePlus.FontSize")
    static let noteQuoteBackground = NSAttributedString.Key("LightNotePlus.QuoteBackground")
}

// Parsed Markdown blocks used to render and edit the note preview.
struct NoteMarkdownBlock: Identifiable {
    enum Kind {
        case heading(level: Int)
        case paragraph
        case unorderedItem(indent: Int, marker: String)
        case checklistItem(indent: Int, checked: Bool, marker: String)
        case orderedItem(indent: Int, number: String)
        case quote
        case code
        case divider
        case blankLine
    }

    let id: Int
    let kind: Kind
    let text: String
}
