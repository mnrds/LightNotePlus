//  LightNote+/
//  This is the text editor app inside LightNote+
//  Original main program file.
//
// Created by mnrds
//

import SwiftUI
import Combine
import UniformTypeIdentifiers
import AppKit

extension EnvironmentValues {
    /// False for the pane ContentView keeps alive but hidden (opacity 0).
    /// AppKit-backed editors use it to hide their NSView, because a view that
    /// is only transparent still shows its I-beam cursor and can take clicks.
    @Entry var isPaneActive = true
}

struct ContentView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject private var notesWorkspace: NotesWorkspaceModel
    @State private var isTargeted = false
    @AppStorage("showsNotesView") private var showsNotesView =
        UserDefaults.standard.string(forKey: "defaultOpeningView") == AppOpeningView.notes.rawValue

    var body: some View {
        VStack(spacing: 0) {
            ToolbarView(showsNotesView: $showsNotesView)
                .environmentObject(themeManager)
                .environmentObject(tabManager)

            ZStack {
                NoteView(model: notesWorkspace)
                    .environmentObject(themeManager)
                    .environment(\.isPaneActive, showsNotesView)
                    .opacity(showsNotesView ? 1 : 0)
                    .allowsHitTesting(showsNotesView)
                    .accessibilityHidden(!showsNotesView)
                    .zIndex(showsNotesView ? 1 : 0)

                VStack(spacing: 0) {
                    TabBarView()
                        .environmentObject(themeManager)
                        .environmentObject(tabManager)

                    EditorView()
                        .environmentObject(themeManager)
                        .environmentObject(tabManager)
                }
                .environment(\.isPaneActive, !showsNotesView)
                .opacity(showsNotesView ? 0 : 1)
                .allowsHitTesting(!showsNotesView)
                .accessibilityHidden(showsNotesView)
                .zIndex(showsNotesView ? 0 : 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        // Runs once per app session, not every time a window or this view appears.
        .onAppear(perform: notesWorkspace.loadWorkspaceIfNeeded)
        .onChange(of: showsNotesView) { _, isShowingNotes in
            if !isShowingNotes {
                notesWorkspace.saveCurrentNote()
            }
            if let window = NSApp.keyWindow {
                window.endEditing(for: nil)
                window.makeFirstResponder(nil)
            }
        }
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
                .accessibilityLabel("Open File")

                Button(action: { Task { await tabManager.saveCurrentTab() } }) {
                    Image(systemName: "square.and.arrow.down")
                        .foregroundColor(themeManager.colors.text)
                }
                .buttonStyle(.plain)
                .help("Save")
                .accessibilityLabel("Save")

                Button(action: { Task { await tabManager.saveCurrentTabAs() } }) {
                    Image(systemName: "square.and.pencil")
                        .foregroundColor(themeManager.colors.text)
                }
                .buttonStyle(.plain)
                .help("Save As")
                .accessibilityLabel("Save As")

                Button(action: { tabManager.newTab() }) {
                    Image(systemName: "plus")
                        .foregroundColor(themeManager.colors.text)
                }
                .buttonStyle(.plain)
                .help("New Tab")
                .accessibilityLabel("New Tab")

                Button(action: { tabManager.closeCurrentTab() }) {
                    Image(systemName: "xmark")
                        .foregroundColor(themeManager.colors.text)
                }
                .buttonStyle(.plain)
                .help("Close Tab")
                .accessibilityLabel("Close Tab")

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
                HStack(spacing: 6) {
                    Image(systemName: "arrow.left.arrow.right")
                    Text(showsNotesView ? "Switch to Text Editor" : "Switch to Notes")
                }
                .foregroundColor(themeManager.colors.text)
            }
            .buttonStyle(.plain)
            .help(showsNotesView ? "Switch to Text Editor" : "Switch to Notes")
            .accessibilityLabel(showsNotesView ? "Switch to Text Editor" : "Switch to Notes")

            Button(action: { themeManager.toggleTheme() }) {
                Image(systemName: themeManager.currentTheme == .light ? "moon.fill" : "sun.max.fill")
                    .foregroundColor(themeManager.colors.text)
            }
            .buttonStyle(.plain)
            .help("Toggle Theme")
            .accessibilityLabel("Toggle Theme")

            SettingsLink {
                Image(systemName: "gearshape")
                    .foregroundColor(themeManager.colors.text)
            }
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityLabel("Settings")
        }
        .padding(8)
        .background(themeManager.colors.tabBackground)
    }
}

