//
//  SyntaxHighlighter.swift
//  mac-txt-editor
//
//  Created by mnrds on 26.10.2026.
//

import SwiftUI
import Combine

final class SyntaxHighlighter: ObservableObject {
    @Published var highlightedText: NSAttributedString = NSAttributedString(string: "")

    private var currentText: String = ""
    private var currentTheme: ThemeManager.Theme = .light

    func update(text: String, theme: ThemeManager.Theme) {
        currentText = text
        currentTheme = theme
        highlightedText = highlight(text: text, theme: theme)
    }

    private func highlight(text: String, theme: ThemeManager.Theme) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text)

        let colors = getColors(for: theme)

        result.addAttribute(.foregroundColor, value: colors.text, range: NSRange(location: 0, length: text.count))

        return result
    }

    private func getColors(for theme: ThemeManager.Theme) -> (text: NSColor, keyword: NSColor, string: NSColor, comment: NSColor, number: NSColor) {
        switch theme {
        case .light:
            return (
                text: NSColor.black,
                keyword: NSColor.blue,
                string: NSColor.red,
                comment: NSColor.green,
                number: NSColor.purple
            )
        case .dark:
            return (
                text: NSColor.white,
                keyword: NSColor.systemBlue,
                string: NSColor.systemRed,
                comment: NSColor.systemGreen,
                number: NSColor.systemPurple
            )
        }
    }

    static func detectLanguage(from fileURL: URL?) -> String? {
        guard let url = fileURL else { return nil }
        let pathExtension = url.pathExtension.lowercased()

        switch pathExtension {
        case "swift": return "swift"
        case "py": return "python"
        case "html": return "html"
        case "css": return "css"
        case "js": return "javascript"
        case "php": return "php"
        default: return nil
        }
    }
}
