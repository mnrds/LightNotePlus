//  LightNote+
//
//  NoteTabBar.swift
//  Open note tabs with unsaved-changes indicator and close buttons.
//
// Created by mnrds
//

import SwiftUI

struct NoteTabBar: View {
    let openNoteURLs: [URL]
    let selectedNoteURL: URL?
    let hasUnsavedChanges: Bool
    let colors: ThemeColors
    let separatorColor: Color
    let onSelect: (URL) -> Void
    let onClose: (URL) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(openNoteURLs, id: \.standardizedFileURL.path) { url in
                        noteTab(for: url)
                    }
                }
            }
            .scrollIndicators(.hidden)
            // Keep the selected tab visible when it changes or tabs are added.
            .onChange(of: selectedNoteURL) { _, url in
                scrollToTab(url, with: proxy)
            }
            .onChange(of: openNoteURLs) { _, _ in
                scrollToTab(selectedNoteURL, with: proxy)
            }
        }
    }

    private func scrollToTab(_ url: URL?, with proxy: ScrollViewProxy) {
        guard let path = url?.standardizedFileURL.path else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            proxy.scrollTo(path)
        }
    }

    // Builds a selectable note tab with a close button.
    private func noteTab(for url: URL) -> some View {
        let isSelected = selectedNoteURL == url
        let isUnsaved = isSelected && hasUnsavedChanges
        let title = url.deletingPathExtension().lastPathComponent
        return ZStack(alignment: .trailing) {
            Button {
                onSelect(url)
            } label: {
                HStack(spacing: 6) {
                    Text(title)
                        .lineLimit(1)
                        .foregroundColor(isSelected ? colors.text : colors.tabText)
                    if isUnsaved {
                        Circle()
                            .fill(colors.tabText)
                            .frame(width: 6, height: 6)
                            .help("Unsaved changes")
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 40)
                .contentShape(Rectangle())
                .padding(.leading, 14)
                .padding(.trailing, 36)
            }
            .buttonStyle(.plain)

            Button {
                onClose(url)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(colors.tabText)
                    .padding(.trailing, 12)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
            .help("Close Note")
            .padding(.trailing, 4)
        }
        .frame(width: 180, height: 42)
        .background(isSelected ? colors.editorBackground : Color.clear)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isUnsaved ? "\(title), unsaved changes" : title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(separatorColor)
                .frame(width: 1)
        }
    }
}
