//  SimpleNotepad/
//  ├── SimpleNotepad/                  # Source files
//  │   ├── AppDelegate.swift           # App entry point//
//  │   ├── ContentView.swift           # Main view with toolbar, tabs, and editor
//  │   ├── ThemeManager.swift          # Dark/light theme management
//  │   ├── TabManager.swift            # Tab system for multiple files
//  │   ├── SyntaxHighlighter.swift     # Syntax highlighting (framework)
//  │   └── Info.plist                  # App configuration
//  └── SimpleNotepad.xcodeproj/        # Xcode project files
//
// Created by mnrds on 27.10.2026.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var tabManager: TabManager
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            ToolbarView()
                .environmentObject(themeManager)
                .environmentObject(tabManager)

            TabBarView()
                .environmentObject(themeManager)
                .environmentObject(tabManager)

            EditorView()
                .environmentObject(themeManager)
                .environmentObject(tabManager)
        }
        .frame(minWidth: 400, minHeight: 300)
        .background(themeManager.colors.background)
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        themeManager.colors.tabSelected,
                        style: StrokeStyle(lineWidth: 3, dash: [8])
                    )
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(
            of: [UTType.fileURL],
            isTargeted: $isTargeted,
            perform: handleFileDrop
        )
        .alert(
            "Save changes before closing?",
            isPresented: Binding(
                get: { tabManager.pendingCloseTabIndex != nil },
                set: { isPresented in
                    if !isPresented {
                        tabManager.pendingCloseTabIndex = nil
                    }
                }
            )
        ) {
            if let index = tabManager.pendingCloseTabIndex {
                Button("Save") {
                    Task {
                        if await tabManager.saveTab(at: index) {
                            tabManager.closeTab(at: index)
                        }
                    }
                }
                Button("Don't Save", role: .destructive) {
                    tabManager.discardChangesAndCloseTab(at: index)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let index = tabManager.pendingCloseTabIndex,
               tabManager.tabs.indices.contains(index) {
                Text("Do you want to save changes to \(tabManager.tabs[index].displayName) before closing?")
            }
        }
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileURLType = UTType.fileURL.identifier
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(fileURLType)
        }
        guard !fileProviders.isEmpty else { return false }

        for provider in fileProviders {
            provider.loadItem(forTypeIdentifier: fileURLType, options: nil) { item, error in
                if let error {
                    print("Error loading dropped file: \(error)")
                    return
                }

                let url = (item as? URL) ?? (item as? Data).flatMap {
                    URL(dataRepresentation: $0, relativeTo: nil)
                }
                guard let url else {
                    print("Error loading dropped file: invalid file URL")
                    return
                }

                Task { @MainActor in
                    await tabManager.openFile(at: url)
                }
            }
        }

        return true
    }
}

struct ToolbarView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var tabManager: TabManager

    var body: some View {
        HStack {
            Button(action: { Task { await tabManager.openFile() } }) {
                Image(systemName: "folder")
                    .foregroundColor(themeManager.colors.text)
            }
            .buttonStyle(.plain)
            .help("Open")

            Button(action: { Task { await tabManager.saveCurrentTab() } }) {
                Image(systemName: "square.and.arrow.down")
                    .foregroundColor(themeManager.colors.text)
            }
            .buttonStyle(.plain)
            .help("Save")

            Button(action: { tabManager.newTab() }) {
                Image(systemName: "plus")
                    .foregroundColor(themeManager.colors.text)
            }
            .buttonStyle(.plain)
            .help("New Tab")

            Button(action: { tabManager.closeCurrentTab() }) {
                Image(systemName: "xmark")
                    .foregroundColor(themeManager.colors.text)
            }
            .buttonStyle(.plain)
            .help("Close Tab")

            Spacer()

            Button(action: { themeManager.toggleTheme() }) {
                Image(systemName: themeManager.currentTheme == .light ? "moon.fill" : "sun.max.fill")
                    .foregroundColor(themeManager.colors.text)
            }
            .buttonStyle(.plain)
            .help("Toggle Theme")
        }
        .padding(8)
        .background(themeManager.colors.tabBackground)
    }
}

struct TabBarView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var tabManager: TabManager

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(tabManager.tabs.indices, id: \.self) { index in
                    TabItem(
                        name: tabManager.tabs[index].displayName,
                        isSelected: index == tabManager.selectedTabIndex,
                        isEdited: tabManager.tabs[index].isEdited,
                        themeColors: themeManager.colors
                    )
                    .onTapGesture {
                        tabManager.selectTab(at: index)
                    }
                    .contextMenu {
                        Button("Close") {
                            tabManager.closeTab(at: index)
                        }
                    }
                }
            }
        }
        .frame(height: 30)
        .background(themeManager.colors.tabBackground)
    }
}

struct TabItem: View {
    let name: String
    let isSelected: Bool
    let isEdited: Bool
    let themeColors: ThemeColors

    var body: some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.system(size: 12))
                .foregroundColor(isSelected ? themeColors.tabSelected : themeColors.tabText)

            if isEdited {
                Circle()
                    .fill(Color.gray)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? themeColors.tabSelected.opacity(0.2) : Color.clear)
        )
    }
}

struct EditorView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var findState: FindState
    @EnvironmentObject var zoomState: ZoomState

    private var currentContent: String {
        tabManager.getCurrentTab()?.content ?? ""
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { currentContent },
            set: { tabManager.updateCurrentTabContent($0) }
        )
    }

    private var lineNumbers: [Int] {
        Array(1...currentContent.components(separatedBy: .newlines).count)
    }

    private var wordCount: Int {
        currentContent.split(whereSeparator: \.isWhitespace).count
    }

    private var characterCount: Int {
        currentContent.count
    }

    private var textEditor: some View {
        TextEditor(text: textBinding)
            .font(.system(size: zoomState.fontSize, design: .monospaced))
            .foregroundColor(themeManager.colors.editorText)
            .scrollContentBackground(.hidden)
            .background(themeManager.colors.editorBackground)
            .environment(\.colorScheme, themeManager.currentTheme == .light ? .light : .dark)
            .padding(.leading, 8)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .trailing, spacing: 0) {
                        ForEach(lineNumbers, id: \.self) { number in
                            Text("\(number)")
                                .font(.system(size: zoomState.fontSize, design: .monospaced))
                                .foregroundColor(themeManager.colors.lineNumbers)
                                .frame(width: 40, alignment: .trailing)
                                .padding(.trailing, 8)
                        }
                    }
                }
                .background(themeManager.colors.editorBackground)
                .frame(width: 50)

                ScrollView {
                    if #available(macOS 26.0, *) {
                        textEditor.findNavigator(isPresented: $findState.isPresented)
                    } else {
                        textEditor
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Spacer()
                Text("Words: \(wordCount)  |  Characters: \(characterCount)")
                    .font(.system(size: 11))
                    .foregroundColor(themeManager.colors.tabText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(themeManager.colors.tabBackground)
        }
        .background(themeManager.colors.editorBackground)
    }
}
