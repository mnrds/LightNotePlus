//  LightNote+
//
//  Search tool for NoteView.swift searching text in the note.
//

import SwiftUI
import Combine
import AppKit

enum NoteSearchDirection {
    case previous
    case next
}

struct NoteSearchRequest {
    let id = UUID()
    let query: String
    let direction: NoteSearchDirection
    let startsAtBeginning: Bool
}

@MainActor
final class NoteSearchModel: ObservableObject {
    @Published var isPresented = false
    @Published var query = ""
    @Published private(set) var request: NoteSearchRequest?
    @Published private(set) var matchCount = 0
    @Published private(set) var selectedMatch = 0

    var statusText: String {
        guard !query.isEmpty else { return "" }
        guard matchCount > 0 else { return "No Matches" }
        return "\(selectedMatch) of \(matchCount)"
    }

    func present() {
        isPresented = true
        if !query.isEmpty {
            searchFromBeginning()
        }
    }

    func close() {
        isPresented = false
        query = ""
        request = NoteSearchRequest(
            query: "",
            direction: .next,
            startsAtBeginning: true
        )
        report(matches: [], selectedMatch: nil)
    }

    func updateQuery() {
        requestSearch(direction: .next, startsAtBeginning: true)
    }

    func searchFromBeginning() {
        requestSearch(direction: .next, startsAtBeginning: true)
    }

    func findNext() {
        requestSearch(direction: .next, startsAtBeginning: false)
    }

    func findPrevious() {
        requestSearch(direction: .previous, startsAtBeginning: false)
    }

    func search(_ request: NoteSearchRequest, in textView: NSTextView) {
        guard !request.query.isEmpty else {
            report(matches: [], selectedMatch: nil)
            return
        }

        let source = textView.string as NSString
        var matches: [NSRange] = []
        var searchLocation = 0
        while searchLocation < source.length {
            let searchRange = NSRange(
                location: searchLocation,
                length: source.length - searchLocation
            )
            let match = source.range(
                of: request.query,
                options: [.caseInsensitive],
                range: searchRange
            )
            guard match.location != NSNotFound else { break }
            matches.append(match)
            searchLocation = NSMaxRange(match)
        }

        guard !matches.isEmpty else {
            report(matches: [], selectedMatch: nil)
            return
        }

        let selection = textView.selectedRange()
        let currentMatch = matches.firstIndex { NSEqualRanges($0, selection) }
        let selectedIndex: Int

        if request.startsAtBeginning {
            selectedIndex = 0
        } else if request.direction == .next {
            if let currentMatch {
                selectedIndex = (currentMatch + 1) % matches.count
            } else {
                selectedIndex = matches.firstIndex {
                    $0.location >= selection.location
                } ?? 0
            }
        } else if let currentMatch {
            selectedIndex = (currentMatch - 1 + matches.count) % matches.count
        } else {
            selectedIndex = matches.lastIndex {
                $0.location < selection.location
            } ?? matches.count - 1
        }

        let selectedRange = matches[selectedIndex]
        textView.setSelectedRange(selectedRange)
        textView.scrollRangeToVisible(selectedRange)
        report(matches: matches, selectedMatch: selectedIndex + 1)
    }

    private func requestSearch(
        direction: NoteSearchDirection,
        startsAtBeginning: Bool
    ) {
        request = NoteSearchRequest(
            query: query,
            direction: direction,
            startsAtBeginning: startsAtBeginning
        )
    }

    private func report(matches: [NSRange], selectedMatch: Int?) {
        matchCount = matches.count
        self.selectedMatch = selectedMatch ?? 0
    }
}

struct NoteSearch: View {
    @ObservedObject var search: NoteSearchModel
    let onClose: () -> Void
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("Find in note", text: $search.query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .focused($isSearchFocused)
                .onChange(of: search.query) { _, _ in
                    search.updateQuery()
                }
                .onSubmit(search.findNext)

            Text(search.statusText)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(minWidth: 76, alignment: .leading)

            Button(action: search.findPrevious) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .disabled(search.query.isEmpty)
            .help("Previous Match")

            Button(action: search.findNext) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .disabled(search.query.isEmpty)
            .help("Next Match")

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Close Search")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear {
            isSearchFocused = true
        }
        .onExitCommand(perform: onClose)
    }
}