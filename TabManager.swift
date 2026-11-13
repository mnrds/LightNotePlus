//
//  TabManager.swift
//  LightNote+
//
//  Created by mnrds
//

import SwiftUI
import Combine
import UniformTypeIdentifiers

enum TextFileEncoding: String, CaseIterable, Codable, Identifiable {
    case utf8
    case utf16
    case utf16LittleEndian
    case utf16BigEndian
    case isoLatin1
    case windowsCP1252
    case macOSRoman

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf16: return "UTF-16"
        case .utf16LittleEndian: return "UTF-16 LE"
        case .utf16BigEndian: return "UTF-16 BE"
        case .isoLatin1: return "ISO Latin-1"
        case .windowsCP1252: return "Windows-1252"
        case .macOSRoman: return "Mac OS Roman"
        }
    }

    var stringEncoding: String.Encoding {
        switch self {
        case .utf8: return .utf8
        case .utf16: return .utf16LittleEndian
        case .utf16LittleEndian: return .utf16LittleEndian
        case .utf16BigEndian: return .utf16BigEndian
        case .isoLatin1: return .isoLatin1
        case .windowsCP1252: return .windowsCP1252
        case .macOSRoman: return .macOSRoman
        }
    }

    static func detect(in data: Data) -> TextFileEncoding {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return .utf8
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return .utf16LittleEndian
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return .utf16BigEndian
        }

        let bytes = Array(data)
        let evenZeroCount = stride(from: 0, to: bytes.count, by: 2)
            .filter { bytes[$0] == 0 }.count
        let oddZeroCount = stride(from: 1, to: bytes.count, by: 2)
            .filter { bytes[$0] == 0 }.count
        let evenByteCount = (bytes.count + 1) / 2
        let oddByteCount = bytes.count / 2
        let evenZeroRatio = evenByteCount == 0 ? 0 : Double(evenZeroCount) / Double(evenByteCount)
        let oddZeroRatio = oddByteCount == 0 ? 0 : Double(oddZeroCount) / Double(oddByteCount)

        if oddZeroCount > 0 && oddZeroRatio >= 0.3 && oddZeroRatio > evenZeroRatio * 2 {
            return .utf16LittleEndian
        }
        if evenZeroCount > 0 && evenZeroRatio >= 0.3 && evenZeroRatio > oddZeroRatio * 2 {
            return .utf16BigEndian
        }

        if String(data: data, encoding: .utf8) != nil {
            return .utf8
        }

        let hasWindowsSpecificCharacters = bytes.contains {
            [0x80, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8A,
             0x8B, 0x8C, 0x8E, 0x91, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97,
             0x98, 0x99, 0x9A, 0x9B, 0x9C, 0x9E, 0x9F].contains($0)
        }
        if hasWindowsSpecificCharacters,
           String(data: data, encoding: .windowsCP1252) != nil {
            return .windowsCP1252
        }
        return .isoLatin1
    }

    func decode(_ data: Data) -> String? {
        var decoded = String(data: data, encoding: stringEncoding)
        if decoded?.first == "\u{FEFF}" {
            decoded?.removeFirst()
        }
        return decoded
    }

    func hasBOM(in data: Data) -> Bool {
        switch self {
        case .utf8:
            return data.starts(with: [0xEF, 0xBB, 0xBF])
        case .utf16, .utf16LittleEndian:
            return data.starts(with: [0xFF, 0xFE])
        case .utf16BigEndian:
            return data.starts(with: [0xFE, 0xFF])
        case .isoLatin1, .windowsCP1252, .macOSRoman:
            return false
        }
    }

    var bom: [UInt8] {
        switch self {
        case .utf8: return [0xEF, 0xBB, 0xBF]
        case .utf16, .utf16LittleEndian: return [0xFF, 0xFE]
        case .utf16BigEndian: return [0xFE, 0xFF]
        case .isoLatin1, .windowsCP1252, .macOSRoman: return []
        }
    }

    var supportsBOM: Bool {
        !bom.isEmpty
    }
}

@MainActor
final class TabManager: ObservableObject {
    @Published var tabs: [Tab] = []
    @Published var selectedTabIndex: Int = 0
    @Published var pendingCloseTabIndex: Int?
    @Published private(set) var hasChangedThisLaunch = false
    private var autosaveWorkItems: [UUID: DispatchWorkItem] = [:]
    private let autosaveDelay: TimeInterval = 30
    private let sessionSaveDelay: TimeInterval = 1
    private var hasSessionStateChanged = false
    private let sessionStorageKey = "previousSession"
    private var sessionSaveWorkItem: DispatchWorkItem?
    private var previousSession: SessionSnapshot?
    private var terminationObserver: NSObjectProtocol?

