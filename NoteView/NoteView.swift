//  LightNote+
//
//  NoteView.swift
//  Main Notes interface: sidebar, tabs, editor pane and sheets.
//
// Created by mnrds
//

import SwiftUI
import AppKit

// Main Notes interface, including sidebar, tabs, editor, and preview.
struct NoteView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var findState: FindState
    @EnvironmentObject private var zoomState: ZoomState
    @AppStorage(NoteEditorSettings.fontSizeKey) private var notesFontSize = NoteEditorSettings.defaultFontSize
    @ObservedObject var model: NotesWorkspaceModel
    @StateObject private var formatting = NoteEditorFormatting()
    @StateObject private var noteSearch = NoteSearchModel()
    @State private var renameTargetURL: URL?
    @State private var renameText = ""
    @State private var isRenamePresented = false
    @State private var deleteTargetURL: URL?
    @State private var isDeleteConfirmationPresented = false
    @State private var headingTitle = ""
    @State private var headingToRename: NoteHeading?
    @State private var isHeadingPresented = false
    @State private var openNoteURLs: [URL] = []
    @State private var isSidebarVisible = true
    @State private var isLinkPresented = false
    @State private var linkURL = ""
    @State private var linkTargetDocumentID: String?
    @State private var isEditing = false
    @AppStorage("notesSplitView") private var isSplitView = false

    private var separatorColor: Color {
        themeManager.currentTheme == .light
            ? Color.black.opacity(0.16)
            : Color.white.opacity(0.16)
    }

    /// Settings font size × View > Zoom (Actual Size = 1).
    private var fontScale: CGFloat {
        NoteEditorSettings.scale(fontSize: notesFontSize, zoom: zoomState.fontSize)
    }

    var body: some View {
        HSplitView {
            if isSidebarVisible {
                NotesSidebar(
                    model: model,
                    separatorColor: separatorColor,
                    onOpenNote: { openNote($0) },
                    onFocusEditor: { url in openNote(url, focusEditor: true) },
                    onRenameNote: beginRenaming,
                    onDeleteNote: requestDelete,
                    onNewHeading: {
                        headingToRename = nil
                        headingTitle = ""
                        isHeadingPresented = true
                    },
                    onRenameHeading: beginRenamingHeading
                )
            }
            editorPane
        }
        .environment(
            \.colorScheme,
            themeManager.currentTheme == .light ? .light : .dark
        )
        .onAppear {
            if let selectedNoteURL = model.selectedNoteURL {
                openNoteURLs = [selectedNoteURL]
            }
            handleFindRequest()
        }
        .onDisappear {
            model.saveCurrentNote()
        }
        .onReceive(model.noteURLChanges) { change in
            switch change {
            case .renamed(let oldURL, let newURL):
                let oldPath = oldURL.standardizedFileURL.path
                let newPath = newURL.standardizedFileURL.path
                var seenPaths = Set<String>()
                openNoteURLs = openNoteURLs
                    .map { $0.standardizedFileURL.path == oldPath ? newURL : $0 }
                    .filter { seenPaths.insert($0.standardizedFileURL.path).inserted }
                if model.selectedNoteURL?.standardizedFileURL.path == newPath,
                   !openNoteURLs.contains(where: { $0.standardizedFileURL.path == newPath }) {
                    openNoteURLs.append(newURL)
                }
            case .deleted(let url):
                let deletedPath = url.standardizedFileURL.path
                openNoteURLs.removeAll { $0.standardizedFileURL.path == deletedPath }
            }
        }
        .onChange(of: findState.isPresented) { _, isPresented in
            if isPresented {
                handleFindRequest()
            }
        }
        .onChange(of: model.selectedNoteURL) { _, selectedNoteURL in
            formatting.cancel()
            isEditing = false
            openNoteURLs.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
            if let selectedNoteURL,
               !openNoteURLs.contains(where: { $0 == selectedNoteURL }) {
                openNoteURLs.append(selectedNoteURL)
            }
            if findState.isPresented {
                handleFindRequest()
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

    // Note tabs and the editor/preview content pane.
    private var editorPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                NoteTabBar(
                    openNoteURLs: openNoteURLs,
                    selectedNoteURL: model.selectedNoteURL,
                    hasUnsavedChanges: model.hasUnsavedChanges,
                    colors: themeManager.colors,
                    separatorColor: separatorColor,
                    onSelect: { openNote($0, focusEditor: true) },
                    onClose: closeNoteTab
                )

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

                Button {
                    // Commit debounced preview edits before the layout changes.
                    model.document.flushPendingEdits()
                    isSplitView.toggle()
                    if let selectedNoteURL = model.selectedNoteURL {
                        formatting.requestFocus(for: selectedNoteURL.standardizedFileURL.path)
                    }
                } label: {
                    Image(systemName: isSplitView ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                        .foregroundColor(themeManager.colors.tabText)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .help(isSplitView ? "Hide Side-by-Side Preview" : "Show Editor and Preview Side by Side")
                .accessibilityLabel("Side-by-Side Preview")
                .accessibilityValue(isSplitView ? "On" : "Off")

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

                    if !isSplitView {
                        Button(isEditing ? "Preview" : "Edit") {
                            // Commit debounced preview edits before the other view reads the text.
                            model.document.flushPendingEdits()
                            isEditing.toggle()
                            formatting.requestFocus(for: selectedNoteURL.standardizedFileURL.path)
                        }
                        .buttonStyle(.bordered)
                        .padding(.trailing, 12)
                    } else {
                        Spacer().frame(width: 4)
                    }
                }
            }
            .frame(height: 44)
            .background(themeManager.colors.tabBackground)

            Rectangle()
                .fill(separatorColor)
                .frame(height: 1)

            if noteSearch.isPresented {
                NoteSearch(search: noteSearch, onClose: closeNoteSearch)
            }

            if let selectedNoteURL = model.selectedNoteURL {
                NoteFormattingToolbar(
                    colors: themeManager.colors,
                    formatting: formatting,
                    documentID: selectedNoteURL.standardizedFileURL.path,
                    onLink: {
                        linkURL = "https://"
                        linkTargetDocumentID = selectedNoteURL.standardizedFileURL.path
                        isLinkPresented = true
                    }
                )
                .disabled(!isEditing && !isSplitView)
            }

            Rectangle()
                .fill(separatorColor)
                .frame(height: 1)

            Group {
                if let selectedNoteURL = model.selectedNoteURL {
                    NoteEditorContent(
                        document: model.document,
                        documentID: selectedNoteURL.standardizedFileURL.path,
                        isEditing: isEditing,
                        isSplit: isSplitView,
                        colors: themeManager.colors,
                        fontScale: fontScale,
                        formatting: formatting,
                        search: noteSearch,
                        onUserEdit: { [model] in model.scheduleSaveCurrentNote() }
                    )
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "note.text")
                            .font(.largeTitle)
                            .foregroundColor(themeManager.colors.tabText)
                        Text(model.notes.isEmpty
                             ? "No notes yet"
                             : "Select a note or create a new one")
                            .foregroundColor(themeManager.colors.tabText)
                        Button("New Note", action: model.createNote)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity)
            .background(themeManager.colors.editorBackground)

            NoteStatusBar(
                statistics: model.document.statistics,
                textColor: themeManager.colors.tabText,
                backgroundColor: themeManager.colors.tabBackground
            )
        }
        .background(themeManager.colors.editorBackground)
    }

    private func handleFindRequest() {
        guard findState.isPresented else { return }
        guard model.selectedNoteURL.map(NoteFileType.isSupported) == true else {
            findState.isPresented = false
            return
        }
        noteSearch.present()
    }

    private func closeNoteSearch() {
        noteSearch.close()
        findState.isPresented = false
    }

    /// Opens a note. With `focusEditor`, keyboard focus moves to its text afterwards;
    /// otherwise focus stays where it is (e.g. in the sidebar for arrow-key browsing).
    private func openNote(_ url: URL, focusEditor: Bool = false) {
        let documentID = url.standardizedFileURL.path
        guard model.selectedNoteURL != url else {
            if focusEditor {
                formatting.requestFocus(for: documentID)
            }
            return
        }
        // Commit marked (IME) text in the note editor before switching. Other
        // first responders, such as the sidebar list, keep focus.
        if let keyWindow = NSApp.keyWindow,
           let textView = keyWindow.firstResponder as? NSTextView,
           !textView.isFieldEditor {
            keyWindow.endEditing(for: nil)
            keyWindow.makeFirstResponder(nil)
        }
        guard model.saveCurrentNote(), model.selectNote(url) else { return }
        if !openNoteURLs.contains(where: { $0 == url }) {
            openNoteURLs.append(url)
        }
        if focusEditor {
            formatting.requestFocus(for: documentID)
        }
    }

    private func closeNoteTab(_ url: URL) {
        guard let index = openNoteURLs.firstIndex(of: url) else { return }
        let wasSelected = model.selectedNoteURL == url
        if wasSelected {
            if openNoteURLs.count == 1 {
                guard model.saveCurrentNote() else { return }
                model.clearSelection()
            } else {
                let nextIndex = index < openNoteURLs.count - 1 ? index + 1 : index - 1
                let nextURL = openNoteURLs[nextIndex]
                openNote(nextURL, focusEditor: true)
                guard model.selectedNoteURL == nextURL else { return }
            }
        }
        openNoteURLs.remove(at: index)
    }

    // Rename, delete and link insertion actions.
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
        guard !destination.isEmpty,
              let targetDocumentID = linkTargetDocumentID,
              model.selectedNoteURL?.standardizedFileURL.path == targetDocumentID else {
            isLinkPresented = false
            linkTargetDocumentID = nil
            return
        }
        formatting.perform(.link(url: destination), for: targetDocumentID)
        isLinkPresented = false
        linkTargetDocumentID = nil
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
