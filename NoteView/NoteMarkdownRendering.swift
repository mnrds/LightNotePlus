//  LightNote+
//
//  NoteMarkdownRendering.swift
//  Markdown ⇄ attributed text conversion used by the preview.
//
// Created by mnrds
//

import SwiftUI
import AppKit

extension NoteMarkdownPreview {
    static func attributedInline(from markdown: String) -> NSMutableAttributedString {
        let output = NSMutableAttributedString()
        let strikeDelimiterPlaceholder = "\u{E000}\u{E000}"
        let protectedMarkdown = markdown.replacingOccurrences(
            of: "~~",
            with: strikeDelimiterPlaceholder
        )
        let source = protectedMarkdown as NSString
        let matches = NoteFontSizeMarkup.matches(in: markdown)
        var sizes: [CGFloat] = []
        var location = 0

        func appendMarkdown(_ range: NSRange, fontSize: CGFloat?) {
            guard range.length > 0 else { return }
            let segment = source.substring(with: range)
            let parsed = (try? AttributedString(
                markdown: segment,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(segment)
            let attributedSegment = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
            attributedSegment.mutableString.replaceOccurrences(
                of: strikeDelimiterPlaceholder,
                with: "~~",
                options: [],
                range: NSRange(location: 0, length: attributedSegment.length)
            )
            if let fontSize, attributedSegment.length > 0 {
                let fullRange = NSRange(location: 0, length: attributedSegment.length)
                attributedSegment.enumerateAttribute(.font, in: fullRange) { value, range, _ in
                    let oldFont = value as? NSFont ?? NSFont.systemFont(ofSize: 16)
                    let traits = NSFontManager.shared.traits(of: oldFont)
                    let resizedFont = NSFontManager.shared.convert(
                        NSFont.systemFont(ofSize: fontSize),
                        toHaveTrait: traits
                    )
                    attributedSegment.addAttributes(
                        [
                            .font: resizedFont,
                            .noteFontSize: fontSize
                        ],
                        range: range
                    )
                }
            }
            output.append(attributedSegment)
        }

        for match in matches {
            appendMarkdown(
                NSRange(location: location, length: match.range.location - location),
                fontSize: sizes.last
            )
            if match.range(at: 1).location != NSNotFound {
                let rawSize = source.substring(with: match.range(at: 1))
                if let size = Double(rawSize) {
                    sizes.append(NoteFontSizeMarkup.clamped(CGFloat(size)))
                }
            } else if !sizes.isEmpty {
                sizes.removeLast()
            } else {
                appendMarkdown(match.range, fontSize: nil)
            }
            location = NSMaxRange(match.range)
        }
        appendMarkdown(
            NSRange(location: location, length: source.length - location),
            fontSize: sizes.last
        )
        return output
    }

    static func attributedString(from markdown: String, textColor: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let baseFont = NSFont.systemFont(ofSize: 16)
        let blocks = parse(markdown)

        for (index, block) in blocks.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n"))
            }

            let rendered: NSMutableAttributedString
            if case .code = block.kind {
                rendered = NSMutableAttributedString(string: block.text.isEmpty ? "\u{200B}" : block.text)
            } else if case .divider = block.kind {
                rendered = NSMutableAttributedString(string: "\u{200B}")
            } else if case .blankLine = block.kind,
                      isQuoteContinuation(at: index, in: blocks) {
                rendered = NSMutableAttributedString(string: " ")
            } else {
                rendered = attributedInline(from: block.text)
            }
            switch block.kind {
            case .code:
                break
            default:
                applyInlineDecorations(to: rendered)
            }
            var markdownListPrefix: String?
            var visiblePrefix = ""
            switch block.kind {
            case .unorderedItem(let indent, let marker):
                markdownListPrefix = String(repeating: " ", count: indent * 2) + marker + " "
                visiblePrefix = String(repeating: "    ", count: indent) + "•  "
            case .checklistItem(let indent, let checked, let marker):
                markdownListPrefix = String(repeating: " ", count: indent * 2)
                    + marker + " "
                visiblePrefix = String(repeating: "    ", count: indent)
                    + (checked ? "☑  " : "☐  ")
            case .orderedItem(let indent, let number):
                markdownListPrefix = String(repeating: " ", count: indent * 2) + "\(number). "
                visiblePrefix = String(repeating: "    ", count: indent) + "\(number).  "
            case .quote:
                visiblePrefix = ""
            default:
                break
            }

            let inlineRange = NSRange(location: 0, length: rendered.length)
            rendered.enumerateAttribute(.inlinePresentationIntent, in: inlineRange) { value, range, _ in
                guard let rawIntent = value as? NSNumber, range.length > 0 else { return }
                let intent = InlinePresentationIntent(rawValue: rawIntent.uintValue)
                var traits: NSFontTraitMask = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
                if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
                let font = NSFontManager.shared.convert(baseFont, toHaveTrait: traits)
                rendered.addAttribute(.font, value: font, range: range)
            }
            rendered.enumerateAttribute(.link, in: inlineRange) { value, range, _ in
                guard let link = value, range.length > 0 else { return }
                rendered.addAttributes(
                    [
                        .link: link,
                        .foregroundColor: NSColor.systemBlue,
                        .underlineStyle: NSUnderlineStyle.single.rawValue
                    ],
                    range: range
                )
            }

            let paragraphKind: String
            let fontSize: CGFloat
            let headingLevel: Int?
            switch block.kind {
            case .heading(let level):
                paragraphKind = "heading"
                fontSize = headingSize(level)
                headingLevel = level
            case .paragraph:
                paragraphKind = "paragraph"
                fontSize = 16
                headingLevel = nil
            case .unorderedItem:
                paragraphKind = "unordered"
                fontSize = 16
                headingLevel = nil
            case .checklistItem(_, let checked, _):
                paragraphKind = "checklist"
                fontSize = 16
                headingLevel = nil
                rendered.addAttribute(
                    .noteChecklistChecked,
                    value: checked,
                    range: NSRange(location: 0, length: rendered.length)
                )
            case .orderedItem:
                paragraphKind = "ordered"
                fontSize = 16
                headingLevel = nil
            case .quote:
                paragraphKind = "quote"
                fontSize = 16
                headingLevel = nil
            case .code:
                paragraphKind = "code"
                fontSize = 13
                headingLevel = nil
            case .divider:
                paragraphKind = "divider"
                fontSize = 16
                headingLevel = nil
            case .blankLine:
                paragraphKind = "blankLine"
                fontSize = 16
                headingLevel = nil
            }

            if !visiblePrefix.isEmpty {
                rendered.insert(NSAttributedString(string: visiblePrefix), at: 0)
            }
            let fullRange = NSRange(location: 0, length: rendered.length)
            if rendered.length > 0 {
                if case .quote = block.kind {
                    let paragraphStyle = NSMutableParagraphStyle()
                    paragraphStyle.firstLineHeadIndent = quoteIndent
                    paragraphStyle.headIndent = quoteIndent
                    rendered.addAttributes(
                        [
                            .noteQuoteBackground: quoteBackground(for: textColor),
                            .paragraphStyle: paragraphStyle
                        ],
                        range: fullRange
                    )
                } else if case .blankLine = block.kind,
                          isQuoteContinuation(at: index, in: blocks) {
                    rendered.addAttribute(
                        .noteQuoteBackground,
                        value: quoteBackground(for: textColor),
                        range: fullRange
                    )
                }
                if !visiblePrefix.isEmpty {
                    rendered.addAttribute(
                        .noteVisiblePrefixLength,
                        value: (visiblePrefix as NSString).length,
                        range: fullRange
                    )
                }
                if let headingLevel {
                    rendered.addAttribute(.noteHeadingLevel, value: headingLevel, range: fullRange)
                }
                rendered.addAttribute(.noteParagraphKind, value: paragraphKind, range: fullRange)
                if case .checklistItem(_, let checked, _) = block.kind {
                    rendered.addAttribute(
                        .noteChecklistChecked,
                        value: checked,
                        range: fullRange
                    )
                }
                rendered.enumerateAttribute(.font, in: fullRange) { value, range, _ in
                    let oldFont = value as? NSFont ?? baseFont
                    let traits = NSFontManager.shared.traits(of: oldFont)
                    let requestedSize = rendered.attribute(
                        .noteFontSize,
                        at: range.location,
                        effectiveRange: nil
                    ) as? CGFloat ?? fontSize
                    var newFont = NSFont.systemFont(ofSize: requestedSize)
                    newFont = NSFontManager.shared.convert(newFont, toHaveTrait: traits)
                    if case .code = block.kind {
                        newFont = NSFont.monospacedSystemFont(ofSize: requestedSize, weight: .regular)
                    }
                    rendered.addAttribute(.font, value: newFont, range: range)
                }
                if case .checklistItem(let indent, _, _) = block.kind {
                    rendered.addAttribute(
                        .font,
                        value: NSFont.systemFont(ofSize: 23),
                        range: NSRange(location: indent * 4, length: 1)
                    )
                }
                rendered.addAttribute(.foregroundColor, value: textColor, range: fullRange)
                if let markdownListPrefix {
                    rendered.addAttribute(.noteListPrefix, value: markdownListPrefix, range: fullRange)
                }
            }
            result.append(rendered)
        }

        let finalLength = result.length
        if finalLength > 0 {
            let fullRange = NSRange(location: 0, length: finalLength)
            result.addAttribute(.foregroundColor, value: textColor, range: fullRange)
            result.enumerateAttribute(.link, in: fullRange) { link, range, _ in
                guard link != nil else { return }
                result.addAttributes(
                    [
                        .foregroundColor: NSColor.systemBlue,
                        .underlineStyle: NSUnderlineStyle.single.rawValue
                    ],
                    range: range
                )
            }
        }
        return result
    }

