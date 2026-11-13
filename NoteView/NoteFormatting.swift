//  LightNote+
//
//  NoteFormatting.swift
//  Formatting requests and shared helpers for the note editor and preview.
//
// Created by mnrds
//

import SwiftUI
import Combine
import AppKit

// Formatting requests shared by the Markdown editor and preview.
enum NoteFormattingAction {
    case bold
    case italic
    case underline
    case strikethrough
    case title
    case separator
    case checklist
    case quote
    case link(url: String)
}

struct NoteFormattingRequest {
    let id = UUID()
    let documentID: String
    let action: NoteFormattingAction
}

@MainActor
final class NoteEditorFormatting: ObservableObject {
    @Published var request: NoteFormattingRequest?
    /// Document ID whose editor or preview should become first responder.
    @Published private(set) var focusRequest: String?

    func requestFocus(for documentID: String) {
        focusRequest = documentID
    }

    /// Moves keyboard focus to `textView` if focus was requested for `documentID`.
    /// Deferred so the view is in its window and no state is published mid-update.
    func applyFocusIfRequested(to textView: NSTextView, documentID: String) {
        guard focusRequest == documentID else { return }
        DispatchQueue.main.async { [weak self, weak textView] in
            guard let self, self.focusRequest == documentID,
                  let textView, let window = textView.window else { return }
            self.focusRequest = nil
            window.makeFirstResponder(textView)
        }
    }

    func perform(_ action: NoteFormattingAction, for documentID: String) {
        request = NoteFormattingRequest(documentID: documentID, action: action)
    }

    func claim(_ request: NoteFormattingRequest, for documentID: String) -> Bool {
        guard self.request?.id == request.id else { return false }
        guard request.documentID == documentID else {
            self.request = nil
            return false
        }
        self.request = nil
        return true
    }

    func cancel() {
        request = nil
    }
}

// Reads legacy spans for display; preview edits no longer write font-size spans.
enum NoteFontSizeMarkup {
    static let minimum: CGFloat = 8
    static let maximum: CGFloat = 72

    private static let tagExpression = try! NSRegularExpression(
        pattern: #"<span\s+style\s*=\s*["']\s*font-size\s*:\s*(\d+(?:\.\d+)?)px\s*;?\s*["']\s*>|</span>"#,
        options: [.caseInsensitive]
    )

    static func clamped(_ size: CGFloat) -> CGFloat {
        min(max(size, minimum), maximum)
    }

    static func matches(in source: String) -> [NSTextCheckingResult] {
        tagExpression.matches(
            in: source,
            range: NSRange(location: 0, length: (source as NSString).length)
        )
    }
}

enum NoteInlineWhitespace {
    static func split(_ text: String) -> (leading: String, content: String, trailing: String) {
        let contentStart = text.firstIndex(where: { !$0.isWhitespace }) ?? text.endIndex
        let contentEnd = text[contentStart...]
            .lastIndex(where: { !$0.isWhitespace })
            .map { text.index(after: $0) } ?? contentStart
        return (
            String(text[..<contentStart]),
            String(text[contentStart..<contentEnd]),
            String(text[contentEnd...])
        )
    }
}

// Nonisolated so the search index can decode notes on a background thread.
nonisolated enum NoteTextDecoder {
    static func decode(_ data: Data) -> String? {
        if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return decode(Data(data.dropFirst(4)), as: .utf32BigEndian)
        }
        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            return decode(Data(data.dropFirst(4)), as: .utf32LittleEndian)
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return decode(Data(data.dropFirst(3)), as: .utf8)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return decode(Data(data.dropFirst(2)), as: .utf16BigEndian)
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return decode(Data(data.dropFirst(2)), as: .utf16LittleEndian)
        }

        if let encoding = bomlessUTF32Encoding(for: data),
           let text = decode(data, as: encoding) {
            return text
        }
        if let encoding = bomlessUTF16Encoding(for: data),
           let text = decode(data, as: encoding) {
            return text
        }
        if let text = decode(data, as: .utf8) {
            return text
        }
        return decode(data, as: .windowsCP1252)
            ?? decode(data, as: .macOSRoman)
            ?? decode(data, as: .isoLatin1)
    }

    private static func decode(_ data: Data, as encoding: String.Encoding) -> String? {
        guard let text = String(data: data, encoding: encoding) else { return nil }
        return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    private static func bomlessUTF32Encoding(for data: Data) -> String.Encoding? {
        let bytes = Array(data)
        guard bytes.count >= 8, bytes.count.isMultiple(of: 4) else { return nil }
        let characterCount = bytes.count / 4
        var littleEndianZeroBytes = 0
        var bigEndianZeroBytes = 0
        for character in 0..<characterCount {
            let offset = character * 4
            littleEndianZeroBytes += (1...3).filter { bytes[offset + $0] == 0 }.count
            bigEndianZeroBytes += (0..<3).filter { bytes[offset + $0] == 0 }.count
        }
        if littleEndianZeroBytes >= characterCount * 2 {
            return .utf32LittleEndian
        }
        if bigEndianZeroBytes >= characterCount * 2 {
            return .utf32BigEndian
        }
        return nil
    }

    private static func bomlessUTF16Encoding(for data: Data) -> String.Encoding? {
        let bytes = Array(data)
        guard bytes.count >= 4, bytes.count.isMultiple(of: 2) else { return nil }
        let characterCount = bytes.count / 2
        let evenZeroBytes = stride(from: 0, to: bytes.count, by: 2)
            .filter { bytes[$0] == 0 }.count
        let oddZeroBytes = stride(from: 1, to: bytes.count, by: 2)
            .filter { bytes[$0] == 0 }.count
        if oddZeroBytes >= characterCount / 2 && oddZeroBytes > evenZeroBytes * 2 {
            return .utf16LittleEndian
        }
        if evenZeroBytes >= characterCount / 2 && evenZeroBytes > oddZeroBytes * 2 {
            return .utf16BigEndian
        }
        return nil
    }
}

enum NoteLinkURL {
    private static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    static func make(from input: String) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if let components = URLComponents(string: value), let scheme = components.scheme {
            switch scheme.lowercased() {
            case "mailto":
                return components.url
            case "http", "https":
                guard value.lowercased().hasPrefix("\(scheme.lowercased())://") else {
                    return nil
                }
                return components.url
            default:
                guard value.contains("://") else {
                    return URL(string: "https://\(value)")
                }
                return nil
            }
        }
        return URL(string: "https://\(value)")
    }

    static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return allowedSchemes.contains(scheme)
    }
}