struct TabBarView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var tabManager: TabManager

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(tabManager.tabs) { tab in
                        TabItem(
                            name: tab.displayName,
                            isSelected: tab.id == tabManager.getCurrentTab()?.id,
                            isEdited: tab.isEdited,
                            themeColors: themeManager.colors,
                            onSelect: {
                                guard let index = tabManager.tabs.firstIndex(where: { $0.id == tab.id }) else {
                                    return
                                }
                                tabManager.selectTab(at: index)
                            },
                            onClose: {
                                guard let index = tabManager.tabs.firstIndex(where: { $0.id == tab.id }) else {
                                    return
                                }
                                tabManager.closeTab(at: index)
                            }
                        )
                        .id(tab.id)
                        .contextMenu {
                            Button("Close") {
                                guard let index = tabManager.tabs.firstIndex(where: { $0.id == tab.id }) else {
                                    return
                                }
                                tabManager.closeTab(at: index)
                            }
                        }
                    }
                }
            }
            .onAppear {
                scrollToSelectedTab(using: proxy)
            }
            .onReceive(tabManager.$selectedTabIndex) { _ in
                scrollToSelectedTab(using: proxy)
            }
            .onReceive(tabManager.$tabs.map { $0.count }.removeDuplicates()) { _ in
                scrollToSelectedTab(using: proxy)
            }
        }
        .frame(height: 30)
        .background(themeManager.colors.tabBackground)
    }

    private func scrollToSelectedTab(using proxy: ScrollViewProxy) {
        guard tabManager.tabs.indices.contains(tabManager.selectedTabIndex) else { return }
        withAnimation {
            proxy.scrollTo(tabManager.tabs[tabManager.selectedTabIndex].id, anchor: .center)
        }
    }
}

struct TabItem: View {
    let name: String
    let isSelected: Bool
    let isEdited: Bool
    let themeColors: ThemeColors
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onSelect) {
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
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(name)\(isEdited ? ", edited" : "")")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(themeColors.tabText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(name)")
            .help("Close \(name)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? themeColors.tabSelected.opacity(0.2) : Color.clear)
        )
    }
}

// Line number gutter attached to an NSTextView's scroll view. It scrolls with
// the text, follows wrapped lines and widens automatically for 4+ digit numbers.
private final class LineNumberRulerView: NSRulerView {
    var numberFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    var numberColor = NSColor.secondaryLabelColor
    var gutterColor = NSColor.clear

    init(scrollView: NSScrollView, textView: NSTextView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44

        scrollView.contentView.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(contentChanged),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        center.addObserver(
            self,
            selector: #selector(contentChanged),
            name: NSText.didChangeNotification,
            object: textView
        )
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func contentChanged() {
        updateThickness()
        needsDisplay = true
    }

    func updateThickness() {
        guard let textView = clientView as? NSTextView else { return }
        let lineCount = Self.lineCount(in: textView.string)
        let digits = max(3, String(lineCount).count)
        let sample = String(repeating: "8", count: digits) as NSString
        let width = ceil(sample.size(withAttributes: [.font: numberFont]).width) + 20
        if abs(ruleThickness - width) > 0.5 {
            ruleThickness = width
        }
    }

    private static func lineCount(in text: String) -> Int {
        text.utf8.reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        gutterColor.setFill()
        bounds.fill()

        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let scrollView else { return }

        let text = textView.string as NSString
        let origin = textView.textContainerOrigin
        let visibleRect = scrollView.contentView.bounds
        let containerVisible = visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: numberFont,
            .foregroundColor: numberColor
        ]

        func drawNumber(_ number: Int, lineRect: NSRect) {
            let y = convert(NSPoint(x: 0, y: lineRect.minY + origin.y), from: textView).y
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(
                at: NSPoint(
                    x: bounds.width - size.width - 8,
                    y: y + (lineRect.height - size.height) / 2
                ),
                withAttributes: attributes
            )
        }

        let glyphRange = layoutManager.glyphRange(forBoundingRect: containerVisible, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let start = text.lineRange(
            for: NSRange(location: min(charRange.location, text.length), length: 0)
        ).location

        var lineNumber = Self.lineCount(in: text.substring(to: start))

        var location = start
        while location < text.length {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: lineRange.location)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            if lineRect.minY > containerVisible.maxY { return }
            drawNumber(lineNumber, lineRect: lineRect)
            lineNumber += 1
            location = NSMaxRange(lineRange)
        }

        // Empty document, or a document that ends with a line break.
        let extraRect = layoutManager.extraLineFragmentRect
        if !extraRect.isEmpty {
            drawNumber(lineNumber, lineRect: extraRect)
        }
    }
}

private struct HighlightedSyntaxEditor: NSViewRepresentable {
    @Binding var text: String
    let theme: ThemeManager.Theme
    let themeColors: ThemeColors
    let fontSize: CGFloat
    let language: String
    let lineNumberColor: NSColor
    @Environment(\.isPaneActive) private var isPaneActive

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
        textView.layoutManager?.allowsNonContiguousLayout = false
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
        // Always-visible scroll bar that can be dragged, even when the system
        // setting shows scroll bars only while scrolling.
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .legacy
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        scrollView.isHidden = !isPaneActive

