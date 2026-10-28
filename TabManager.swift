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

        if tabs.count == 1 {
            tabs[0].content = ""
            tabs[0].fileURL = nil
            tabs[0].isEdited = false
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
                return true
            } catch {
                print("Error saving file: \(error)")
                return false
            }
        } else {
            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [UTType.text, UTType.sourceCode]
            savePanel.title = "Save File"
            savePanel.nameFieldLabel = "File name:"

            let response = await savePanel.begin()

            if response == .OK, let url = savePanel.url {
                do {
                    try tab.content.write(to: url, atomically: true, encoding: .utf8)
                    guard tabs.indices.contains(index) else { return false }
                    tabs[index].fileURL = url
                    tabs[index].isEdited = false
                    return true
                } catch {
                    print("Error saving file: \(error)")
                    return false
                }
            }
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
            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                let newTab = Tab(content: content, fileURL: url, isEdited: false)
                tabs.append(newTab)
                selectedTabIndex = tabs.count - 1
            } catch {
                print("Error opening file: \(error)")
            }
        }
    }

    func updateCurrentTabContent(_ newContent: String) {
        guard selectedTabIndex < tabs.count else { return }
        tabs[selectedTabIndex].content = newContent
        tabs[selectedTabIndex].isEdited = true
    }
}

struct Tab {
    var content: String
    var fileURL: URL?
    var isEdited: Bool

    var displayName: String {
        if let url = fileURL {
            return url.lastPathComponent
        } else {
            return "Untitled"
        }
    }
}