    static func isQuoteContinuation(
        at index: Int,
        in blocks: [NoteMarkdownBlock]
    ) -> Bool {
        guard case .blankLine = blocks[index].kind, index > 0 else { return false }

        var precedingIndex = index - 1
        while precedingIndex >= 0 {
            if case .blankLine = blocks[precedingIndex].kind {
                precedingIndex -= 1
                continue
            }
            if case .quote = blocks[precedingIndex].kind {
                return index - precedingIndex == 1
            }
            return false
        }
        return false
    }

    static func markdown(from attributedText: NSAttributedString) -> String {
        let source = attributedText.string as NSString
        guard source.length > 0 else { return "" }
        var lines: [String] = []
        var location = 0
        var isInsideCodeBlock = false

        while location < source.length {
            let fullLineRange = source.lineRange(for: NSRange(location: location, length: 0))
            let lineRange = NSRange(
                location: fullLineRange.location,
                length: max(0, fullLineRange.length - (source.substring(with: fullLineRange).hasSuffix("\n") ? 1 : 0))
            )
            let line = (source.substring(with: lineRange) as NSString)
            let attributes = lineRange.length > 0
                ? attributedText.attributes(at: lineRange.location, effectiveRange: nil)
                : [:]
            let kind = attributes[.noteParagraphKind] as? String
            let headingLevel = attributes[.noteHeadingLevel] as? Int
            let visiblePrefixLength = attributes[.noteVisiblePrefixLength] as? Int ?? 0
            let checklistChecked = attributes[.noteChecklistChecked] as? Bool ?? false
            if kind == "code", !isInsideCodeBlock {
                lines.append("```")
                isInsideCodeBlock = true
            } else if kind != "code", isInsideCodeBlock {
                lines.append("```")
                isInsideCodeBlock = false
            }
            var prefix = ""
            if let headingLevel {
                prefix = String(repeating: "#", count: headingLevel) + " "
            } else if kind == "quote" {
                prefix = "> "
            } else if kind == "checklist" {
                let marker = attributes[.noteListPrefix] as? String ?? "- "
                prefix = marker + (checklistChecked ? "[x] " : "[ ] ")
            } else if let listPrefix = attributes[.noteListPrefix] as? String {
                prefix = listPrefix
            } else if kind == "divider" {
                prefix = ""
            }

            let inlineRange = NSRange(
                location: min(lineRange.location + visiblePrefixLength, NSMaxRange(lineRange)),
                length: max(0, lineRange.length - visiblePrefixLength)
            )
            let inline = kind == "blankLine"
                ? ""
                : kind == "code"
                ? source.substring(with: lineRange).replacingOccurrences(of: "\u{200B}", with: "")
                : markdownInline(from: attributedText, range: inlineRange)
            lines.append(kind == "divider" ? "---" : (kind == "code" ? inline : prefix + inline))
            location = NSMaxRange(fullLineRange)
        }

        if isInsideCodeBlock {
            lines.append("```")
        }
        let markdown = lines.joined(separator: "\n")
        return source.hasSuffix("\n") ? markdown + "\n" : markdown
    }

