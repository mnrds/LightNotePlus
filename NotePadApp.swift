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
    }
}
