//  LightNote+
//
//  NoteDocument.swift
//  Open note text, word statistics and the cached search index.
//
// Created by mnrds
//

import Foundation
import Combine

// Word and character counts. Markdown syntax (heading/list/quote markers,
// emphasis, checkboxes, link destinations and HTML tags) is not counted as words.
nonisolated struct NoteTextStatistics: Sendable, Equatable {
    let words: Int
    let characters: Int

    static let empty = NoteTextStatistics(words: 0, characters: 0)

    private static let linkDestination = try! NSRegularExpression(
        pattern: #"\]\([^)\n]*\)"#
    )
    private static let htmlTag = try! NSRegularExpression(
        pattern: #"</?[A-Za-z][^>\n]*>"#
    )
    private static let checkbox = try! NSRegularExpression(
        pattern: #"^(\s*(?:[-*+]|\d+[.)])\s+)\[[ xX]\]"#,
        options: [.anchorsMatchLines]
    )

    init(words: Int, characters: Int) {
        self.words = words
        self.characters = characters
    }

    init(markdown: String) {
        characters = markdown.count
        words = Self.countWords(in: markdown)
    }

    private static func countWords(in markdown: String) -> Int {
        var text = markdown
        if text.contains("](") {
            text = replacing(linkDestination, in: text, with: "]")
        }
        if text.contains("<") {
            text = replacing(htmlTag, in: text, with: " ")
        }
        if text.contains("[") {
            text = replacing(checkbox, in: text, with: "$1")
        }
        // A token counts as a word only if it contains a letter or digit, so
        // "#", "-", ">", "---", "**" and "|" are ignored while "**bold**" counts once.
        return text
            .split(whereSeparator: \.isWhitespace)
            .reduce(0) { count, token in
                token.contains(where: { $0.isLetter || $0.isNumber }) ? count + 1 : count
            }
    }

    private static func replacing(
        _ expression: NSRegularExpression,
        in text: String,
        with template: String
    ) -> String {
        expression.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: template
        )
    }
}

// Publishes debounced statistics so only the status bar redraws while typing.
@MainActor
final class NoteTextStatisticsModel: ObservableObject {
    @Published private(set) var statistics = NoteTextStatistics.empty
    private var updateTask: Task<Void, Never>?

    func update(for text: String, immediately: Bool = false) {
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            if !immediately {
                do {
                    try await Task.sleep(for: .milliseconds(300))
                } catch {
                    return
                }
            }
            let statistics = await Task.detached(priority: .utility) {
                NoteTextStatistics(markdown: text)
            }.value
            guard !Task.isCancelled,
                  let self,
                  self.statistics != statistics else { return }
            self.statistics = statistics
        }
    }
}

// Text of the open note. It lives outside NotesWorkspaceModel so keystrokes do
// not invalidate the sidebar, tabs or anything else observing the workspace.
@MainActor
final class NoteDocument: ObservableObject {
    /// Incremented only when the text is replaced programmatically (open,
    /// reload, clear). User edits do not publish, so typing redraws nothing.
    @Published private(set) var revision = 0
    private(set) var text = ""
    let statistics = NoteTextStatisticsModel()
    /// Fires once user edits have paused.
    let editsSettled: AnyPublisher<Void, Never>
    private let edits: PassthroughSubject<Void, Never>
    private var pendingEditsHandler: (() -> Void)?

    init() {
        let edits = PassthroughSubject<Void, Never>()
        self.edits = edits
        editsSettled = edits
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .eraseToAnyPublisher()
    }

    func replace(with newText: String) {
        text = newText
        revision &+= 1
        statistics.update(for: newText, immediately: true)
    }

    enum EditSource {
        case editor
        case preview
    }

    /// Which view made each user edit. In the split layout the other view
    /// listens and refreshes itself, without any SwiftUI redraw.
    let userEdits = PassthroughSubject<EditSource, Never>()

    func applyUserEdit(_ newText: String, from source: EditSource) {
        text = newText
        statistics.update(for: newText)
        edits.send()
        userEdits.send(source)
    }

    /// Registered by an editor that buffers edits (the preview's Markdown
    /// conversion) so the workspace can force them in before reading the text.
    func setPendingEditsHandler(_ handler: (() -> Void)?) {
        pendingEditsHandler = handler
    }

    func flushPendingEdits() {
        pendingEditsHandler?()
    }
}

// Cache of case-folded note contents for sidebar search. Entries are validated
// against the file's modification date, so unchanged notes are read only once.
nonisolated final class NoteContentIndex: @unchecked Sendable {
    nonisolated struct SearchResult: Sendable {
        let matchingPaths: Set<String>
        let firstError: String?
    }

    nonisolated struct UnsavedNote: Sendable {
        let path: String
        let text: String
    }

    nonisolated private struct Entry {
        let modificationDate: Date?
        let foldedText: String
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive], locale: .current)
    }

    func store(_ text: String, for url: URL, modificationDate: Date?) {
        let entry = Entry(modificationDate: modificationDate, foldedText: Self.fold(text))
        let path = url.standardizedFileURL.path
        lock.withLock { entries[path] = entry }
    }

    func remove(_ url: URL) {
        let path = url.standardizedFileURL.path
        _ = lock.withLock { entries.removeValue(forKey: path) }
    }

    func removeAll() {
        lock.withLock { entries.removeAll() }
    }

    func search(_ query: String, in urls: [URL], unsavedNote: UnsavedNote?) -> SearchResult {
        let foldedQuery = Self.fold(query)
        var matchingPaths = Set<String>()
        var firstError: String?

        for url in urls {
            guard !Task.isCancelled else { break }
            let path = url.standardizedFileURL.path
            if Self.contains(foldedQuery, in: Self.fold(url.deletingPathExtension().lastPathComponent)) {
                matchingPaths.insert(path)
                continue
            }

            let foldedText: String
            if let unsavedNote, unsavedNote.path == path {
                foldedText = Self.fold(unsavedNote.text)
            } else {
                do {
                    foldedText = try cachedText(for: url, path: path)
                } catch {
                    firstError = firstError
                        ?? "Unable to search \(url.lastPathComponent): \(error.localizedDescription)"
                    continue
                }
            }
            if Self.contains(foldedQuery, in: foldedText) {
                matchingPaths.insert(path)
            }
        }
        return SearchResult(matchingPaths: matchingPaths, firstError: firstError)
    }

    private static func contains(_ foldedQuery: String, in foldedText: String) -> Bool {
        foldedText.range(of: foldedQuery, options: .literal) != nil
    }

    private func cachedText(for url: URL, path: String) throws -> String {
        let modificationDate = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if let modificationDate,
           let entry = lock.withLock({ entries[path] }),
           entry.modificationDate == modificationDate {
            return entry.foldedText
        }

        let data = try Data(contentsOf: url)
        guard let text = NoteTextDecoder.decode(data) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let foldedText = Self.fold(text)
        lock.withLock {
            entries[path] = Entry(modificationDate: modificationDate, foldedText: foldedText)
        }
        return foldedText
    }
}
