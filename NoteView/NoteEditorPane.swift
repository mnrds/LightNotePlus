//  LightNote+
//
//  NoteEditorPane.swift
//  Formatting toolbar, editor/preview layout and status bar.
//
// Created by mnrds
//

import SwiftUI
import AppKit

// Formatting toolbar buttons for the Markdown editor and preview.
struct NoteFormattingToolbar: View {
    let colors: ThemeColors
    let formatting: NoteEditorFormatting
    let documentID: String
    let onLink: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            formatButton("textformat.size", help: "Add Title") {
                formatting.perform(.title, for: documentID)
            }
            formatButton("bold", help: "Bold (⌘B)") {
                formatting.perform(.bold, for: documentID)
            }
            formatButton("italic", help: "Italic (⌘I)") {
                formatting.perform(.italic, for: documentID)
            }
            formatButton("underline", help: "Underline") {
                formatting.perform(.underline, for: documentID)
            }
            Button {
                formatting.perform(.strikethrough, for: documentID)
            } label: {
                Text("A\u{0336}")
                    .foregroundColor(colors.text)
            }
            .help("Strikethrough")
            formatButton("line.3.horizontal", help: "Insert Separator") {
                formatting.perform(.separator, for: documentID)
            }
            formatButton("checklist", help: "Insert Checklist Item") {
                formatting.perform(.checklist, for: documentID)
            }
            formatButton("text.quote", help: "Insert Quote") {
                formatting.perform(.quote, for: documentID)
            }
            formatButton("link", help: "Insert Hyperlink", action: onLink)
            Spacer()
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func formatButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundColor(colors.text)
        }
        .help(help)
    }
}

// Editor or preview for the open note. Observes only the document's revision,
// which changes when the text is replaced (open, reload), not on keystrokes.
struct NoteEditorContent: View {
    @ObservedObject var document: NoteDocument
    let documentID: String
    let isEditing: Bool
    let isSplit: Bool
    let colors: ThemeColors
    let fontScale: CGFloat
    @ObservedObject var formatting: NoteEditorFormatting
    @ObservedObject var search: NoteSearchModel
    let onUserEdit: () -> Void

    var body: some View {
        if isSplit {
            HSplitView {
                editor
                    .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
                preview(isSecondary: true)
                    .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if isEditing {
            editor
        } else {
            preview(isSecondary: false)
        }
    }

    private var editor: some View {
        NoteMarkdownEditor(
            document: document,
            revision: document.revision,
            documentID: documentID,
            textColor: colors.editorText,
            fontScale: fontScale,
            onUserEdit: onUserEdit,
            formatting: formatting,
            search: search
        )
    }

    private func preview(isSecondary: Bool) -> some View {
        NoteMarkdownPreview(
            document: document,
            revision: document.revision,
            documentID: documentID,
            textColor: colors.editorText,
            backgroundColor: colors.editorBackground,
            fontScale: fontScale,
            onUserEdit: onUserEdit,
            formatting: formatting,
            search: search,
            isSecondary: isSecondary
        )
    }
}

// Word and character counts; the only view that redraws while typing.
struct NoteStatusBar: View {
    @ObservedObject var statistics: NoteTextStatisticsModel
    let textColor: Color
    let backgroundColor: Color

    var body: some View {
        HStack {
            Spacer()
            Text("Words: \(statistics.statistics.words)  |  Characters: \(statistics.statistics.characters)")
                .font(.system(size: 11))
                .foregroundColor(textColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(backgroundColor)
    }
}
