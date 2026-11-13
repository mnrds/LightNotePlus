//  LightNote+
//
//  NoteMarkdownPreview.swift
//  Rendered Markdown preview (NSViewRepresentable).
//
// Created by mnrds
//

import SwiftUI
import AppKit

// Renders Markdown and converts preview edits back to the note source.
struct NoteMarkdownPreview: NSViewRepresentable {
    let document: NoteDocument
    /// Changes only when the note text is replaced outside the preview.
    let revision: Int
    let documentID: String
    let textColor: Color
    let backgroundColor: Color
    /// Preview zoom (Settings × View zoom), applied as scroll-view magnification
    /// so headings, checkboxes and code keep their relative sizes.
    let fontScale: CGFloat
    let onUserEdit: () -> Void
    @ObservedObject var formatting: NoteEditorFormatting
    @ObservedObject var search: NoteSearchModel
    /// True when shown beside the editor: the editor then owns keyboard
    /// focus and find-in-note, and the preview follows its edits.
    var isSecondary = false
    @Environment(\.isPaneActive) private var isPaneActive

    // Quote indentation (points) and a background that adapts to light/dark text.
    static let quoteIndent: CGFloat = 16

    static func quoteBackground(for textColor: NSColor) -> NSColor {
        let brightness = textColor.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 0
        return brightness > 0.5
            ? NSColor(calibratedWhite: 0.22, alpha: 1)   // dark theme
            : NSColor(calibratedWhite: 0.94, alpha: 1)   // light theme
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document, documentID: documentID, onUserEdit: onUserEdit)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        // Keep edits typed within the debounce window when the preview goes away.
        coordinator.flushPendingConversion()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PreviewMarkdownTextView()
        textView.delegate = context.coordinator
        textView.onInsertNewline = { [weak textView] in
            guard let textView else { return false }
            return context.coordinator.handleNewline(in: textView)
        }
        textView.onBold = { [weak textView] in
            guard let textView else { return }
            context.coordinator.toggleTrait(.boldFontMask, in: textView)
        }
        textView.onItalic = { [weak textView] in
            guard let textView else { return }
            context.coordinator.toggleTrait(.italicFontMask, in: textView)
        }
        textView.onToggleChecklist = { [weak textView] range in
            guard let textView else { return }
            context.coordinator.toggleChecklist(at: range, in: textView)
        }
        textView.isRichText = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.drawsBackground = true
        textView.textColor = NSColor(textColor)
        textView.backgroundColor = NSColor(backgroundColor)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 40, height: 32)
        context.coordinator.configure(textView, textColor: NSColor(textColor))
        context.coordinator.attach(textView)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(backgroundColor)
        scrollView.documentView = textView
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.5
        scrollView.maxMagnification = 4
        scrollView.magnification = fontScale
        scrollView.isHidden = !isPaneActive
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? PreviewMarkdownTextView else { return }
        if scrollView.isHidden == isPaneActive {
            scrollView.isHidden = !isPaneActive
        }
        if context.coordinator.lastFontScale != fontScale {
            context.coordinator.lastFontScale = fontScale
            scrollView.magnification = fontScale
        }
        context.coordinator.document = document
        context.coordinator.onUserEdit = onUserEdit
        let resolvedTextColor = NSColor(textColor)
        let themeChanged = context.coordinator.lastRenderedTextColor?.isEqual(resolvedTextColor) != true
        if themeChanged {
            textView.textColor = resolvedTextColor
        }
        textView.backgroundColor = NSColor(backgroundColor)
        scrollView.backgroundColor = NSColor(backgroundColor)

        if context.coordinator.documentID != documentID {
            // The workspace flushes pending edits before switching notes.
            context.coordinator.cancelPendingConversion()
            textView.undoManager?.removeAllActions()
            context.coordinator.documentID = documentID
            context.coordinator.lastSearchRequestID = nil
        }

        if context.coordinator.lastRevision != revision || themeChanged {
            if themeChanged {
                context.coordinator.flushPendingConversion()
            }
            context.coordinator.configure(textView, textColor: resolvedTextColor)
        }

        guard !isSecondary else { return }
        context.coordinator.performSearchIfNeeded(in: textView, search: search)
        formatting.applyFocusIfRequested(to: textView, documentID: documentID)
        // Check editability before claiming, so a read-only preview never
        // consumes a formatting request meant for the editor.
        guard textView.isEditable,
              let request = formatting.request,
              formatting.claim(request, for: documentID) else { return }
        switch request.action {
        case .bold:
            context.coordinator.toggleTrait(.boldFontMask, in: textView)
        case .italic:
            context.coordinator.toggleTrait(.italicFontMask, in: textView)
        case .underline:
            context.coordinator.toggleDecoration(.underlineStyle, in: textView)
        case .strikethrough:
            context.coordinator.toggleDecoration(.strikethroughStyle, in: textView)
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
}
