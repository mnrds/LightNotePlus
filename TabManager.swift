//
//  TabManager.swift
//  mac-txt-editor
//
//  Created by mnrds on 26.10.2026.
//

import SwiftUI
import Combine
import UniformTypeIdentifiers

final class TabManager: ObservableObject {
    @Published var tabs: [Tab] = []
    @Published var selectedTabIndex: Int = 0
    @Published var pendingCloseTabIndex: Int?
    private var autosaveWorkItems: [UUID: DispatchWorkItem] = [:]
    private let autosaveDelay: TimeInterval = 30

    init() {
        newTab()
    }

    func newTab() {
        let newTab = Tab(content: "", fileURL: nil, isEdited: false)
        tabs.append(newTab)
        selectedTabIndex = tabs.count - 1
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
        selectedTabIndex = index
    }

    func getCurrentTab() -> Tab? {
        guard selectedTabIndex < tabs.count else { return nil }
        return tabs[selectedTabIndex]
    }

    func saveCurrentTab() async -> Bool {
        await saveTab(at: selectedTabIndex)
    }

    func saveTab(at index: Int) async -> Bool {
        guard tabs.indices.contains(index) else { return false }
        let tab = tabs[index]

        if let fileURL = tab.fileURL {
            do {
                try tab.content.write(to: fileURL, atomically: true, encoding: .utf8)
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
            try tab.content.write(to: url, atomically: true, encoding: .utf8)
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
            let content = try String(contentsOf: url, encoding: .utf8)
            let newTab = Tab(
                content: content,
                fileURL: url,
                isEdited: false,
                hasSecurityScopedAccess: hasSecurityScopedAccess
            )
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
        tabs[selectedTabIndex].content = newContent
        tabs[selectedTabIndex].isEdited = true
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
            try tabs[index].content.write(to: fileURL, atomically: true, encoding: .utf8)
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
}

struct Tab {
    var id = UUID()
    var content: String
    var fileURL: URL?
    var isEdited: Bool
    var hasSecurityScopedAccess = false

    var displayName: String {
        if let url = fileURL {
            return url.lastPathComponent
        } else {
            return "Untitled"
        }
    }
}