        let ruler = LineNumberRulerView(scrollView: scrollView, textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        context.coordinator.ruler = ruler
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if scrollView.isHidden == isPaneActive {
            scrollView.isHidden = !isPaneActive
        }
        // NSScrollView switches back to overlay scrollers when the system
        // preference changes; keep the legacy (always visible) style.
        if scrollView.scrollerStyle != .legacy {
            scrollView.scrollerStyle = .legacy
        }
        // Draw the scroll bar for the app theme, not the system appearance;
        // otherwise a light knob is invisible on the light theme in Dark Mode.
        let appearanceName: NSAppearance.Name = theme == .light ? .aqua : .darkAqua
        if scrollView.appearance?.name != appearanceName {
            scrollView.appearance = NSAppearance(named: appearanceName)
        }
        let coordinator = context.coordinator
        coordinator.text = $text
        coordinator.highlighter.update(text: text, theme: theme, language: language)

        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let textColor = NSColor(themeColors.editorText)
        textView.font = font
        textView.textColor = textColor
        textView.insertionPointColor = textColor
        textView.backgroundColor = NSColor(themeColors.editorBackground)
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(themeColors.selection),
            .foregroundColor: textColor
        ]
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: textColor
        ]

        if let ruler = coordinator.ruler {
            ruler.numberFont = font
            ruler.numberColor = lineNumberColor
            ruler.gutterColor = textView.backgroundColor
        }
        // Runs on every exit path below, including the early returns.
        defer {
            coordinator.ruler?.updateThickness()
            coordinator.ruler?.needsDisplay = true
        }

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

        guard textView.string != formattedText.string else {
            guard let textStorage = textView.textStorage, formattedText.length > 0 else { return }

            textStorage.beginEditing()
            formattedText.enumerateAttributes(
                in: NSRange(location: 0, length: formattedText.length)
            ) { attributes, range, _ in
                var location = range.location
                let rangeEnd = NSMaxRange(range)

                while location < rangeEnd {
                    var currentRange = NSRange()
                    let currentAttributes = textStorage.attributes(
                        at: location,
                        effectiveRange: &currentRange
                    )
                    let updateEnd = min(rangeEnd, NSMaxRange(currentRange))
                    var changedAttributes: [NSAttributedString.Key: Any] = [:]

                    for key in [NSAttributedString.Key.font, .foregroundColor] {
                        let currentValue = currentAttributes[key] as? NSObject
                        let formattedValue = attributes[key] as? NSObject
                        guard currentValue?.isEqual(formattedValue) != true else { continue }
                        if let formattedValue = attributes[key] {
                            changedAttributes[key] = formattedValue
                        }
                    }

                    if !changedAttributes.isEmpty {
                        textStorage.addAttributes(
                            changedAttributes,
                            range: NSRange(location: location, length: updateEnd - location)
                        )
                    }
                    location = updateEnd
                }
            }
            textStorage.endEditing()
            return
        }

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
        var ruler: LineNumberRulerView?

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
    @State private var pendingReopen: ReopenEncodingRequest?

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
        let editor = HighlightedSyntaxEditor(
            text: textBinding,
            theme: themeManager.currentTheme,
            themeColors: themeManager.colors,
            fontSize: zoomState.fontSize,
            language: currentLanguage ?? "",
            lineNumberColor: NSColor(themeManager.colors.lineNumbers)
        )

        if #available(macOS 26.0, *) {
            editor.findNavigator(isPresented: $findState.isPresented)
        } else {
            editor
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            textEditor
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
                    .font(.system(size: 11))
                    .foregroundColor(themeManager.colors.tabText)

                Spacer()
                Menu {
                    Section("Reopen from Disk") {
                        ForEach(TextFileEncoding.allCases) { encoding in
                            Button(encoding.displayName) {
                                guard let tab = tabManager.getCurrentTab(),
                                      tab.fileURL != nil else { return }
                                if tab.isEdited {
                                    pendingReopen = ReopenEncodingRequest(
                                        tabID: tab.id,
                                        encoding: encoding
                                    )
                                } else {
                                    tabManager.reopenTab(id: tab.id, with: encoding)
                                }
                            }
                            .disabled(tabManager.getCurrentTab()?.fileURL == nil)
                        }
                    }

                    Section("Save to Disk") {
                        ForEach(TextFileEncoding.allCases) { encoding in
                            Button {
                                Task {
                                    await tabManager.saveCurrentTab(with: encoding)
                                }
                            } label: {
                                if currentEncoding == encoding {
                                    Label(encoding.displayName, systemImage: "checkmark")
                                } else {
                                    Text(encoding.displayName)
                                }
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
                .help("Reopen or save with a text encoding")

                Text("Words: \(wordCount)  |  Characters: \(characterCount)")
                    .font(.system(size: 11))
                    .foregroundColor(themeManager.colors.tabText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(themeManager.colors.tabBackground)
        }
        .background(themeManager.colors.editorBackground)
        .confirmationDialog(
            "Reopen with another encoding?",
            isPresented: Binding(
                get: { pendingReopen != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingReopen = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Reopen and Discard Changes", role: .destructive) {
                guard let request = pendingReopen else { return }
                tabManager.reopenTab(id: request.tabID, with: request.encoding)
                pendingReopen = nil
            }
            Button("Cancel", role: .cancel) {
                pendingReopen = nil
            }
        } message: {
            Text("This tab has unsaved changes. Reopening replaces them with the file contents.")
        }
    }

    private struct ReopenEncodingRequest {
        let tabID: UUID
        let encoding: TextFileEncoding
    }
}
