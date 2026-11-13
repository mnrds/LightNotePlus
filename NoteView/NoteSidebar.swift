//  LightNote+
//
//  NoteSidebar.swift
//  Notes sidebar: headings, note rows, search and drag and drop.
//
// Created by mnrds
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Sidebar note rows and their context-menu actions.
struct NoteTreeRow: View {
    let item: NoteTreeItem
    let isSelected: Bool
    let colors: ThemeColors

    private var rowContent: some View {
        HStack(spacing: 6) {
            Image(systemName: item.isDirectory ? "folder" : "doc.text")
                .foregroundColor(colors.tabText)
            Text(item.name)
                .lineLimit(1)
                .foregroundColor(colors.tabText)
        }
    }

    // Selection, double-click and the context menu are handled by the List
    // (NotesSidebar). Gestures here would swallow clicks and block selection.
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
        .listRowBackground(colors.tabBackground)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// Sidebar with headings, note rows and note search. It observes the workspace
// model only, so editing the open note does not redraw or re-filter it.
struct NotesSidebar: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @ObservedObject var model: NotesWorkspaceModel
    let separatorColor: Color
    let onOpenNote: (URL) -> Void
    let onFocusEditor: (URL) -> Void
    let onRenameNote: (URL) -> Void
    let onDeleteNote: (URL) -> Void
    let onNewHeading: () -> Void
    let onRenameHeading: (NoteHeading) -> Void

    @State private var targetedHeadingID: UUID?
    @State private var isUnsortedTargeted = false
    @State private var collapsedHeadingIDs = Set<UUID>()
    @State private var isSearchPresented = false
    @State private var searchText = ""
    @State private var searchResults: (query: String, notePaths: Set<String>)?
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var isSearchFieldFocused: Bool

    private struct HeadingSection: Identifiable {
        let heading: NoteHeading
        let notes: [NoteTreeItem]
        let hasNotes: Bool
        var id: UUID { heading.id }
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// List selection mirrors the open note; selecting a row (click or arrow
    /// keys) opens it while keyboard focus stays in the list.
    private var selection: Binding<URL?> {
        Binding(
            get: { model.selectedNoteURL },
            set: { url in
                guard let url, url != model.selectedNoteURL else { return }
                onOpenNote(url)
            }
        )
    }

