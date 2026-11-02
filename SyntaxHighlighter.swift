//
//  SyntaxHighlighter.swift
//  LightNote+
//
//  Created by mnrds 
//

import SwiftUI
import Combine

final class SyntaxHighlighter: ObservableObject {
    @Published var highlightedText: NSAttributedString = NSAttributedString(string: "")

    private var currentText: String = ""
    private var currentTheme: ThemeManager.Theme = .light

    func update(text: String, theme: ThemeManager.Theme, language: String? = nil) {
        currentText = text
        currentTheme = theme
        highlightedText = highlight(text: text, theme: theme, language: language)
    }

    private func highlight(
        text: String,
        theme: ThemeManager.Theme,
        language: String?
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text)
        let colors = getColors(for: theme)
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        result.addAttribute(.foregroundColor, value: colors.text, range: fullRange)

        if language == "html" {
            highlightHTML(in: text as NSString, result: result, colors: colors)
        } else if language == "css" {
            highlightCSS(in: text as NSString, result: result, colors: colors)
        }

        return result
    }

    private func highlightCSS(
        in source: NSString,
        result: NSMutableAttributedString,
        colors: (text: NSColor, keyword: NSColor, string: NSColor, comment: NSColor, number: NSColor)
    ) {
        var index = 0
        var segmentStart = 0
        var braceDepth = 0
        var highlightedTokens: [(range: NSRange, color: NSColor)] = []
        let length = source.length

        while index < length {
            let character = source.character(at: index)

            if character == 47, index + 1 < length, source.character(at: index + 1) == 42 {
                let commentStart = index
                index += 2
                while index + 1 < length,
                      !(source.character(at: index) == 42 && source.character(at: index + 1) == 47) {
                    index += 1
                }
                index = min(index + 2, length)
                highlightedTokens.append((
                    NSRange(location: commentStart, length: index - commentStart),
                    colors.comment
                ))
                continue
            }

            if character == 34 || character == 39 {
                let quote = character
                let stringStart = index
                index += 1
                while index < length {
                    if source.character(at: index) == 92 {
                        index = min(index + 2, length)
                    } else if source.character(at: index) == quote {
                        index += 1
                        break
                    } else {
                        index += 1
                    }
                }
                highlightedTokens.append((
                    NSRange(location: stringStart, length: index - stringStart),
                    colors.string
                ))
                continue
            }

            if character == 64 {
                let atRuleStart = index
                index += 1
                while index < length, isCSSNameCharacter(source.character(at: index)) {
                    index += 1
                }
                if index > atRuleStart + 1 {
                    highlightedTokens.append((
                        NSRange(location: atRuleStart, length: index - atRuleStart),
                        colors.keyword
                    ))
                }
                continue
            }

            if (48...57).contains(character)
                || (character == 46 && index + 1 < length && (48...57).contains(source.character(at: index + 1)))
                || (character == 35 && index + 1 < length && isCSSHexDigit(source.character(at: index + 1))) {
                let numberStart = index
                index += 1
                while index < length {
                    let next = source.character(at: index)
                    guard isCSSNameCharacter(next) || next == 37 else { break }
                    index += 1
                }
                highlightedTokens.append((
                    NSRange(location: numberStart, length: index - numberStart),
                    colors.number
                ))
                continue
            }

            if character == 123 {
                if index > segmentStart {
                    result.addAttribute(
                        .foregroundColor,
                        value: colors.keyword,
                        range: NSRange(location: segmentStart, length: index - segmentStart)
                    )
                }
                braceDepth += 1
                segmentStart = index + 1
            } else if character == 59 {
                if braceDepth > 0 {
                    highlightCSSDeclaration(
                        in: source,
                        range: NSRange(location: segmentStart, length: index - segmentStart),
                        result: result,
                        color: colors.keyword
                    )
                }
                segmentStart = index + 1
            } else if character == 125 {
                if braceDepth > 0 {
                    highlightCSSDeclaration(
                        in: source,
                        range: NSRange(location: segmentStart, length: index - segmentStart),
                        result: result,
                        color: colors.keyword
                    )
                    braceDepth -= 1
                }
                segmentStart = index + 1
            }

            index += 1
        }

        if braceDepth > 0 {
            highlightCSSDeclaration(
                in: source,
                range: NSRange(location: segmentStart, length: length - segmentStart),
                result: result,
                color: colors.keyword
            )
        }

        for token in highlightedTokens {
            result.addAttribute(.foregroundColor, value: token.color, range: token.range)
        }
    }

    private func highlightCSSDeclaration(
        in source: NSString,
        range: NSRange,
        result: NSMutableAttributedString,
        color: NSColor
    ) {
        let end = NSMaxRange(range)
        var colon = range.location
        while colon < end {
            if source.character(at: colon) == 47,
               colon + 1 < end,
               source.character(at: colon + 1) == 42 {
                colon += 2
                while colon + 1 < end,
                      !(source.character(at: colon) == 42 && source.character(at: colon + 1) == 47) {
                    colon += 1
                }
                colon = min(colon + 2, end)
                continue
            }
            if source.character(at: colon) == 58 { break }
            colon += 1
        }
        guard colon < end else { return }

        var propertyStart = range.location
        while propertyStart < colon, isCSSWhitespace(source.character(at: propertyStart)) {
            propertyStart += 1
        }
        while propertyStart + 1 < colon,
              source.character(at: propertyStart) == 47,
              source.character(at: propertyStart + 1) == 42 {
            propertyStart += 2
            while propertyStart + 1 < colon,
                  !(source.character(at: propertyStart) == 42 && source.character(at: propertyStart + 1) == 47) {
                propertyStart += 1
            }
            propertyStart = min(propertyStart + 2, colon)
            while propertyStart < colon, isCSSWhitespace(source.character(at: propertyStart)) {
                propertyStart += 1
            }
        }
        var propertyEnd = colon
        while propertyStart < propertyEnd, isCSSWhitespace(source.character(at: propertyStart)) {
            propertyStart += 1
        }
        while propertyEnd > propertyStart, isCSSWhitespace(source.character(at: propertyEnd - 1)) {
            propertyEnd -= 1
        }
        guard propertyStart < propertyEnd else { return }

        for index in propertyStart..<propertyEnd {
            let character = source.character(at: index)
            guard isCSSNameCharacter(character) else { return }
        }

        result.addAttribute(
            .foregroundColor,
            value: color,
            range: NSRange(location: propertyStart, length: propertyEnd - propertyStart)
        )
    }

    private func isCSSWhitespace(_ character: unichar) -> Bool {
        character == 32 || character == 9 || character == 10 || character == 13
    }

    private func isCSSNameCharacter(_ character: unichar) -> Bool {
        (65...90).contains(character)
            || (97...122).contains(character)
            || (48...57).contains(character)
            || character == 45
            || character == 95
    }

    private func isCSSHexDigit(_ character: unichar) -> Bool {
        (48...57).contains(character)
            || (65...70).contains(character)
            || (97...102).contains(character)
    }

    private func highlightHTML(
        in source: NSString,
        result: NSMutableAttributedString,
        colors: (text: NSColor, keyword: NSColor, string: NSColor, comment: NSColor, number: NSColor)
    ) {
        let length = source.length
        var index = 0

        while index < length {
            guard source.character(at: index) == 60 else {
                index += 1
                continue
            }

            if index + 4 <= length,
               source.substring(with: NSRange(location: index, length: 4)) == "<!--" {
                let commentStart = index
                let searchRange = NSRange(location: index + 4, length: length - index - 4)
                let closingRange = source.range(of: "-->", options: [], range: searchRange)
                index = closingRange.location == NSNotFound
                    ? length
                    : NSMaxRange(closingRange)
                result.addAttribute(
                    .foregroundColor,
                    value: colors.comment,
                    range: NSRange(location: commentStart, length: index - commentStart)
                )
                continue
            }

            guard let tagEnd = closingTagEnd(in: source, from: index) else {
                index += 1
                continue
            }

            let tagRange = NSRange(location: index, length: tagEnd - index + 1)
            result.addAttribute(.foregroundColor, value: colors.keyword, range: tagRange)
            highlightAttributes(in: source, tagRange: tagRange, result: result, colors: colors)
            index = tagEnd + 1
        }
    }

    private func closingTagEnd(in source: NSString, from start: Int) -> Int? {
        var quote: unichar?
        var index = start + 1

        while index < source.length {
            let character = source.character(at: index)
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                }
            } else if character == 34 || character == 39 {
                quote = character
            } else if character == 62 {
                return index
            } else if character == 60 {
                return nil
            }
            index += 1
        }

        return nil
    }

    private func highlightAttributes(
        in source: NSString,
        tagRange: NSRange,
        result: NSMutableAttributedString,
        colors: (text: NSColor, keyword: NSColor, string: NSColor, comment: NSColor, number: NSColor)
    ) {
        var index = tagRange.location + 1
        let end = NSMaxRange(tagRange) - 1

        if index < end, source.character(at: index) == 47 {
            index += 1
        }

        guard index < end,
              isHTMLNameStart(source.character(at: index)) else {
            return
        }

        while index < end, isHTMLNameCharacter(source.character(at: index)) {
            index += 1
        }

        while index < end {
            while index < end, isHTMLWhitespace(source.character(at: index)) || source.character(at: index) == 47 {
                index += 1
            }

            let nameStart = index
            while index < end, isHTMLNameCharacter(source.character(at: index)) {
                index += 1
            }

            guard index > nameStart else {
                index += 1
                continue
            }

            result.addAttribute(
                .foregroundColor,
                value: colors.number,
                range: NSRange(location: nameStart, length: index - nameStart)
            )

            while index < end, isHTMLWhitespace(source.character(at: index)) {
                index += 1
            }

            guard index < end, source.character(at: index) == 61 else {
                continue
            }
            index += 1

            while index < end, isHTMLWhitespace(source.character(at: index)) {
                index += 1
            }

            guard index < end else { continue }
            let valueStart = index
            let quote = source.character(at: index)

            if quote == 34 || quote == 39 {
                index += 1
                while index < end, source.character(at: index) != quote {
                    index += 1
                }
                if index < end {
                    index += 1
                }
            } else {
                while index < end,
                      !isHTMLWhitespace(source.character(at: index)) {
                    index += 1
                }
            }

            result.addAttribute(
                .foregroundColor,
                value: colors.string,
                range: NSRange(location: valueStart, length: index - valueStart)
            )
        }
    }

    private func isHTMLWhitespace(_ character: unichar) -> Bool {
        character == 32 || character == 9 || character == 10 || character == 13
    }

    private func isHTMLNameStart(_ character: unichar) -> Bool {
        (65...90).contains(character) || (97...122).contains(character) || character == 95 || character == 58
    }

    private func isHTMLNameCharacter(_ character: unichar) -> Bool {
        isHTMLNameStart(character)
            || (48...57).contains(character)
            || character == 45
            || character == 46
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
        case "html", "htm", "xhtml": return "html"
        case "css": return "css"
        case "js": return "javascript"
        case "php": return "php"
        default: return nil
        }
    }
}