    static func markdownInline(from text: NSAttributedString, range: NSRange) -> String {
        guard range.length > 0 else { return "" }
        var result = ""
        var currentRun: (
            style: (bold: Bool, italic: Bool),
            underline: Bool,
            strikethrough: Bool,
            link: String?,
            text: String
        )?

        func appendRun(_ run: (
            style: (bold: Bool, italic: Bool),
            underline: Bool,
            strikethrough: Bool,
            link: String?,
            text: String
        )) {
            let whitespace = NoteInlineWhitespace.split(run.text)
            guard !whitespace.content.isEmpty else {
                result += run.text
                return
            }
            var value = whitespace.content
            if run.underline { value = "<u>\(value)</u>" }
            if run.strikethrough { value = "~~\(value)~~" }
            if run.style.bold && run.style.italic { value = "***\(value)***" }
            else if run.style.bold { value = "**\(value)**" }
            else if run.style.italic { value = "*\(value)*" }
            if let link = run.link {
                value = "[\(value)](\(link))"
            }
            result += whitespace.leading + value + whitespace.trailing
        }

        text.enumerateAttributes(in: range) { attributes, subrange, _ in
            let font = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 16)
            let traits = NSFontManager.shared.traits(of: font)
            let style = (
                bold: traits.contains(.boldFontMask),
                italic: traits.contains(.italicFontMask)
            )
            let underline = attributes[.noteTextUnderline] as? Bool == true
            let strikethrough = attributes[.noteTextStrikethrough] as? Bool == true
            let string = (text.string as NSString).substring(with: subrange)
            let link = (attributes[.link] as? URL)?.absoluteString
                ?? attributes[.link] as? String
            if let run = currentRun,
               run.style.bold == style.bold,
               run.style.italic == style.italic,
               run.underline == underline,
               run.strikethrough == strikethrough,
               run.link == link {
                currentRun = (style, underline, strikethrough, link, run.text + string)
            } else {
                if let currentRun { appendRun(currentRun) }
                currentRun = (style, underline, strikethrough, link, string)
            }
        }
        if let currentRun { appendRun(currentRun) }
        return result
    }

    static func applyInlineDecorations(to text: NSMutableAttributedString) {
        let decorations: [(
            opening: String,
            closing: String,
            attribute: NSAttributedString.Key,
            value: Any,
            markerKey: NSAttributedString.Key
        )] = [
            ("<u>", "</u>", .underlineStyle, NSUnderlineStyle.single.rawValue, .noteTextUnderline),
            ("~~", "~~", .strikethroughStyle, NSUnderlineStyle.single.rawValue, .noteTextStrikethrough)
        ]
        for decoration in decorations {
            while true {
                let source = text.string as NSString
                let opening = source.range(of: decoration.opening)
                guard opening.location != NSNotFound else { break }
                let closingSearchRange = NSRange(
                    location: NSMaxRange(opening),
                    length: source.length - NSMaxRange(opening)
                )
                let closing = source.range(
                    of: decoration.closing,
                    options: [],
                    range: closingSearchRange
                )
                guard closing.location != NSNotFound,
                      closing.location > NSMaxRange(opening) else {
                    break
                }

                let decoratedRange = NSRange(
                    location: NSMaxRange(opening),
                    length: closing.location - NSMaxRange(opening)
                )
                text.addAttribute(
                    decoration.attribute,
                    value: decoration.value,
                    range: decoratedRange
                )
                text.addAttribute(decoration.markerKey, value: true, range: decoratedRange)
                text.deleteCharacters(in: closing)
                text.deleteCharacters(in: opening)
            }
        }
    }

    static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 30
        case 2: 25
        case 3: 21
        case 4: 18
        case 5: 16
        default: 14
        }
    }

    static func parse(_ markdown: String) -> [NoteMarkdownBlock] {
        let normalizedMarkdown = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalizedMarkdown.components(separatedBy: "\n")
        var blocks: [NoteMarkdownBlock] = []
        var paragraphLines: [String] = []
        var codeLines: [String] = []
        var isInCodeBlock = false
        var codeFence = ""

        func append(_ kind: NoteMarkdownBlock.Kind, _ text: String) {
            blocks.append(NoteMarkdownBlock(id: blocks.count, kind: kind, text: text))
        }

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            append(.paragraph, paragraphLines.joined(separator: "\n"))
            paragraphLines.removeAll()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if isInCodeBlock {
                if trimmed.hasPrefix(codeFence) {
                    append(.code, codeLines.joined(separator: "\n"))
                    codeLines.removeAll()
                    isInCodeBlock = false
                } else {
                    codeLines.append(line)
                }
                continue
            }

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                codeFence = String(trimmed.prefix(3))
                isInCodeBlock = true
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                append(.blankLine, "")
                continue
            }

            if let heading = match(trimmed, pattern: #"^(#{1,6})\s+(.+?)(?:\s+#+)?\s*$"#) {
                flushParagraph()
                append(.heading(level: heading[1].count), heading[2])
            } else if trimmed.range(
                of: #"^((\*\s*){3,}|(-\s*){3,}|(_\s*){3,})$"#,
                options: .regularExpression
            ) != nil {
                flushParagraph()
                append(.divider, "")
            } else if let quote = match(trimmed, pattern: #"^>\s?(.*)$"#) {
                flushParagraph()
                append(.quote, quote[1])
            } else if let item = match(line, pattern: #"^(\s*)([-+*])\s+\[([ xX])\]\s*(.*)$"#) {
                flushParagraph()
                append(
                    .checklistItem(
                        indent: item[1].count / 2,
                        checked: item[3].lowercased() == "x",
                        marker: item[2]
                    ),
                    item[4]
                )
            } else if let item = match(line, pattern: #"^(\s*)([-+*])\s+(.+)$"#) {
                flushParagraph()
                append(.unorderedItem(indent: item[1].count / 2, marker: item[2]), item[3])
            } else if let item = match(line, pattern: #"^(\s*)(\d+)[.)]\s+(.+)$"#) {
                flushParagraph()
                append(.orderedItem(indent: item[1].count / 2, number: item[2]), item[3])
            } else {
                paragraphLines.append(trimmed)
            }
        }

        flushParagraph()
        if isInCodeBlock {
            append(.code, codeLines.joined(separator: "\n"))
        }
        return blocks
    }

    static func match(_ string: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: string,
                range: NSRange(string.startIndex..., in: string)
              ) else {
            return nil
        }

        return (0..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: string) else { return nil }
            return String(string[range])
        }
    }
}
