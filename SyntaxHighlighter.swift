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

        if language == "html" || language == "xml" {
            highlightHTML(in: text as NSString, result: result, colors: colors)
        } else if language == "json" {
            highlightJSON(in: text as NSString, result: result, colors: colors)
        } else if language == "css" {
            highlightCSS(in: text as NSString, result: result, colors: colors)
        } else if language == "php"
                    || language == "javascript"
                    || language == "python"
                    || language == "swift" {
            highlightCode(
                in: text as NSString,
                result: result,
                language: language,
                colors: colors
            )
        }

        return result
    }

    private func highlightCode(
        in source: NSString,
        result: NSMutableAttributedString,
        language: String?,
        colors: (text: NSColor, keyword: NSColor, string: NSColor, comment: NSColor, number: NSColor)
    ) {
        let keywords: Set<String>
        if language == "php" {
            keywords = [
                "abstract", "and", "array", "as", "break", "callable", "case", "catch",
                "class", "clone", "const", "continue", "declare", "default", "do", "echo",
                "else", "elseif", "empty", "endfor", "endforeach", "endif", "endswitch",
                "endwhile", "enum", "extends", "final", "finally", "fn", "for", "foreach",
                "function", "global", "if", "implements", "include", "include_once",
                "instanceof", "interface", "isset", "list", "match", "namespace", "new",
                "or", "print", "private", "protected", "public", "readonly", "require",
                "require_once", "return", "static", "switch", "throw", "trait", "try",
                "unset", "use", "var", "while", "xor", "yield", "true", "false", "null"
            ]
        } else if language == "python" {
            keywords = [
                "False", "None", "True", "and", "as", "assert", "async", "await", "break",
                "case", "class", "continue", "def", "del", "elif", "else", "except", "finally",
                "for", "from", "global", "if", "import", "in", "is", "lambda", "match",
                "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with",
                "yield"
            ]
        } else if language == "swift" {
            keywords = [
                "actor", "associatedtype", "async", "await", "break", "case", "catch",
                "class", "continue", "default", "defer", "deinit", "do", "else", "enum",
                "extension", "fallthrough", "false", "for", "func", "guard", "if", "import",
                "in", "init", "inout", "internal", "let", "nil", "operator", "private",
                "protocol", "public", "repeat", "return", "self", "static", "struct",
                "subscript", "super", "switch", "throw", "throws", "true", "try", "var",
                "where", "while"
            ]
        } else {
            keywords = [
                "async", "await", "break", "case", "catch", "class", "const", "continue",
                "debugger", "default", "delete", "do", "else", "export", "extends", "false",
                "finally", "for", "from", "function", "if", "import", "in", "instanceof",
                "let", "new", "null", "of", "return", "static", "super", "switch", "this",
                "throw", "true", "try", "typeof", "undefined", "var", "void", "while", "with",
                "yield"
            ]
        }

        var index = 0
        let length = source.length
        var inPHP = language != "php"
        while index < length {
            if language == "php", !inPHP {
                guard let openingTag = nextPHPOpeningTag(in: source, from: index) else {
                    highlightHTMLSegment(
                        in: source,
                        range: NSRange(location: index, length: length - index),
                        result: result,
                        colors: colors
                    )
                    break
                }
                highlightHTMLSegment(
                    in: source,
                    range: NSRange(location: index, length: openingTag - index),
                    result: result,
                    colors: colors
                )
                index = openingTag
                inPHP = true
                continue
            }

            let character = source.character(at: index)

            if language == "php",
               character == 60,
               index + 1 < length,
               source.character(at: index + 1) == 63 {
                let tagStart = index
                if index + 4 < length,
                   source.substring(with: NSRange(location: index, length: 5)).lowercased() == "<?php" {
                    index += 5
                } else if index + 2 < length, source.character(at: index + 2) == 61 {
                    index += 3
                } else {
                    index += 2
                }
                result.addAttribute(
                    .foregroundColor,
                    value: colors.keyword,
                    range: NSRange(location: tagStart, length: index - tagStart)
                )
                inPHP = true
                continue
            }

            if (language != "python"
                && character == 47
                && index + 1 < length
                && source.character(at: index + 1) == 47)
                || (language == "php"
                    && character == 35
                    && !(index + 1 < length && source.character(at: index + 1) == 91))
                || (language == "python" && character == 35) {
                let commentStart = index
                while index < length,
                      source.character(at: index) != 10,
                      source.character(at: index) != 13 {
                    index += 1
                }
                result.addAttribute(
                    .foregroundColor,
                    value: colors.comment,
                    range: NSRange(location: commentStart, length: index - commentStart)
                )
                continue
            }

            if language == "php",
               character == 63,
               index + 1 < length,
               source.character(at: index + 1) == 62 {
                result.addAttribute(
                    .foregroundColor,
                    value: colors.keyword,
                    range: NSRange(location: index, length: 2)
                )
                inPHP = false
                index += 2
                continue
            }

            if language != "python",
               character == 47,
               index + 1 < length,
               source.character(at: index + 1) == 42 {
                let commentStart = index
                index += 2
                while index + 1 < length,
                      !(source.character(at: index) == 42 && source.character(at: index + 1) == 47) {
                    index += 1
                }
                index = min(index + 2, length)
                result.addAttribute(
                    .foregroundColor,
                    value: colors.comment,
                    range: NSRange(location: commentStart, length: index - commentStart)
                )
                continue
            }

            if language == "python",
               (character == 34 || character == 39),
               index + 2 < length,
               source.character(at: index + 1) == character,
               source.character(at: index + 2) == character {
                let stringStart = index
                index += 3
                var isTerminated = false
                while index + 2 < length {
                    if source.character(at: index) == 92 {
                        index = min(index + 2, length)
                    } else if source.character(at: index) == character,
                              source.character(at: index + 1) == character,
                              source.character(at: index + 2) == character {
                        index += 3
                        isTerminated = true
                        break
                    } else {
                        index += 1
                    }
                }
                if !isTerminated { index = length }
                result.addAttribute(
                    .foregroundColor,
                    value: colors.string,
                    range: NSRange(location: stringStart, length: index - stringStart)
                )
                continue
            }

            if character == 34
                || character == 39
                || (language == "javascript" && character == 96) {
                let stringStart = index
                let quote = character
                index += 1
                while index < length {
                    if source.character(at: index) == 92 {
                        index = min(index + 2, length)
                    } else if source.character(at: index) == quote {
                        index += 1
                        break
                    } else if source.character(at: index) == 10,
                              quote != 96,
                              language != "php" {
                        break
                    } else {
                        index += 1
                    }
                }
                result.addAttribute(
                    .foregroundColor,
                    value: colors.string,
                    range: NSRange(location: stringStart, length: index - stringStart)
                )
                continue
            }

            if (48...57).contains(character)
                || character == 46
                    && index + 1 < length
                    && (48...57).contains(source.character(at: index + 1)) {
                let numberStart = index
                index += 1
                while index < length {
                    let next = source.character(at: index)
                    guard isCodeIdentifierCharacter(next) || next == 46 else { break }
                    index += 1
                }
                result.addAttribute(
                    .foregroundColor,
                    value: colors.number,
                    range: NSRange(location: numberStart, length: index - numberStart)
                )
                continue
            }

            if isCodeIdentifierStart(character) {
                let identifierStart = index
                index += 1
                while index < length, isCodeIdentifierCharacter(source.character(at: index)) {
                    index += 1
                }
                let identifier = source.substring(
                    with: NSRange(location: identifierStart, length: index - identifierStart)
                )
                let keyword = language == "php" ? identifier.lowercased() : identifier
                if keywords.contains(keyword) {
                    result.addAttribute(
                        .foregroundColor,
                        value: colors.keyword,
                        range: NSRange(location: identifierStart, length: index - identifierStart)
                    )
                }
                continue
            }

            index += 1
        }
    }

    private func nextPHPOpeningTag(in source: NSString, from start: Int) -> Int? {
        guard start < source.length else { return nil }
        var index = start
        while index + 1 < source.length {
            guard source.character(at: index) == 60,
                  source.character(at: index + 1) == 63 else {
                index += 1
                continue
            }

            if index + 4 < source.length,
               source.substring(with: NSRange(location: index, length: 5)).lowercased() == "<?php" {
                return index
            }
            if index + 2 < source.length, source.character(at: index + 2) == 61 {
                return index
            }
            return index
        }
        return nil
    }

    private func highlightHTMLSegment(
        in source: NSString,
        range: NSRange,
        result: NSMutableAttributedString,
        colors: (text: NSColor, keyword: NSColor, string: NSColor, comment: NSColor, number: NSColor)
    ) {
        guard range.length > 0 else { return }
        let segmentString = source.substring(with: range)
        let segment = NSMutableAttributedString(string: segmentString)
        segment.addAttribute(
            .foregroundColor,
            value: colors.text,
            range: NSRange(location: 0, length: segment.length)
        )
        highlightHTML(in: segmentString as NSString, result: segment, colors: colors)
        segment.enumerateAttribute(
            .foregroundColor,
            in: NSRange(location: 0, length: segment.length)
        ) { color, segmentRange, _ in
            guard let color else { return }
            result.addAttribute(
                .foregroundColor,
                value: color,
                range: NSRange(
                    location: range.location + segmentRange.location,
                    length: segmentRange.length
                )
            )
        }
    }

    private func isCodeIdentifierStart(_ character: unichar) -> Bool {
        (65...90).contains(character)
            || (97...122).contains(character)
            || character == 95
            || character == 36
    }

    private func isCodeIdentifierCharacter(_ character: unichar) -> Bool {
        isCodeIdentifierStart(character) || (48...57).contains(character)
    }

    private func highlightJSON(
        in source: NSString,
        result: NSMutableAttributedString,
        colors: (text: NSColor, keyword: NSColor, string: NSColor, comment: NSColor, number: NSColor)
    ) {
        var index = 0
        while index < source.length {
            let character = source.character(at: index)
            if character == 34 {
                let stringStart = index
                index += 1
                while index < source.length {
                    if source.character(at: index) == 92 {
                        index = min(index + 2, source.length)
                    } else if source.character(at: index) == 34 {
                        index += 1
                        break
                    } else {
                        index += 1
                    }
                }
                result.addAttribute(
                    .foregroundColor,
                    value: colors.string,
                    range: NSRange(location: stringStart, length: index - stringStart)
                )
            } else if (48...57).contains(character) || character == 45 {
                let numberStart = index
                index += 1
                while index < source.length {
                    let next = source.character(at: index)
                    guard (48...57).contains(next) || [45, 46, 69, 101, 43].contains(next) else {
                        break
                    }
                    index += 1
                }
                result.addAttribute(
                    .foregroundColor,
                    value: colors.number,
                    range: NSRange(location: numberStart, length: index - numberStart)
                )
            } else if isCodeIdentifierStart(character) {
                let identifierStart = index
                index += 1
                while index < source.length,
                      isCodeIdentifierCharacter(source.character(at: index)) {
                    index += 1
                }
                let identifier = source.substring(
                    with: NSRange(location: identifierStart, length: index - identifierStart)
                )
                if ["true", "false", "null"].contains(identifier) {
                    result.addAttribute(
                        .foregroundColor,
                        value: colors.keyword,
                        range: NSRange(location: identifierStart, length: index - identifierStart)
                    )
                }
            } else {
                index += 1
            }
        }
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
        let colors = ThemeManager.colors(for: theme)
        return (
            text: NSColor(colors.editorText),
            keyword: NSColor(colors.syntaxKeyword),
            string: NSColor(colors.syntaxString),
            comment: NSColor(colors.syntaxComment),
            number: NSColor(colors.syntaxNumber)
        )
    }

    static func detectLanguage(from fileURL: URL?) -> String? {
        guard let url = fileURL else { return nil }
        let pathExtension = url.pathExtension.lowercased()

        switch pathExtension {
        case "swift": return "swift"
        case "py": return "python"
        case "html", "htm", "xhtml": return "html"
        case "css": return "css"
        case "js", "ts": return "javascript"
        case "php": return "php"
        case "json": return "json"
        case "md", "markdown": return "markdown"
        case "xml": return "xml"
        default: return nil
        }
    }
}
