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

struct ContentView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var tabManager: TabManager

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
                Image(systemName: "arrow.down.doc")
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

    @State private var text: String = ""
    @State private var lineNumbers: [Int] = []

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(lineNumbers, id: \.self) { number in
                        Text("\(number)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(themeManager.colors.lineNumbers)
                            .frame(width: 40, alignment: .trailing)
                            .padding(.trailing, 8)
                    }
                }
            }
            .background(themeManager.colors.editorBackground)
            .frame(width: 50)

            ScrollView {
                TextEditor(text: $text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(themeManager.colors.editorText)
                    .scrollContentBackground(.hidden)
                    .background(themeManager.colors.editorBackground)
                    .environment(\.colorScheme, themeManager.currentTheme == .light ? .light : .dark)
                    .padding(.leading, 8)
                    .onChange(of: text) { newValue in
                        updateLineNumbers()
                        tabManager.updateCurrentTabContent(newValue)
                    }
                    .onAppear {
                        if let currentTab = tabManager.getCurrentTab() {
                            text = currentTab.content
                            updateLineNumbers()
                        }
                    }
                    .onChange(of: tabManager.selectedTabIndex) { _ in
                        if let currentTab = tabManager.getCurrentTab() {
                            text = currentTab.content
                            updateLineNumbers()
                        }
                    }
            }
        }
        .background(themeManager.colors.editorBackground)
    }

    private func updateLineNumbers() {
        let lines = text.components(separatedBy: .newlines)
        lineNumbers = Array(1...lines.count)
    }
}
