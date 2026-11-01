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

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf16: return "UTF-16"
        case .utf16LittleEndian: return "UTF-16 LE"
        case .utf16BigEndian: return "UTF-16 BE"
        }
    }

    var stringEncoding: String.Encoding {
        switch self {
        case .utf8: return .utf8
        case .utf16: return .utf16
        case .utf16LittleEndian: return .utf16LittleEndian
        case .utf16BigEndian: return .utf16BigEndian
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

        if data.count >= 4 {
            let bytes = Array(data)
            let evenZeroCount = stride(from: 0, to: bytes.count, by: 2)
                .filter { bytes[$0] == 0 }.count
            let oddZeroCount = stride(from: 1, to: bytes.count, by: 2)
                .filter { bytes[$0] == 0 }.count

            if oddZeroCount >= 2 && oddZeroCount > evenZeroCount * 2 {
                return .utf16LittleEndian
            }
            if evenZeroCount >= 2 && evenZeroCount > oddZeroCount * 2 {
                return .utf16BigEndian
            }
        }

        guard String(data: data, encoding: .utf8) == nil,
              data.count >= 2,
              data.count.isMultiple(of: 2) else {
            return .utf8
        }

        return String(data: data, encoding: .utf16LittleEndian) != nil
            ? .utf16LittleEndian
            : .utf16BigEndian
    }

    func decode(_ data: Data) -> String? {
        var decoded = String(data: data, encoding: stringEncoding)
        if decoded?.first == "\u{FEFF}" {
            decoded?.removeFirst()
        }
        return decoded
    }
}

final class TabManager: ObservableObject {
    @Published var tabs: [Tab] = []
    @Published var selectedTabIndex: Int = 0
    @Published var pendingCloseTabIndex: Int?
    @Published private(set) var hasChangedThisLaunch = false
    private var autosaveWorkItems: [UUID: DispatchWorkItem] = [:]
    private let autosaveDelay: TimeInterval = 30
    private var hasSessionStateChanged = false
    private let sessionStorageKey = "previousSession"
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
            self?.saveCurrentSession()
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    func newTab() {
        hasChangedThisLaunch = true
        hasSessionStateChanged = true
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

        tabs = previousSession.tabs.map { savedTab in
            Tab(
                content: savedTab.content,
                fileURL: savedTab.fileURL.flatMap { URL(string: $0) },
                isEdited: savedTab.isEdited,
                encoding: savedTab.encoding ?? .utf8
            )
        }
        selectedTabIndex = min(
            max(previousSession.selectedTabIndex, 0),
            tabs.count - 1
        )
        hasChangedThisLaunch = true
        hasSessionStateChanged = true

        for tab in tabs where tab.isEdited && tab.fileURL != nil {
            scheduleAutosave(for: tab)
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
        hasSessionStateChanged = true
        cancelAutosave(for: tabs[index].id)
        stopSecurityScopedAccess(for: tabs[index])

        if tabs.count == 1 {
            tabs[0].content = ""
            tabs[0].fileURL = nil
            tabs[0].isEdited = false
            tabs[0].hasSecurityScopedAccess = false
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
        hasSessionStateChanged = hasSessionStateChanged || selectedTabIndex != index
        selectedTabIndex = index
    }

    func getCurrentTab() -> Tab? {
        guard selectedTabIndex < tabs.count else { return nil }
        return tabs[selectedTabIndex]
    }

    func selectEncoding(_ encoding: TextFileEncoding) {
        guard tabs.indices.contains(selectedTabIndex),
              tabs[selectedTabIndex].encoding != encoding else { return }

        tabs[selectedTabIndex].encoding = encoding
        tabs[selectedTabIndex].isEdited = true
        hasChangedThisLaunch = true
        hasSessionStateChanged = true
        scheduleAutosave(for: tabs[selectedTabIndex])
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
                cancelAutosave(for: tab.id)
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
        let tab = tabs[index]

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType.text, UTType.sourceCode]
        savePanel.title = "Save File"
        savePanel.nameFieldLabel = "File name:"

        let response = await savePanel.begin()
        guard response == .OK, let url = savePanel.url else { return false }

        let hasSecurityScopedAccess = url.startAccessingSecurityScopedResource()
        do {
            try write(tab, to: url)
            guard tabs.indices.contains(index) else {
                if hasSecurityScopedAccess {
                    url.stopAccessingSecurityScopedResource()
                }
                return false
            }
            stopSecurityScopedAccess(for: tabs[index])
            tabs[index].fileURL = url
            tabs[index].isEdited = false
            tabs[index].hasSecurityScopedAccess = hasSecurityScopedAccess
            cancelAutosave(for: tab.id)
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

        let hasSecurityScopedAccess = url.startAccessingSecurityScopedResource()
        do {
            let data = try Data(contentsOf: url)
            let encoding = TextFileEncoding.detect(in: data)
            guard let content = encoding.decode(data) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            let newTab = Tab(
                content: content,
                fileURL: url,
                isEdited: false,
                hasSecurityScopedAccess: hasSecurityScopedAccess,
                encoding: encoding
            )
            hasChangedThisLaunch = true
            hasSessionStateChanged = true
            tabs.append(newTab)
            selectedTabIndex = tabs.count - 1
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
        hasSessionStateChanged = true
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

        do {
            try write(tabs[index], to: fileURL)
            tabs[index].isEdited = false
            cancelAutosave(for: tabID)
        } catch {
            print("Error autosaving file: \(error)")
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

    private func write(_ tab: Tab, to url: URL) throws {
        guard let data = tab.content.data(using: tab.encoding.stringEncoding) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try data.write(to: url, options: .atomic)
    }

    private func loadPreviousSession() -> SessionSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: sessionStorageKey) else {
            return nil
        }

        do {
            return try JSONDecoder().decode(SessionSnapshot.self, from: data)
        } catch {
            print("Error restoring previous session: \(error)")
            return nil
        }
    }

    private func saveCurrentSession() {
        guard hasSessionStateChanged else { return }

        let snapshot = SessionSnapshot(
            tabs: tabs.map {
                SavedTab(
                    content: $0.content,
                    fileURL: $0.fileURL?.absoluteString,
                    isEdited: $0.isEdited,
                    encoding: $0.encoding
                )
            },
            selectedTabIndex: selectedTabIndex
        )

        do {
            let data = try JSONEncoder().encode(snapshot)
            UserDefaults.standard.set(data, forKey: sessionStorageKey)
        } catch {
            print("Error saving session: \(error)")
        }
    }

    private struct SessionSnapshot: Codable {
        let tabs: [SavedTab]
        let selectedTabIndex: Int
    }

    private struct SavedTab: Codable {
        let content: String
        let fileURL: String?
        let isEdited: Bool
        let encoding: TextFileEncoding?
    }
}

struct Tab {
    var id = UUID()
    var content: String
    var fileURL: URL?
    var isEdited: Bool
    var hasSecurityScopedAccess = false
    var encoding: TextFileEncoding = .utf8

    var displayName: String {
        if let url = fileURL {
            return url.lastPathComponent
        } else {
            return "Untitled"
        }
    }
}
