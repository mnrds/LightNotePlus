//
//  ThemeManager.swift
//  LightNote+
//
//  Created by mnrds 
//

import SwiftUI
import Combine
import Foundation

final class ThemeManager: ObservableObject {
    @Published var currentTheme: Theme {
        didSet {
            UserDefaults.standard.set(currentTheme.rawValue, forKey: Self.themeStorageKey)
        }
    }

    private static let themeStorageKey = "selectedTheme"

    enum Theme: String, CaseIterable {
        case light
        case dark
    }

    init() {
        currentTheme = UserDefaults.standard.string(forKey: Self.themeStorageKey)
            .flatMap(Theme.init(rawValue:)) ?? .light
    }

    func toggleTheme() {
        currentTheme = currentTheme == .light ? .dark : .light
    }

    var colors: ThemeColors {
        Self.colors(for: currentTheme)
    }

    static func colors(for theme: Theme) -> ThemeColors {
        switch theme {
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
                selection: Color.blue.opacity(0.3),
                syntaxKeyword: .blue,
                syntaxString: .red,
                syntaxComment: Color(red: 0.0, green: 0.42, blue: 0.12),
                syntaxNumber: .purple
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
                selection: Color.blue.opacity(0.4),
                syntaxKeyword: .cyan,
                syntaxString: .orange,
                syntaxComment: Color(red: 0.45, green: 0.78, blue: 0.48),
                syntaxNumber: .purple
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
    let syntaxKeyword: Color
    let syntaxString: Color
    let syntaxComment: Color
    let syntaxNumber: Color
}
