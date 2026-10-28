//
//  NotePadApp.swift
//  mac-txt-editor
//
//  Created by mnrds on 27.10.2026.
//

import SwiftUI

@main
struct SimpleNotepadApp: App {
    @StateObject private var themeManager = ThemeManager()
    @StateObject private var tabManager = TabManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(themeManager)
                .environmentObject(tabManager)
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
}