    var canRestorePreviousSession: Bool {
        previousSession?.tabs.isEmpty == false && !hasChangedThisLaunch
    }

    init() {
        previousSession = loadPreviousSession()
        tabs = [Tab(content: "", fileURL: nil, isEdited: false)]
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveCurrentSession()
            }
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    func newTab() {
        hasChangedThisLaunch = true
        markSessionStateChanged()
        let newTab = Tab(content: "", fileURL: nil, isEdited: false)
        tabs.append(newTab)
        selectedTabIndex = tabs.count - 1
    }

    func restorePreviousSession() {
        guard canRestorePreviousSession, let previousSession else { return }

        for tab in tabs {
            cancelAutosave(for: tab.id)
            stopSecurityScopedAccess(for: tab)
        }

        tabs = previousSession.tabs.map(restoreTab)
        selectedTabIndex = min(
            max(previousSession.selectedTabIndex, 0),
            tabs.count - 1
        )
        hasChangedThisLaunch = true
        markSessionStateChanged()

        for tab in tabs where tab.isEdited && tab.fileURL != nil {
            if tab.fileModificationDate != nil {
                scheduleAutosave(for: tab)
            } else {
                print("Autosave disabled for \(tab.displayName): no saved modification date")
            }
        }
    }

    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        guard !tabs[index].isEdited else {
            pendingCloseTabIndex = index
            return
        }

