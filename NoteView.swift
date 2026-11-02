//  LightNote+/
//  ├── LightNote+/                  # Source files
//  │   ├── AppDelegate.swift           # App entry point//
//  │   ├── ContentView.swift           # Main Text-editor view with toolbar, tabs, and editor
//  │   ├── NoteView.swift              # Notes view with file tree and note editor
//  │   ├── ThemeManager.swift          # Dark/light theme management
//  │   ├── TabManager.swift            # Tab system for multiple files
//  │   ├── SyntaxHighlighter.swift     # Syntax highlighting (framework)
//  │   └── Info.plist                  # App configuration
//  └── LightNotePlus.xcodeproj/        # Xcode project files
//
// Created by mnrds
//

import SwiftUI
import Combine
import Foundation

struct NoteTreeItem: Identifiable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let children: [NoteTreeItem]?

    var id: String { url.absoluteString }
}

@MainActor
final class NotesWorkspaceModel: ObservableObject {
    @Published private(set) var notes: [NoteTreeItem] = []
    @Published private(set) var selectedNoteURL: URL?
    @Published var content = ""
    @Published var errorMessage: String?

    // Documents/LightNotePlus/Notes
    let rootURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents", isDirectory: true)
        .appendingPathComponent("LightNotePlus", isDirectory: true)
        .appendingPathComponent("Notes", isDirectory: true)

    func loadWorkspace() {
        do {
            try FileManager.default.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true
            )
            try refreshNotes()
            if let selectedNoteURL,
               FileManager.default.fileExists(atPath: selectedNoteURL.path) {
                selectNote(selectedNoteURL)
            } else if let firstNote = firstNoteURL(in: notes) {
                selectNote(firstNote)
            } else {
                selectedNoteURL = nil
                content = ""
            }
        } catch {
            errorMessage = "Unable to load the notes folder: \(error.localizedDescription)"
        }
    }

    func createNote() {
        do {
            try FileManager.default.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true
            )

            var fileURL = rootURL.appendingPathComponent("Untitled.md")
            var number = 2
            while FileManager.default.fileExists(atPath: fileURL.path) {
                fileURL = rootURL.appendingPathComponent("Untitled \(number).md")
                number += 1
            }

            try Data().write(to: fileURL, options: .atomic)
            try refreshNotes()
            selectNote(fileURL)
        } catch {
            errorMessage = "Unable to create a note: \(error.localizedDescription)"
        }
    }

    func selectNote(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            guard let noteContent = String(data: data, encoding: .utf8) else {
                errorMessage = "The note is not valid UTF-8 text."
                return
            }

            selectedNoteURL = url
            content = noteContent
        } catch {
            errorMessage = "Unable to open the note: \(error.localizedDescription)"
        }
    }

    func saveCurrentNote() {
        guard let selectedNoteURL else { return }

        do {
            try content.write(to: selectedNoteURL, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Unable to save the note: \(error.localizedDescription)"
        }
    }

    private func refreshNotes() throws {
        notes = try treeItems(in: rootURL)
    }

    private func treeItems(in directory: URL) throws -> [NoteTreeItem] {
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var items: [NoteTreeItem] = []

        for url in fileURLs {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { continue }

            if values.isDirectory == true {
                items.append(
                    NoteTreeItem(
                        url: url,
                        name: url.lastPathComponent,
                        isDirectory: true,
                        children: try treeItems(in: url)
                    )
                )
            } else if url.pathExtension.lowercased() == "md" {
                items.append(
                    NoteTreeItem(
                        url: url,
                        name: url.deletingPathExtension().lastPathComponent,
                        isDirectory: false,
                        children: nil
                    )
                )
            }
        }

        return items.sorted {
            if $0.isDirectory != $1.isDirectory {
                return $0.isDirectory
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func firstNoteURL(in items: [NoteTreeItem]) -> URL? {
        for item in items {
            if item.isDirectory, let noteURL = firstNoteURL(in: item.children ?? []) {
                return noteURL
            }
            if !item.isDirectory {
                return item.url
            }
        }
        return nil
    }
}

struct NoteView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @ObservedObject var model: NotesWorkspaceModel

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Notes")
                        .font(.headline)
                    Spacer()
                    Button(action: model.createNote) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .help("Create Note")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                Divider()

                List {
                    OutlineGroup(model.notes, children: \.children) { item in
                        HStack(spacing: 6) {
                            Image(systemName: item.isDirectory ? "folder" : "doc.text")
                                .foregroundColor(themeManager.colors.tabText)
                            Text(item.name)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                        .background(
                            model.selectedNoteURL == item.url
                                ? themeManager.colors.tabSelected.opacity(0.18)
                                : Color.clear
                        )
                        .onTapGesture {
                            if !item.isDirectory {
                                model.selectNote(item.url)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 170, idealWidth: 220, maxWidth: 300)

            Group {
                if let selectedNoteURL = model.selectedNoteURL {
                    VStack(spacing: 0) {
                        HStack {
                            Text(selectedNoteURL.deletingPathExtension().lastPathComponent)
                                .font(.headline)
                            Spacer()
                            Text("Markdown")
                                .font(.caption)
                                .foregroundColor(themeManager.colors.tabText)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)

                        Divider()

                        TextEditor(text: $model.content)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(themeManager.colors.editorText)
                            .scrollContentBackground(.hidden)
                            .background(themeManager.colors.editorBackground)
                            .onChange(of: model.content) { _, _ in
                                model.saveCurrentNote()
                            }
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "note.text")
                            .font(.largeTitle)
                        Text("Create a note or add a Markdown file to the Notes folder.")
                            .multilineTextAlignment(.center)
                            .foregroundColor(themeManager.colors.tabText)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity)
            .background(themeManager.colors.editorBackground)
        }
        .onAppear(perform: model.loadWorkspace)
        .alert(
            "Notes",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        model.errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
