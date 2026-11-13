//  LightNote+
//
//  NotesWorkspaceModel.swift
//  Notes folder, organization metadata, selection and saving.
//
// Created by mnrds
//

import SwiftUI
import Combine
import AppKit

// Note hierarchy, heading, and organization data.
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

// Persisted organization data for headings, note assignments, and note order.
struct NotesSidebarMetadata: Codable {
    var headings: [NoteHeading]
    var noteAssignments: [String: UUID]
    var noteOrder: [String]?
}

struct NotesOrganizationExport: Codable {
    let version: Int
    /// Notes folder relative to the user's home ("~/…"); nil when outside it.
    /// Never an absolute path, so exports do not reveal the full folder layout.
    var notesFolder: String?
    let headings: [NoteHeading]
    let noteAssignments: [String: UUID]
    let noteOrder: [String]?
}

// File types shown and edited as notes.
nonisolated enum NoteFileType {
    static let extensions: Set<String> = ["md", "markdown", "txt"]
    static let defaultExtension = "md"

    static func isSupported(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }
}

enum NoteFileConflictError: LocalizedError {
    case modifiedExternally
    case modificationDateUnavailable

    var errorDescription: String? {
        switch self {
        case .modifiedExternally:
            return "The note changed outside LightNotePlus. Reload it before saving to avoid losing those changes."
        case .modificationDateUnavailable:
            return "The note's modification date could not be determined, so it was not saved."
        }
    }
}

enum NoteURLChange {
    case renamed(from: URL, to: URL)
    case deleted(URL)
}

enum NotesOrganizationTransferError: LocalizedError {
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
    @Published private(set) var noteOrder: [String] = []
    @Published private(set) var selectedNoteURL: URL?
    @Published var errorMessage: String?
    /// True while the open note has edits not yet written to disk. Only
    /// published on transitions, so it does not redraw views on every keystroke.
    @Published private(set) var hasUnsavedChanges = false
    private var hasLoadedWorkspace = false
    /// The open note's text. Kept in its own object so typing does not publish
    /// changes from the workspace model.
    let document = NoteDocument()
    let contentIndex = NoteContentIndex()
    let noteURLChanges = PassthroughSubject<NoteURLChange, Never>()

    /// Text of the selected note, including edits the preview has not yet
    /// converted back to Markdown. Setting it replaces the document text.
    var content: String {
        get {
            document.flushPendingEdits()
            return document.text
        }
        set {
            document.replace(with: newValue)
        }
    }
    private var loadedMetadataRootPath: String?
    private var selectedNoteModificationDate: Date?
    private var lastSavedContent: String? {
        didSet { updateUnsavedChanges() }
    }
    private var hasSecurityScopedAccess = false
    private let noteSaveQueue = DispatchQueue(label: "com.lightnoteplus.notes.save", qos: .utility)
    private var pendingSaveTask: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?

    @Published private(set) var rootURL: URL

    private static let defaultRootURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents", isDirectory: true)
        .appendingPathComponent("LightNotePlus", isDirectory: true)
        .appendingPathComponent("Notes", isDirectory: true)
    private static let notesFolderBookmarkKey = "notes.folder.bookmark"

