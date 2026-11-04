//  LightNote+/
//  This is the text editor app inside LightNote+
//  Original main program file. 
//
// Created by mnrds
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject private var notesWorkspace: NotesWorkspaceModel
    @State private var isTargeted = false
    @State private var showsNotesView = false

    var body: some View {
        VStack(spacing: 0) {
            ToolbarView(showsNotesView: $showsNotesView)
                .environmentObject(themeManager)
                .environmentObject(tabManager)

            if showsNotesView {
                NoteView(model: notesWorkspace)
                    .environmentObject(themeManager)
            } else {
                TabBarView()
                    .environmentObject(themeManager)
                    .environmentObject(tabManager)

                EditorView()
                    .environmentObject(themeManager)
                    .environmentObject(tabManager)
            }
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
        .onAppear(perform: notesWorkspace.loadWorkspace)
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
    @Binding var showsNotesView: Bool

    var body: some View {
        HStack {
            if !showsNotesView {
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

                Button(action: { tabManager.restorePreviousSession() }) {
                    Label("Session Restore", systemImage: "clock.arrow.circlepath")
                        .foregroundColor(themeManager.colors.text)
                }
                .buttonStyle(.plain)
                .disabled(!tabManager.canRestorePreviousSession)
                .help("Restore tabs from the previous session")
            }

            Spacer()

            Button {
                showsNotesView.toggle()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundColor(themeManager.colors.text)
            }
            .buttonStyle(.plain)
            .help(showsNotesView ? "Switch to Text Editor" : "Switch to Notes")

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

private struct HighlightedSyntaxEditor: NSViewRepresentable {
    @Binding var text: String
    let theme: ThemeManager.Theme
    let fontSize: CGFloat
    let language: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainerInset = NSSize(width: 5, height: 8)
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        coordinator.text = $text
        coordinator.highlighter.update(text: text, theme: theme, language: language)

        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let textColor = theme == .light ? NSColor.black : NSColor.white
        textView.font = font
        textView.textColor = textColor
        textView.insertionPointColor = textColor
        textView.backgroundColor = theme == .light
            ? NSColor.white
            : NSColor(calibratedRed: 0.1, green: 0.1, blue: 0.12, alpha: 1)
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: textColor
        ]

        let formattedText = NSMutableAttributedString(
            attributedString: coordinator.highlighter.highlightedText
        )
        if formattedText.length > 0 {
            formattedText.addAttribute(
                .font,
                value: font,
                range: NSRange(location: 0, length: formattedText.length)
            )
        }

        guard !textView.attributedString().isEqual(to: formattedText) else { return }

        let selection = textView.selectedRange()
        let location = min(selection.location, formattedText.length)
        let length = min(selection.length, formattedText.length - location)
        coordinator.isApplyingChanges = true
        textView.textStorage?.setAttributedString(formattedText)
        textView.setSelectedRange(NSRange(location: location, length: length))
        coordinator.isApplyingChanges = false
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        let highlighter = SyntaxHighlighter()
        var isApplyingChanges = false

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingChanges,
                  let textView = notification.object as? NSTextView else {
                return
            }
            text.wrappedValue = textView.string
        }
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

    private var currentLanguage: String? {
        SyntaxHighlighter.detectLanguage(from: tabManager.getCurrentTab()?.fileURL)
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

    private var currentEncoding: TextFileEncoding {
        tabManager.getCurrentTab()?.encoding ?? .utf8
    }

    @ViewBuilder
    private var textEditor: some View {
        if currentLanguage == "html" || currentLanguage == "css" {
            HighlightedSyntaxEditor(
                text: textBinding,
                theme: themeManager.currentTheme,
                fontSize: zoomState.fontSize,
                language: currentLanguage ?? "html"
            )
            .padding(.leading, 8)
        } else {
            let editor = TextEditor(text: textBinding)
                .font(.system(size: zoomState.fontSize, design: .monospaced))
                .foregroundColor(themeManager.colors.editorText)
                .scrollContentBackground(.hidden)
                .background(themeManager.colors.editorBackground)
                .environment(\.colorScheme, themeManager.currentTheme == .light ? .light : .dark)
                .padding(.leading, 8)

            if #available(macOS 26.0, *) {
                editor.findNavigator(isPresented: $findState.isPresented)
            } else {
                editor
            }
        }
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

                if currentLanguage == "html" || currentLanguage == "css" {
                    textEditor
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        textEditor
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Text("Version 1.1")
                    .font(.system(size: 11))
                    .foregroundColor(themeManager.colors.tabText)

                Spacer()
                Menu {
                    ForEach(TextFileEncoding.allCases) { encoding in
                        Button {
                            tabManager.selectEncoding(encoding)
                        } label: {
                            if currentEncoding == encoding {
                                Label(encoding.displayName, systemImage: "checkmark")
                            } else {
                                Text(encoding.displayName)
                            }
                        }
                    }
                } label: {
                    Text(currentEncoding.displayName)
                        .font(.system(size: 11))
                        .foregroundColor(themeManager.colors.tabText)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Select text encoding")

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
