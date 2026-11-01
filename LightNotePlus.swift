//
//  LightNotePlus.swift
//  Notepad App
//
//  Created by mnrds 
//

import SwiftUI
import Combine

final class FindState: ObservableObject {
    @Published var isPresented = false
}

final class ZoomState: ObservableObject {
    @Published private(set) var fontSize: CGFloat = 12

    func zoomIn() {
        fontSize = min(fontSize + 2, 48)
    }

    func zoomOut() {
        fontSize = max(fontSize - 2, 8)
    }

    func reset() {
        fontSize = 12
    }
}

@main
struct SimpleNotepadApp: App {
    @StateObject private var themeManager = ThemeManager()
    @StateObject private var tabManager = TabManager()
    @StateObject private var findState = FindState()
    @StateObject private var zoomState = ZoomState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(themeManager)
                .environmentObject(tabManager)
                .environmentObject(findState)
                .environmentObject(zoomState)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open…") {
                    Task { await tabManager.openFile() }
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            CommandGroup(after: .pasteboard) {
                Button("Indent Selection") {
                    IndentSelectionCommand.perform()
                }
                .keyboardShortcut("]", modifiers: .command)
            }

            CommandGroup(after: .textEditing) {
                Button("Find…") {
                    findState.isPresented = true
                }
                .keyboardShortcut("f", modifiers: .command)
            }

            CommandGroup(after: .toolbar) {
                Button("Zoom In") {
                    zoomState.zoomIn()
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Zoom Out") {
                    zoomState.zoomOut()
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Actual Size") {
                    zoomState.reset()
                }
                .keyboardShortcut("0", modifiers: .command)
            }

            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    Task { await tabManager.saveCurrentTab() }
                }
                .keyboardShortcut("s", modifiers: .command)

                Button("Save As…") {
                    Task { await tabManager.saveCurrentTabAs() }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }
    }

    private enum IndentSelectionCommand {
        static func perform() {
            guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else { return }

            let content = textView.string as NSString
            let selection = textView.selectedRange()
            guard selection.location != NSNotFound,
                  selection.location <= content.length else { return }

            let selectionEnd = min(NSMaxRange(selection), content.length)
            var lastSelectedCharacter = selectionEnd
            if selection.length > 0,
               lastSelectedCharacter > selection.location,
               content.character(at: lastSelectedCharacter - 1) == 10 {
                lastSelectedCharacter -= 1
            }

            let firstLineRange = content.lineRange(
                for: NSRange(location: selection.location, length: 0)
            )
            let lastLineRange = content.lineRange(
                for: NSRange(location: lastSelectedCharacter, length: 0)
            )
            let linesRange = NSRange(
                location: firstLineRange.location,
                length: NSMaxRange(lastLineRange) - firstLineRange.location
            )
            let replacement = NSMutableString(
                string: content.substring(with: linesRange)
            )

            var lineStarts = [firstLineRange.location]
            var lineRange = firstLineRange
            while NSMaxRange(lineRange) < NSMaxRange(linesRange) {
                lineRange = content.lineRange(
                    for: NSRange(location: NSMaxRange(lineRange), length: 0)
                )
                lineStarts.append(lineRange.location)
            }

            for lineStart in lineStarts.reversed() {
                replacement.insert("    ", at: lineStart - linesRange.location)
            }

            textView.insertText(replacement, replacementRange: linesRange)
            textView.setSelectedRange(
                NSRange(location: linesRange.location, length: replacement.length)
            )
        }
    }
}
