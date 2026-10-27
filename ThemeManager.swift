//
//  ThemeManager.swift
//  mac-txt-editor
//
//  Created by mnrds on 27.10.2026.
//

import SwiftUI
import Combine
import Foundation

final class ThemeManager: ObservableObject {
    @Published var currentTheme: Theme = .light

    enum Theme: String, CaseIterable {
        case light
        case dark
    }

    func toggleTheme() {
        currentTheme = currentTheme == .light ? .dark : .light
    }

    var colors: ThemeColors {
        switch currentTheme {
        case .light:
            return ThemeColors(
                background: .white,
                text: .black,
                tabBackground: Color(white: 0.95),
                tabText: .black,
                tabSelected: .blue,
                editorBackground: .white,
                editorText: .black,
                lineNumbers: Color(white: 0.7),
                selection: Color.blue.opacity(0.3)
            )
        case .dark:
            return ThemeColors(
                background: Color(red: 0.15, green: 0.15, blue: 0.18),
                text: .white,
                tabBackground: Color(red: 0.25, green: 0.25, blue: 0.28),
                tabText: .white,
                tabSelected: .blue,
                editorBackground: Color(red: 0.1, green: 0.1, blue: 0.12),
                editorText: .white,
                lineNumbers: Color(white: 0.4),
                selection: Color.blue.opacity(0.4)
            )
        }
    }
}

struct ThemeColors {
    let background: Color
    let text: Color
    let tabBackground: Color
    let tabText: Color
    let tabSelected: Color
    let editorBackground: Color
    let editorText: Color
    let lineNumbers: Color
    let selection: Color
}