        removeTab(at: index)
    }

    func discardChangesAndCloseTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabs[index].isEdited = false
        removeTab(at: index)
    }

    private func removeTab(at index: Int) {
        pendingCloseTabIndex = nil
        markSessionStateChanged()
        cancelAutosave(for: tabs[index].id)
        stopSecurityScopedAccess(for: tabs[index])

        if tabs.count == 1 {
            tabs[0] = Tab(content: "", fileURL: nil, isEdited: false)
            selectedTabIndex = 0
        } else {
            tabs.remove(at: index)
            if selectedTabIndex >= index {
                selectedTabIndex = max(0, selectedTabIndex - 1)
            }
        }
    }

    func closeCurrentTab() {
        closeTab(at: selectedTabIndex)
    }

    func selectTab(at index: Int) {
        guard index < tabs.count else { return }
        if selectedTabIndex != index {
            markSessionStateChanged()
        }
        selectedTabIndex = index
    }

    func getCurrentTab() -> Tab? {
        guard selectedTabIndex < tabs.count else { return nil }
        return tabs[selectedTabIndex]
    }

    func saveCurrentTab(with encoding: TextFileEncoding) async -> Bool {
        guard tabs.indices.contains(selectedTabIndex) else { return false }

        tabs[selectedTabIndex].encoding = encoding
        if !encoding.supportsBOM {
            tabs[selectedTabIndex].hasBOM = false
        }
        tabs[selectedTabIndex].isEdited = true
        hasChangedThisLaunch = true
        markSessionStateChanged()
        return await saveTab(at: selectedTabIndex)
    }

    func reopenCurrentTab(with encoding: TextFileEncoding) {
        guard tabs.indices.contains(selectedTabIndex) else { return }
        reopenTab(id: tabs[selectedTabIndex].id, with: encoding)
    }

    func reopenTab(id tabID: UUID, with encoding: TextFileEncoding) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              let fileURL = tabs[index].fileURL else { return }

        let didStartAccess = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let initialModificationDate = try? modificationDate(for: fileURL)
            let data = try Data(contentsOf: fileURL)
            guard let content = encoding.decode(data) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            let finalModificationDate = try? modificationDate(for: fileURL)
            if let initialModificationDate,
               let finalModificationDate,
               initialModificationDate != finalModificationDate {
                throw AutosaveError.fileChangedOutsideApp
            }
            tabs[index].content = content
            tabs[index].encoding = encoding
            tabs[index].hasBOM = encoding.hasBOM(in: data)
            tabs[index].isEdited = false
            tabs[index].fileModificationDate =
                initialModificationDate == finalModificationDate ? initialModificationDate : nil
            cancelAutosave(for: tabID)
            hasChangedThisLaunch = true
            markSessionStateChanged()
        } catch {
            print("Error reopening file with \(encoding.displayName): \(error)")
        }
    }

    func saveCurrentTab() async -> Bool {
        await saveTab(at: selectedTabIndex)
    }

    func saveTab(at index: Int) async -> Bool {
        guard tabs.indices.contains(index) else { return false }
        let tab = tabs[index]

        if let fileURL = tab.fileURL {
            do {
                try write(tab, to: fileURL)
                tabs[index].isEdited = false
                updateModificationDate(for: index, at: fileURL)
                cancelAutosave(for: tab.id)
                markSessionStateChanged()
                return true
            } catch {
                print("Error saving file: \(error)")
                return false
            }
        } else {
            return await saveTabAs(at: index)
        }
    }

    func saveCurrentTabAs() async -> Bool {
        await saveTabAs(at: selectedTabIndex)
    }

    private func saveTabAs(at index: Int) async -> Bool {
        guard tabs.indices.contains(index) else { return false }
        let tabID = tabs[index].id
        let tab = tabs[index]

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType.text, UTType.sourceCode]
        savePanel.title = "Save File"
        savePanel.nameFieldLabel = "File name:"
        let recognizedExtensions: Set<String> = [
            "html", "htm", "xhtml", "css", "php", "js", "ts", "py",
            "swift", "json", "md", "markdown", "xml"
        ]
        let currentExtension = tab.fileURL?.pathExtension.lowercased()
        let saveExtension = currentExtension.flatMap {
            recognizedExtensions.contains($0) ? $0 : nil
        } ?? "txt"
        let baseName = tab.fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        savePanel.nameFieldStringValue = "\(baseName).\(saveExtension)"

        let response = await savePanel.begin()
        guard response == .OK,
              let url = savePanel.url,
              let current = tabs.firstIndex(where: { $0.id == tabID }) else { return false }
        let currentTab = tabs[current]

        let hasSecurityScopedAccess = url.startAccessingSecurityScopedResource()
        do {
            try write(currentTab, to: url)
            stopSecurityScopedAccess(for: currentTab)
            tabs[current].fileURL = url
            tabs[current].isEdited = false
            tabs[current].hasSecurityScopedAccess = hasSecurityScopedAccess
            updateModificationDate(for: current, at: url)
            cancelAutosave(for: tabID)
            markSessionStateChanged()
            return true
        } catch {
            if hasSecurityScopedAccess {
                url.stopAccessingSecurityScopedResource()
            }
            print("Error saving file: \(error)")
            return false
        }
    }

    func openFile() async {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [UTType.text, UTType.sourceCode]
        openPanel.title = "Open File"
        openPanel.allowsMultipleSelection = false

        let response = await openPanel.begin()

        if response == .OK, let url = openPanel.url {
            await openFile(at: url)
        }
    }

    func openFile(at url: URL) async {
        guard url.isFileURL else {
            print("Error opening dropped item: expected a file URL")
            return
        }

        let standardizedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        if let existingIndex = tabs.firstIndex(where: {
            $0.fileURL?.standardizedFileURL.resolvingSymlinksInPath() == standardizedURL
        }) {
            selectTab(at: existingIndex)
            return
        }

        let hasSecurityScopedAccess = url.startAccessingSecurityScopedResource()
        do {
            let initialModificationDate = try? modificationDate(for: url)
            let data = try Data(contentsOf: url)
            let encoding = TextFileEncoding.detect(in: data)
            guard let content = encoding.decode(data) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            let finalModificationDate = try? modificationDate(for: url)
            if let initialModificationDate,
               let finalModificationDate,
               initialModificationDate != finalModificationDate {
                throw AutosaveError.fileChangedOutsideApp
            }
            let fileModificationDate = initialModificationDate == finalModificationDate
                ? initialModificationDate
                : nil
            if fileModificationDate == nil {
                print("Autosave disabled for \(url.lastPathComponent): unable to establish a stable modification date")
            }
            let newTab = Tab(
                content: content,
                fileURL: url,
                isEdited: false,
                hasSecurityScopedAccess: hasSecurityScopedAccess,
                encoding: encoding,
                fileModificationDate: fileModificationDate,
                hasBOM: encoding.hasBOM(in: data)
            )
            hasChangedThisLaunch = true
            markSessionStateChanged()
            let emptyUntitledIndex = tabs.indices.first(where: {
                tabs[$0].fileURL == nil &&
                !tabs[$0].isEdited &&
                tabs[$0].content.isEmpty
            })
            let targetIndex = tabs.indices.contains(selectedTabIndex) &&
                tabs[selectedTabIndex].fileURL == nil &&
                !tabs[selectedTabIndex].isEdited &&
                tabs[selectedTabIndex].content.isEmpty
                ? selectedTabIndex
                : emptyUntitledIndex

            if let targetIndex {
                tabs[targetIndex] = newTab
                selectedTabIndex = targetIndex
            } else {
                tabs.append(newTab)
                selectedTabIndex = tabs.count - 1
            }
        } catch {
            if hasSecurityScopedAccess {
                url.stopAccessingSecurityScopedResource()
            }
            print("Error opening file: \(error)")
        }
    }

    func updateCurrentTabContent(_ newContent: String) {
        guard selectedTabIndex < tabs.count else { return }
        guard tabs[selectedTabIndex].content != newContent else { return }
        tabs[selectedTabIndex].content = newContent
        tabs[selectedTabIndex].isEdited = true
        hasChangedThisLaunch = true
        markSessionStateChanged()
        scheduleAutosave(for: tabs[selectedTabIndex])
    }

    private func scheduleAutosave(for tab: Tab) {
        cancelAutosave(for: tab.id)
        guard tab.fileURL != nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            self?.autosave(tabID: tab.id)
        }

        autosaveWorkItems[tab.id] = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + autosaveDelay,
            execute: workItem
        )
    }

    private func autosave(tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              tabs[index].isEdited,
              let fileURL = tabs[index].fileURL else { return }
        guard let expectedModificationDate = tabs[index].fileModificationDate else {
            cancelAutosave(for: tabID)
            print("Autosave skipped for \(tabs[index].displayName): no saved modification date")
            return
        }

        do {
            var coordinationError: NSError?
            var writeError: Error?
            NSFileCoordinator(filePresenter: nil).coordinate(
                writingItemAt: fileURL,
                options: .forReplacing,
                error: &coordinationError
            ) { coordinatedURL in
                do {
                    guard try modificationDate(for: coordinatedURL) == expectedModificationDate else {
                        throw AutosaveError.fileChangedOutsideApp
                    }
                    try write(tabs[index], to: coordinatedURL)
                    updateModificationDate(for: index, at: coordinatedURL)
                    tabs[index].isEdited = false
                } catch {
                    writeError = error
                }
            }
            if let coordinationError {
                throw coordinationError
            }
            if let writeError {
                throw writeError
            }
            cancelAutosave(for: tabID)
            markSessionStateChanged()
        } catch {
            print("Error autosaving file: \(error)")
            cancelAutosave(for: tabID)
        }
    }

    private func cancelAutosave(for tabID: UUID) {
        autosaveWorkItems[tabID]?.cancel()
        autosaveWorkItems[tabID] = nil
    }

    private func stopSecurityScopedAccess(for tab: Tab) {
        guard tab.hasSecurityScopedAccess, let fileURL = tab.fileURL else { return }
        fileURL.stopAccessingSecurityScopedResource()
    }

    private func modificationDate(for url: URL) throws -> Date {
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
        guard let date = values.contentModificationDate else {
            throw AutosaveError.modificationDateUnavailable
        }
        return date
    }

    private func updateModificationDate(for index: Int, at url: URL) {
        do {
            tabs[index].fileModificationDate = try modificationDate(for: url)
        } catch {
            tabs[index].fileModificationDate = nil
            print("Unable to track file modification date for \(url.lastPathComponent): \(error)")
        }
    }

    private func write(_ tab: Tab, to url: URL) throws {
        guard let data = tab.content.data(using: tab.encoding.stringEncoding) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        var outputData = data
        if tab.hasBOM, tab.encoding.supportsBOM {
            outputData.insert(contentsOf: tab.encoding.bom, at: 0)
        }
        try outputData.write(to: url, options: .atomic)
    }

    private func loadPreviousSession() -> SessionSnapshot? {
        do {
            let sessionURL = try sessionFileURL()
            if FileManager.default.fileExists(atPath: sessionURL.path) {
                let data = try Data(contentsOf: sessionURL)
                return try JSONDecoder().decode(SessionSnapshot.self, from: data)
            }

            guard let legacyData = UserDefaults.standard.data(forKey: sessionStorageKey) else {
                return nil
            }
            return try JSONDecoder().decode(SessionSnapshot.self, from: legacyData)
        } catch {
            print("Error restoring previous session: \(error)")
            return nil
        }
    }

    private func saveCurrentSession() {
        guard hasSessionStateChanged else { return }

        do {
            let snapshot = SessionSnapshot(
                tabs: tabs.map { tab in
                    return SavedTab(
                        content: tab.content,
                        fileURL: tab.fileURL?.absoluteString,
                        fileBookmark: bookmarkData(for: tab.fileURL),
                        fileModificationDate: tab.fileModificationDate,
                        isEdited: tab.isEdited,
                        encoding: tab.encoding
                    )
                },
                selectedTabIndex: selectedTabIndex
            )
            let data = try JSONEncoder().encode(snapshot)
            let sessionURL = try sessionFileURL()
            try FileManager.default.createDirectory(
                at: sessionURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            try data.write(to: sessionURL, options: .atomic)
            UserDefaults.standard.removeObject(forKey: sessionStorageKey)
            hasSessionStateChanged = false
            sessionSaveWorkItem = nil
        } catch {
            print("Error saving session: \(error)")
        }
    }

    private func bookmarkData(for url: URL?) -> Data? {
        guard let url else { return nil }
        do {
            return try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            print("Error saving security-scoped bookmark for \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    private func sessionFileURL() throws -> URL {
        let applicationSupportURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let applicationDirectory = Bundle.main.bundleIdentifier ?? "LightNotePlus"
        return applicationSupportURL
            .appendingPathComponent(applicationDirectory, isDirectory: true)
            .appendingPathComponent("previous-session.json")
    }

    private func restoreTab(_ savedTab: SavedTab) -> Tab {
        var fileURL = savedTab.fileURL.flatMap { URL(string: $0) }
        var hasSecurityScopedAccess = false
        let encoding = savedTab.encoding ?? .utf8

        if let bookmark = savedTab.fileBookmark {
            do {
                var isStale = false
                let bookmarkedURL = try URL(
                    resolvingBookmarkData: bookmark,
                    options: [.withSecurityScope, .withoutUI],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                fileURL = bookmarkedURL
                hasSecurityScopedAccess = bookmarkedURL.startAccessingSecurityScopedResource()
                if isStale {
                    print("Session bookmark is stale for \(bookmarkedURL.lastPathComponent)")
                }
            } catch {
                print("Error restoring security-scoped file access: \(error)")
            }
        }

        let hasBOM: Bool
        if let savedHasBOM = savedTab.hasBOM {
            hasBOM = savedHasBOM
        } else if let fileURL, let data = try? Data(contentsOf: fileURL) {
            hasBOM = encoding.hasBOM(in: data)
        } else {
            hasBOM = false
        }

        return Tab(
            content: savedTab.content,
            fileURL: fileURL,
            isEdited: savedTab.isEdited,
            hasSecurityScopedAccess: hasSecurityScopedAccess,
            encoding: encoding,
            fileModificationDate: savedTab.fileModificationDate,
            hasBOM: hasBOM
        )
    }

    private func markSessionStateChanged() {
        hasSessionStateChanged = true
        sessionSaveWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.saveCurrentSession()
        }
        sessionSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + sessionSaveDelay,
            execute: workItem
        )
    }

    private enum AutosaveError: LocalizedError {
        case fileChangedOutsideApp
        case modificationDateUnavailable

        var errorDescription: String? {
            switch self {
            case .fileChangedOutsideApp:
                return "The file changed outside the app; autosave was skipped to avoid overwriting it."
            case .modificationDateUnavailable:
                return "The file modification date is unavailable."
            }
        }
    }

    private struct SessionSnapshot: Codable {
        let tabs: [SavedTab]
        let selectedTabIndex: Int
    }

    private struct SavedTab: Codable {
        let content: String
        let fileURL: String?
        var fileBookmark: Data? = nil
        var fileModificationDate: Date? = nil
        var hasBOM: Bool? = nil
        let isEdited: Bool
        let encoding: TextFileEncoding?
    }
}

struct Tab: Identifiable {
    let id = UUID()
    var content: String
    var fileURL: URL?
    var isEdited: Bool
    var hasSecurityScopedAccess = false
    var encoding: TextFileEncoding = .utf8
    var fileModificationDate: Date? = nil
    var hasBOM: Bool = false

    var displayName: String {
        if let url = fileURL {
            return url.lastPathComponent
        } else {
            return "Untitled"
        }
    }
}