    var body: some View {
        // Group the tree by heading once per render instead of re-filtering
        // the whole tree several times for every heading.
        let groups = model.notesGroupedByHeading()
        let query = normalizedSearchText
        let unsortedNotes = visibleNotes(groups[nil] ?? [], heading: nil, query: query)
        let headingSections = model.headings.compactMap { heading -> HeadingSection? in
            let allNotes = groups[heading.id] ?? []
            let titleMatches = !query.isEmpty && heading.title.localizedCaseInsensitiveContains(query)
            let notes = titleMatches ? allNotes : visibleNotes(allNotes, heading: heading, query: query)
            guard query.isEmpty || titleMatches || !notes.isEmpty else { return nil }
            return HeadingSection(heading: heading, notes: notes, hasNotes: !allNotes.isEmpty)
        }
        // Unsorted stays visible (as a drop target) while headings exist.
        let showsUnsorted = !unsortedNotes.isEmpty || (query.isEmpty && !model.headings.isEmpty)
        let isEmpty = unsortedNotes.isEmpty && headingSections.isEmpty

        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("Notes")
                    .font(.headline)
                    .foregroundColor(themeManager.colors.text)
                Spacer(minLength: 0)
                sidebarButton("doc.badge.plus", help: "New Note") {
                    model.createNote()
                }
                sidebarButton("folder.badge.plus", help: "New Heading", action: onNewHeading)
                sidebarButton(
                    isSearchPresented ? "xmark" : "magnifyingglass",
                    help: isSearchPresented ? "Close Search" : "Search Notes"
                ) {
                    isSearchPresented.toggle()
                    if isSearchPresented {
                        isSearchFieldFocused = true
                    } else {
                        searchText = ""
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            if isSearchPresented {
                TextField("Search notes", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isSearchFieldFocused)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .onExitCommand {
                        isSearchPresented = false
                        searchText = ""
                    }
            }

            Rectangle()
                .fill(separatorColor)
                .frame(height: 1)

            List(selection: selection) {
                if showsUnsorted {
                    Section {
                        noteRows(unsortedNotes)
                    } header: {
                        unsortedHeader
                    }
                }

                ForEach(headingSections) { section in
                    Section {
                        if !collapsedHeadingIDs.contains(section.heading.id) {
                            noteRows(section.notes)
                        }
                    } header: {
                        headingHeader(section.heading, hasNotes: section.hasNotes)
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
            // Delete moves the selected note to the Trash; Return opens it for editing.
            .onDeleteCommand {
                if let url = model.selectedNoteURL {
                    onDeleteNote(url)
                }
            }
            // Double-click renames; Return opens the note for typing.
            .contextMenu(forSelectionType: URL.self) { urls in
                if let url = urls.first {
                    noteMenu(for: url)
                }
            } primaryAction: { urls in
                guard let url = urls.first else { return }
                if NSApp.currentEvent?.type == .keyDown {
                    onFocusEditor(url)
                } else {
                    onRenameNote(url)
                }
            }
            .overlay {
                if isEmpty {
                    emptyState(query: query)
                }
            }
        }
        .frame(minWidth: 190, idealWidth: 250, maxWidth: 340)
        .background(themeManager.colors.tabBackground)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(separatorColor)
                .frame(width: 1)
        }
        .onChange(of: searchText) { _, query in
            updateSearchResults(for: query, in: model.notes, debounce: true, reportsErrors: true)
        }
        // Keep content matches current: re-run (from the cache) when the note
        // list changes or the open note's edits settle.
        .onReceive(model.$notes) { notes in
            guard !normalizedSearchText.isEmpty else { return }
            updateSearchResults(for: searchText, in: notes, debounce: false, reportsErrors: false)
        }
        .onReceive(model.document.editsSettled) { _ in
            guard !normalizedSearchText.isEmpty else { return }
            updateSearchResults(for: searchText, in: model.notes, debounce: false, reportsErrors: false)
        }
        .onDisappear {
            searchTask?.cancel()
        }
    }

    @ViewBuilder
    private func emptyState(query: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: query.isEmpty ? "note.text" : "magnifyingglass")
                .font(.title2)
            if query.isEmpty {
                Text("No Notes")
                    .font(.headline)
                Text("Create a note to get started.")
                    .font(.callout)
                Button("New Note", action: model.createNote)
                    .padding(.top, 4)
            } else {
                Text("No Results")
                    .font(.headline)
                Text("No notes contain “\(query)”.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
            }
        }
        .foregroundColor(themeManager.colors.tabText)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var unsortedHeader: some View {
        HStack {
            Text("Unsorted")
                .foregroundColor(themeManager.colors.tabText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(
            isUnsortedTargeted
                ? themeManager.colors.tabSelected.opacity(0.25)
                : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onDrop(
            of: [UTType.fileURL],
            isTargeted: $isUnsortedTargeted,
            perform: { handleNoteDrop($0, to: nil) }
        )
    }

    private func headingHeader(_ heading: NoteHeading, hasNotes: Bool) -> some View {
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

            if hasNotes {
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
                onRenameHeading(heading)
            }

            Button("Delete Heading", systemImage: "trash", role: .destructive) {
                model.deleteHeading(heading)
            }
        }
    }

    // Builds the note rows shown under a heading or Unsorted.
    private func noteRows(_ items: [NoteTreeItem]) -> some View {
        OutlineGroup(items, children: \.children) { item in
            let row = NoteTreeRow(
                item: item,
                isSelected: model.selectedNoteURL == item.url,
                colors: themeManager.colors
            )
            // Only notes are selectable; folders stay untagged.
            if item.isDirectory {
                row
            } else {
                row.tag(item.url)
            }
        }
    }

    // Context menu for a note row (right-click or Control-click).
    @ViewBuilder
    private func noteMenu(for url: URL) -> some View {
        let currentHeadingID = model.noteAssignments[url.standardizedFileURL.path]
        Button("Rename…", systemImage: "pencil") { onRenameNote(url) }
        Button("Delete", systemImage: "trash", role: .destructive) { onDeleteNote(url) }
        Divider()
        Button("Move Up", systemImage: "arrow.up") {
            model.moveNote(url, by: -1)
        }
        .disabled(!model.canMoveNote(url, by: -1))
        Button("Move Down", systemImage: "arrow.down") {
            model.moveNote(url, by: 1)
        }
        .disabled(!model.canMoveNote(url, by: 1))
        Divider()
        Menu("Move to") {
            Button {
                model.moveNote(url, to: nil)
            } label: {
                if currentHeadingID == nil {
                    Label("Unsorted", systemImage: "checkmark")
                } else {
                    Text("Unsorted")
                }
            }

            if !model.headings.isEmpty {
                Divider()
            }

            ForEach(model.headings) { heading in
                Button {
                    model.moveNote(url, to: heading.id)
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

    // Search filtering over the cached note-content index.
    private func visibleNotes(
        _ items: [NoteTreeItem],
        heading: NoteHeading?,
        query: String
    ) -> [NoteTreeItem] {
        guard !query.isEmpty else { return items }
        if let heading, heading.title.localizedCaseInsensitiveContains(query) {
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

    private func updateSearchResults(
        for proposedQuery: String,
        in notes: [NoteTreeItem],
        debounce: Bool,
        reportsErrors: Bool
    ) {
        searchTask?.cancel()
        let query = proposedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = nil
            return
        }

        let noteURLs = allNoteURLs(in: notes)
        let index = model.contentIndex
        // Search the open note's in-memory text so unsaved edits are matched too.
        let unsavedNote = model.selectedNoteURL.map {
            NoteContentIndex.UnsavedNote(
                path: $0.standardizedFileURL.path,
                text: model.document.text
            )
        }
        searchTask = Task { @MainActor in
            if debounce {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }

            let readTask = Task.detached(priority: .userInitiated) {
                index.search(query, in: noteURLs, unsavedNote: unsavedNote)
            }
            let result = await withTaskCancellationHandler {
                await readTask.value
            } onCancel: {
                readTask.cancel()
            }

            guard !Task.isCancelled,
                  normalizedSearchText == query else {
                return
            }
            if searchResults?.query != query || searchResults?.notePaths != result.matchingPaths {
                searchResults = (query, result.matchingPaths)
            }
            if reportsErrors, let error = result.firstError {
                model.errorMessage = error
            }
        }
    }

    private func allNoteURLs(in items: [NoteTreeItem]) -> [URL] {
        items.flatMap { item in
            item.isDirectory ? allNoteURLs(in: item.children ?? []) : [item.url]
        }
    }

    private func handleNoteDrop(_ providers: [NSItemProvider], to headingID: UUID?) -> Bool {
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
}