    // Restores the previously selected notes folder, or uses the default folder.
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
            } catch {
                UserDefaults.standard.removeObject(forKey: Self.notesFolderBookmarkKey)
                rootURL = Self.defaultRootURL
                errorMessage = "Unable to restore the saved Notes folder: \(error.localizedDescription)"
            }
        } else {
            rootURL = Self.defaultRootURL
        }

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveCurrentNote()
            }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshAfterActivation()
            }
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    private var sidebarMetadataKey: String {
        "notes.sidebar.metadata.\(rootURL.standardizedFileURL.path)"
    }

    private var sidebarMetadataURL: URL {
        rootURL.appendingPathComponent(".lightnote.json")
    }

    // Changes the active notes folder and its security-scoped bookmark.
    func setNotesFolder(_ url: URL) throws {
        errorMessage = nil
        guard saveCurrentNote() else {
            throw NSError(
                domain: "NotesWorkspaceModel",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: errorMessage ?? "Unable to save the current note."]
            )
        }
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
        contentIndex.removeAll()
        loadedMetadataRootPath = nil
        headings = []
        noteAssignments = [:]
        noteOrder = []
        notes = []
        selectedNoteURL = nil
        content = ""
        selectedNoteModificationDate = nil
        lastSavedContent = nil
        loadWorkspace()
    }

    func resetNotesFolder() throws {
        errorMessage = nil
        guard saveCurrentNote() else {
            throw NSError(
                domain: "NotesWorkspaceModel",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: errorMessage ?? "Unable to save the current note."]
            )
        }
        if hasSecurityScopedAccess {
            rootURL.stopAccessingSecurityScopedResource()
        }
        UserDefaults.standard.removeObject(forKey: Self.notesFolderBookmarkKey)
        rootURL = Self.defaultRootURL
        hasSecurityScopedAccess = false
        contentIndex.removeAll()
        loadedMetadataRootPath = nil
        headings = []
        noteAssignments = [:]
        noteOrder = []
        notes = []
        selectedNoteURL = nil
        content = ""
        selectedNoteModificationDate = nil
        lastSavedContent = nil
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

    /// Loads the workspace once; later calls (another window, view re-appearing) do nothing.
    func loadWorkspaceIfNeeded() {
        guard !hasLoadedWorkspace else { return }
        loadWorkspace()
    }

    // Loads organization metadata and notes, then restores the selected note.
    func loadWorkspace() {
        hasLoadedWorkspace = true
        guard selectedNoteURL == nil || saveCurrentNote() else { return }
        do {
            var isDirectory: ObjCBool = false
            let folderExists = FileManager.default.fileExists(
                atPath: rootURL.path,
                isDirectory: &isDirectory
            )
            if folderExists {
                guard isDirectory.boolValue else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
            } else {
                guard UserDefaults.standard.data(forKey: Self.notesFolderBookmarkKey) == nil else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
                try FileManager.default.createDirectory(
                    at: rootURL,
                    withIntermediateDirectories: true
                )
            }
            loadSidebarMetadata()
            try refreshNotes()
            if let selectedNoteURL,
               FileManager.default.fileExists(atPath: selectedNoteURL.path) {
                selectNote(selectedNoteURL)
            } else if let firstNote = firstNoteURL(in: notes) {
                selectNote(firstNote)
            } else {
                selectedNoteURL = nil
                content = ""
                selectedNoteModificationDate = nil
                lastSavedContent = nil
            }
        } catch {
            errorMessage = "Unable to load the notes folder: \(error.localizedDescription)"
        }
    }

    func notes(inHeading headingID: UUID?) -> [NoteTreeItem] {
        filteredTree(notes, headingID: headingID)
    }

    /// Splits the note tree by heading in a single pass (nil = Unsorted).
    /// Equivalent to calling notes(inHeading:) for every heading.
    func notesGroupedByHeading() -> [UUID?: [NoteTreeItem]] {
        groupedTree(notes)
    }

    private func groupedTree(_ items: [NoteTreeItem]) -> [UUID?: [NoteTreeItem]] {
        var groups: [UUID?: [NoteTreeItem]] = [:]
        for item in items {
            if item.isDirectory {
                for (headingID, children) in groupedTree(item.children ?? []) {
                    groups[headingID, default: []].append(
                        NoteTreeItem(
                            url: item.url,
                            name: item.name,
                            isDirectory: true,
                            children: children
                        )
                    )
                }
            } else {
                groups[noteAssignments[noteKey(for: item.url)], default: []].append(item)
            }
        }
        return groups
    }

    // Exports and imports headings, note assignments, and their saved order.
    func exportOrganization() throws -> Data {
        // All paths are written relative to the Notes folder, and the folder
        // itself relative to the home folder, so no absolute path is exported.
        var relativeAssignments: [String: UUID] = [:]
        for (path, headingID) in noteAssignments {
            relativeAssignments[try relativeNotePath(from: path)] = headingID
        }
        let relativeNoteOrder = try noteOrder.map(relativeNotePath(from:))

        let export = NotesOrganizationExport(
            version: 1,
            notesFolder: Self.homeRelativePath(for: rootURL),
            headings: headings,
            noteAssignments: relativeAssignments,
            noteOrder: relativeNoteOrder
        )
        return try JSONEncoder().encode(export)
    }

    /// The Notes folder saved in an export, if it differs from the current one.
    func exportedNotesFolderMismatch(in data: Data) -> String? {
        guard let organization = try? JSONDecoder().decode(NotesOrganizationExport.self, from: data),
              let savedFolder = organization.notesFolder,
              savedFolder != Self.homeRelativePath(for: rootURL) else {
            return nil
        }
        return savedFolder
    }

    /// The path as "~/…" relative to the user's real home folder (not the
    /// sandbox container), or nil when the folder is outside it.
    private static func homeRelativePath(for url: URL) -> String? {
        guard let passwd = getpwuid(getuid()), let homeDirectory = passwd.pointee.pw_dir else {
            return nil
        }
        let homePath = URL(fileURLWithPath: String(cString: homeDirectory)).standardizedFileURL.path
        let homePrefix = homePath.hasSuffix("/") ? homePath : homePath + "/"
        let path = url.standardizedFileURL.path
        if path == homePath {
            return "~"
        }
        guard path.hasPrefix(homePrefix) else { return nil }
        return "~/" + path.dropFirst(homePrefix.count)
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
                  NoteFileType.isSupported(noteURL) else {
                throw NotesOrganizationTransferError.invalidAssignmentPath
            }
            importedAssignments[noteKey(for: noteURL)] = headingID
        }
        var importedNoteOrder: [String] = []
        for relativePath in organization.noteOrder ?? [] {
            guard !relativePath.isEmpty,
                  !relativePath.hasPrefix("/"),
                  !relativePath.split(separator: "/").contains("..") else {
                throw NotesOrganizationTransferError.invalidAssignmentPath
            }
            let noteURL = URL(fileURLWithPath: relativePath, relativeTo: rootURL)
                .standardizedFileURL
            let rootPath = rootURL.standardizedFileURL.path
            let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            let path = noteKey(for: noteURL)
            guard noteURL.path.hasPrefix(rootPrefix),
                  NoteFileType.isSupported(noteURL),
                  !importedNoteOrder.contains(path) else {
                throw NotesOrganizationTransferError.invalidAssignmentPath
            }
            importedNoteOrder.append(path)
        }

        let previousHeadings = headings
        let previousAssignments = noteAssignments
        let previousNoteOrder = noteOrder
        headings = organization.headings
        noteAssignments = importedAssignments
        let currentNotePaths = allNoteURLs(in: notes).map(noteKey(for:))
        let currentNotePathSet = Set(currentNotePaths)
        noteOrder = importedNoteOrder.filter(currentNotePathSet.contains)
        for path in currentNotePaths where !noteOrder.contains(path) {
            noteOrder.append(path)
        }
        notes = sortTreeItems(notes)
        do {
            try saveSidebarMetadata()
        } catch {
            headings = previousHeadings
            noteAssignments = previousAssignments
            noteOrder = previousNoteOrder
            notes = sortTreeItems(notes)
            throw error
        }
    }

    // Creates, renames, deletes, and reorders sidebar headings.
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

    // Reorders notes among the siblings in their current heading or folder.
    func canMoveNote(_ url: URL, by offset: Int) -> Bool {
        guard let siblings = noteSiblings(containing: url),
              let index = siblings.firstIndex(of: noteKey(for: url)) else {
            return false
        }
        return siblings.indices.contains(index + offset)
    }

    func moveNote(_ url: URL, by offset: Int) {
        let key = noteKey(for: url)
        guard let siblings = noteSiblings(containing: url),
              let index = siblings.firstIndex(of: key) else {
            return
        }
        let destination = index + offset
        guard siblings.indices.contains(destination) else { return }

        var updatedOrder = noteOrder
        for path in allNoteURLs(in: notes).map(noteKey(for:)) where !updatedOrder.contains(path) {
            updatedOrder.append(path)
        }
        guard let sourceOrderIndex = updatedOrder.firstIndex(of: key),
              let destinationOrderIndex = updatedOrder.firstIndex(of: siblings[destination]) else {
            return
        }
        updatedOrder.swapAt(sourceOrderIndex, destinationOrderIndex)

        let previousOrder = noteOrder
        noteOrder = updatedOrder
        notes = sortTreeItems(notes)
        do {
            try saveSidebarMetadata()
        } catch {
            noteOrder = previousOrder
            notes = sortTreeItems(notes)
            errorMessage = "Unable to save the note order: \(error.localizedDescription)"
        }
    }

    // Assigns a note to a heading or returns it to the unsorted list.
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

    // Reads, creates, opens, saves, renames, and deletes note files.
    func noteContainsText(at url: URL) -> Bool? {
        guard allNoteURLs(in: notes).contains(where: { noteKey(for: $0) == noteKey(for: url) }) else {
            errorMessage = "The selected note is not in the Notes folder."
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            let hasUnsavedSelectedContent =
                selectedNoteURL?.standardizedFileURL == url.standardizedFileURL && !content.isEmpty
            return !data.isEmpty || hasUnsavedSelectedContent
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
        let isSelectedNote = selectedNoteURL.map { noteKey(for: $0) == key } ?? false

        do {
            if isSelectedNote {
                pendingSaveTask?.cancel()
                pendingSaveTask = nil
                noteSaveQueue.sync {}
            }
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            contentIndex.remove(url)
            noteURLChanges.send(.deleted(url))
            noteAssignments.removeValue(forKey: key)
            noteOrder.removeAll { $0 == key }
            if isSelectedNote {
                selectedNoteURL = nil
                content = ""
                selectedNoteModificationDate = nil
                lastSavedContent = nil
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
        guard saveCurrentNote() else { return }
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

    @discardableResult
    func selectNote(_ url: URL) -> Bool {
        do {
            noteSaveQueue.sync {}
            let modificationDateBeforeRead = try modificationDate(of: url)
            let data = try Data(contentsOf: url)
            guard let noteContent = NoteTextDecoder.decode(data) else {
                errorMessage = "The note uses an unsupported text encoding."
                return false
            }
            let modificationDateAfterRead = try modificationDate(of: url)
            guard modificationDateBeforeRead == modificationDateAfterRead else {
                throw NoteFileConflictError.modifiedExternally
            }

            selectedNoteURL = url
            content = noteContent
            selectedNoteModificationDate = modificationDateAfterRead
            lastSavedContent = noteContent
            contentIndex.store(noteContent, for: url, modificationDate: modificationDateAfterRead)
            return true
        } catch {
            errorMessage = "Unable to open the note: \(error.localizedDescription)"
            return false
        }
    }

    func clearSelection() {
        selectedNoteURL = nil
        content = ""
        selectedNoteModificationDate = nil
        lastSavedContent = nil
    }

    @discardableResult
    func saveCurrentNote() -> Bool {
        // Flush first: a flushed preview edit schedules a save, cancelled below.
        document.flushPendingEdits()
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        guard let selectedNoteURL else { return true }

        let snapshot = content
        return persist(snapshot, to: selectedNoteURL)
    }

    func scheduleSaveCurrentNote() {
        if selectedNoteURL != nil, !hasUnsavedChanges {
            hasUnsavedChanges = true
        }
        pendingSaveTask?.cancel()
        guard let selectedNoteURL else {
            pendingSaveTask = nil
            return
        }

        let snapshot = content
        pendingSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(400))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.selectedNoteURL?.standardizedFileURL == selectedNoteURL.standardizedFileURL else {
                return
            }
            self.enqueueSave(snapshot, to: selectedNoteURL)
        }
    }

    private func enqueueSave(_ snapshot: String, to url: URL) {
        guard selectedNoteURL?.standardizedFileURL == url.standardizedFileURL else { return }
        _ = persist(snapshot, to: url)
    }

    private func updateUnsavedChanges() {
        // Reads document.text directly: flushing here could re-enter a save.
        let isUnsaved = selectedNoteURL != nil && document.text != lastSavedContent
        if hasUnsavedChanges != isUnsaved {
            hasUnsavedChanges = isUnsaved
        }
    }

    private func persist(_ snapshot: String, to url: URL) -> Bool {
        if snapshot == lastSavedContent {
            updateUnsavedChanges()
            return true
        }
        guard let expectedDate = selectedNoteModificationDate else {
            errorMessage = "Unable to save the note: \(NoteFileConflictError.modificationDateUnavailable.localizedDescription)"
            return false
        }

        do {
            let newDate = try noteSaveQueue.sync {
                let currentDate = try modificationDate(of: url)
                guard currentDate == expectedDate else {
                    throw NoteFileConflictError.modifiedExternally
                }
                try snapshot.write(to: url, atomically: true, encoding: .utf8)
                return try modificationDate(of: url)
            }
            selectedNoteModificationDate = newDate
            lastSavedContent = snapshot
            contentIndex.store(snapshot, for: url, modificationDate: newDate)
            return true
        } catch {
            errorMessage = "Unable to save the note: \(error.localizedDescription)"
            return false
        }
    }

    private func modificationDate(of url: URL) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let date = attributes[.modificationDate] as? Date else {
            throw NoteFileConflictError.modificationDateUnavailable
        }
        return date
    }

    private func refreshAfterActivation() {
        guard loadedMetadataRootPath == rootURL.standardizedFileURL.path else { return }
        do {
            try refreshNotes()
            guard let selectedNoteURL else { return }

            guard FileManager.default.fileExists(atPath: selectedNoteURL.path) else {
                if content == lastSavedContent {
                    pendingSaveTask?.cancel()
                    pendingSaveTask = nil
                    self.selectedNoteURL = nil
                    content = ""
                    selectedNoteModificationDate = nil
                    lastSavedContent = nil
                    if let firstNote = firstNoteURL(in: notes) {
                        selectNote(firstNote)
                    }
                } else {
                    pendingSaveTask?.cancel()
                    pendingSaveTask = nil
                    errorMessage = "The selected note was removed outside LightNotePlus. Your unsaved edits were kept."
                }
                return
            }

            let currentDate = try modificationDate(of: selectedNoteURL)
            guard currentDate != selectedNoteModificationDate else { return }
            pendingSaveTask?.cancel()
            pendingSaveTask = nil
            guard content == lastSavedContent else {
                errorMessage = NoteFileConflictError.modifiedExternally.localizedDescription
                return
            }
            _ = selectNote(selectedNoteURL)
        } catch {
            errorMessage = "Unable to refresh notes: \(error.localizedDescription)"
        }
    }

    func renameNote(at url: URL, to proposedName: String) {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep the note's file type; a typed supported extension is ignored.
        let typedExtension = (name as NSString).pathExtension.lowercased()
        let noteName = NoteFileType.extensions.contains(typedExtension)
            ? (name as NSString).deletingPathExtension
            : name
        let fileExtension = url.pathExtension.isEmpty ? NoteFileType.defaultExtension : url.pathExtension

        guard !noteName.isEmpty,
              noteName != ".",
              noteName != "..",
              !noteName.hasPrefix("."),
              !noteName.contains("/") else {
            errorMessage = "Enter a valid note name."
            return
        }

        let newURL = url
            .deletingLastPathComponent()
            .appendingPathComponent(noteName)
            .appendingPathExtension(fileExtension)
        let sourcePath = url.standardizedFileURL.path
        let destinationPath = newURL.standardizedFileURL.path
        guard sourcePath != destinationPath else { return }

        let isCaseOnlyRename =
            url.deletingLastPathComponent().standardizedFileURL.path
                == newURL.deletingLastPathComponent().standardizedFileURL.path
            && url.lastPathComponent.caseInsensitiveCompare(newURL.lastPathComponent) == .orderedSame
        let destinationExists = FileManager.default.fileExists(atPath: newURL.path)
        let destinationIsSource = isCaseOnlyRename
            && destinationExists
            && refersToSameFile(url, newURL)
        guard !destinationExists || destinationIsSource else {
            errorMessage = "A note with that name already exists."
            return
        }
        if selectedNoteURL.map({ noteKey(for: $0) == noteKey(for: url) }) == true,
           !saveCurrentNote() {
            return
        }

        do {
            if isCaseOnlyRename {
                try moveForCaseOnlyRename(from: url, to: newURL)
            } else {
                try FileManager.default.moveItem(at: url, to: newURL)
            }
            contentIndex.remove(url)
            noteURLChanges.send(.renamed(from: url, to: newURL))
            if selectedNoteURL.map({ noteKey(for: $0) == noteKey(for: url) }) == true {
                selectedNoteURL = newURL
            }
            if let orderIndex = noteOrder.firstIndex(of: noteKey(for: url)) {
                noteOrder[orderIndex] = noteKey(for: newURL)
            }
            if let assignment = noteAssignments.removeValue(forKey: noteKey(for: url)) {
                noteAssignments[noteKey(for: newURL)] = assignment
            }
            try saveSidebarMetadata()
            try refreshNotes()
        } catch {
            errorMessage = "Unable to rename the note: \(error.localizedDescription)"
        }
    }

    private func refersToSameFile(_ firstURL: URL, _ secondURL: URL) -> Bool {
        let resourceKeys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let firstIdentifier = try? firstURL.resourceValues(forKeys: resourceKeys).fileResourceIdentifier,
              let secondIdentifier = try? secondURL.resourceValues(forKeys: resourceKeys).fileResourceIdentifier else {
            return false
        }
        return (firstIdentifier as? NSObject)?.isEqual(secondIdentifier) == true
    }

    private func moveForCaseOnlyRename(from sourceURL: URL, to destinationURL: URL) throws {
        let temporaryURL = sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent(".rename-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: sourceURL, to: temporaryURL)
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        } catch let renameError {
            do {
                try FileManager.default.moveItem(at: temporaryURL, to: sourceURL)
            } catch let restoreError {
                throw NSError(
                    domain: "NotesWorkspaceModel",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Unable to rename the note: \(renameError.localizedDescription). "
                            + "The original could not be restored: \(restoreError.localizedDescription). "
                            + "The note is at \(temporaryURL.path)."
                    ]
                )
            }
            throw renameError
        }
    }

    // Refreshes the filesystem tree and reconciles saved organization metadata.
    private func refreshNotes() throws {
        var itemErrors: [String] = []
        let refreshedNotes = try treeItems(in: rootURL, itemErrors: &itemErrors)
        let refreshedURLs = allNoteURLs(in: refreshedNotes)
        let validKeys = Set(refreshedURLs.map(noteKey(for:)))
        let validHeadingIDs = Set(headings.map(\.id))
        let previousAssignments = noteAssignments
        let previousNoteOrder = noteOrder
        if itemErrors.isEmpty {
            noteAssignments = noteAssignments.filter {
                validKeys.contains($0.key) && validHeadingIDs.contains($0.value)
            }
            noteOrder = noteOrder.filter(validKeys.contains)
        } else {
            noteAssignments = noteAssignments.filter { validHeadingIDs.contains($0.value) }
        }
        var orderedKeys = Set(noteOrder)
        var appendedKeys: [String] = []
        for url in refreshedURLs {
            let key = noteKey(for: url)
            if orderedKeys.insert(key).inserted {
                appendedKeys.append(key)
            }
        }
        if !appendedKeys.isEmpty {
            noteOrder.append(contentsOf: appendedKeys)
        }
        notes = sortTreeItems(refreshedNotes)
        if itemErrors.isEmpty,
           (noteAssignments != previousAssignments || noteOrder != previousNoteOrder),
           loadedMetadataRootPath == rootURL.standardizedFileURL.path {
            try saveSidebarMetadata()
        }
        if !itemErrors.isEmpty {
            errorMessage = "Some notes could not be listed:\n" + itemErrors.joined(separator: "\n")
        }
    }

    private func loadSidebarMetadata() {
        let rootPath = rootURL.standardizedFileURL.path
        guard loadedMetadataRootPath != rootPath else { return }
        headings = []
        noteAssignments = [:]
        noteOrder = []

        do {
            let metadata: NotesSidebarMetadata
            let isLegacyMetadata: Bool
            if FileManager.default.fileExists(atPath: sidebarMetadataURL.path) {
                let data = try Data(contentsOf: sidebarMetadataURL)
                metadata = try JSONDecoder().decode(NotesSidebarMetadata.self, from: data)
                isLegacyMetadata = false
            } else if let data = UserDefaults.standard.data(forKey: sidebarMetadataKey) {
                metadata = try JSONDecoder().decode(NotesSidebarMetadata.self, from: data)
                isLegacyMetadata = true
            } else {
                loadedMetadataRootPath = rootPath
                return
            }

            headings = metadata.headings
            if isLegacyMetadata {
                for (absolutePath, headingID) in metadata.noteAssignments {
                    let relativePath = try relativeNotePath(from: absolutePath)
                    noteAssignments[try absoluteNotePath(for: relativePath)] = headingID
                }
                noteOrder = try (metadata.noteOrder ?? []).map {
                    try absoluteNotePath(for: relativeNotePath(from: $0))
                }
                loadedMetadataRootPath = rootPath
                try saveSidebarMetadata()
                UserDefaults.standard.removeObject(forKey: sidebarMetadataKey)
            } else {
                for (relativePath, headingID) in metadata.noteAssignments {
                    noteAssignments[try absoluteNotePath(for: relativePath)] = headingID
                }
                noteOrder = try (metadata.noteOrder ?? []).map(absoluteNotePath(for:))
                loadedMetadataRootPath = rootPath
                UserDefaults.standard.removeObject(forKey: sidebarMetadataKey)
            }
        } catch {
            loadedMetadataRootPath = nil
            headings = []
            noteAssignments = [:]
            noteOrder = []
            errorMessage = "Unable to load note organization: \(error.localizedDescription)"
        }
    }

    private func saveSidebarMetadata() throws {
        guard loadedMetadataRootPath == rootURL.standardizedFileURL.path else {
            throw NSError(
                domain: "NotesWorkspaceModel",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Unable to save note organization because it could not be loaded."
                ]
            )
        }

        var relativeAssignments: [String: UUID] = [:]
        for (absolutePath, headingID) in noteAssignments {
            relativeAssignments[try relativeNotePath(from: absolutePath)] = headingID
        }
        let relativeNoteOrder = try noteOrder.map(relativeNotePath(from:))
        let metadata = NotesSidebarMetadata(
            headings: headings,
            noteAssignments: relativeAssignments,
            noteOrder: relativeNoteOrder
        )
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: sidebarMetadataURL, options: .atomic)
    }

    // Helpers for note paths, ordering, and the filesystem tree.
    private func noteKey(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func relativeNotePath(from absolutePath: String) throws -> String {
        let path = URL(fileURLWithPath: absolutePath).standardizedFileURL.path
        let rootPath = rootURL.standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(rootPrefix) else {
            throw NotesOrganizationTransferError.invalidAssignmentPath
        }
        let relativePath = String(path.dropFirst(rootPrefix.count))
        guard isValidRelativeNotePath(relativePath) else {
            throw NotesOrganizationTransferError.invalidAssignmentPath
        }
        return relativePath
    }

    private func absoluteNotePath(for relativePath: String) throws -> String {
        guard isValidRelativeNotePath(relativePath) else {
            throw NotesOrganizationTransferError.invalidAssignmentPath
        }
        let url = URL(fileURLWithPath: relativePath, relativeTo: rootURL).standardizedFileURL
        let rootPath = rootURL.standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard url.path.hasPrefix(rootPrefix) else {
            throw NotesOrganizationTransferError.invalidAssignmentPath
        }
        return noteKey(for: url)
    }

    private func isValidRelativeNotePath(_ path: String) -> Bool {
        !path.isEmpty
            && !(path as NSString).isAbsolutePath
            && !path.split(separator: "/").contains("..")
            && NoteFileType.isSupported(URL(fileURLWithPath: path))
    }

    private func noteSiblings(containing url: URL) -> [String]? {
        let headingID = noteAssignments[noteKey(for: url)]
        return noteSiblings(containing: noteKey(for: url), in: filteredTree(notes, headingID: headingID))
    }

    private func noteSiblings(containing path: String, in items: [NoteTreeItem]) -> [String]? {
        let notePaths = items.filter { !$0.isDirectory }.map { noteKey(for: $0.url) }
        if notePaths.contains(path) {
            return notePaths
        }
        for directory in items where directory.isDirectory {
            if let siblings = noteSiblings(containing: path, in: directory.children ?? []) {
                return siblings
            }
        }
        return nil
    }

    private func sortTreeItems(_ items: [NoteTreeItem]) -> [NoteTreeItem] {
        // Position lookup table built once; the first occurrence wins, matching firstIndex(of:).
        var orderIndex: [String: Int] = [:]
        orderIndex.reserveCapacity(noteOrder.count)
        for (index, key) in noteOrder.enumerated() where orderIndex[key] == nil {
            orderIndex[key] = index
        }
        return sortTreeItems(items, orderIndex: orderIndex)
    }

    private func sortTreeItems(
        _ items: [NoteTreeItem],
        orderIndex: [String: Int]
    ) -> [NoteTreeItem] {
        // Resolve each item's position once instead of inside the comparator.
        items.map { item -> (item: NoteTreeItem, order: Int?) in
            guard item.isDirectory else {
                return (item, orderIndex[noteKey(for: item.url)])
            }
            let sortedDirectory = NoteTreeItem(
                url: item.url,
                name: item.name,
                isDirectory: true,
                children: sortTreeItems(item.children ?? [], orderIndex: orderIndex)
            )
            return (sortedDirectory, nil)
        }.sorted { lhs, rhs in
            if lhs.item.isDirectory != rhs.item.isDirectory {
                return lhs.item.isDirectory
            }
            if let leftIndex = lhs.order, let rightIndex = rhs.order, leftIndex != rightIndex {
                return leftIndex < rightIndex
            }
            return lhs.item.name.localizedStandardCompare(rhs.item.name) == .orderedAscending
        }.map(\.item)
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

    private func treeItems(in directory: URL, itemErrors: inout [String]) throws -> [NoteTreeItem] {
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var items: [NoteTreeItem] = []

        for url in fileURLs {
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            } catch {
                itemErrors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                continue
            }
            guard values.isSymbolicLink != true else { continue }

            if values.isDirectory == true {
                let children: [NoteTreeItem]
                do {
                    children = try treeItems(in: url, itemErrors: &itemErrors)
                } catch {
                    itemErrors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    continue
                }
                items.append(
                    NoteTreeItem(
                        url: url,
                        name: url.lastPathComponent,
                        isDirectory: true,
                        children: children
                    )
                )
            } else if NoteFileType.isSupported(url) {
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
