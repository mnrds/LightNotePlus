//  LightNote+/
//  AppSettings.swift
//
// Created by mnrds
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

enum AppOpeningView: String, CaseIterable, Identifiable {
    case textEditor
    case notes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .textEditor: "Text Editor"
        case .notes: "NoteView"
        }
    }
}

private struct NotesOrganizationDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct AppSettings: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var notesWorkspace: NotesWorkspaceModel
    @AppStorage("defaultOpeningView") private var defaultOpeningView = AppOpeningView.textEditor.rawValue
    @State private var exportDocument: NotesOrganizationDocument?
    @State private var isExportPresented = false
    @State private var isImportPresented = false
    @State private var pendingImportData: Data?
    @State private var isImportConfirmationPresented = false
    @State private var errorMessage: String?

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $themeManager.currentTheme) {
                    ForEach(ThemeManager.Theme.allCases, id: \.self) { theme in
                        Text(theme.rawValue.capitalized)
                            .tag(theme)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Startup") {
                Picker("Open at launch", selection: $defaultOpeningView) {
                    ForEach(AppOpeningView.allCases) { openingView in
                        Text(openingView.title)
                            .tag(openingView.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Notes folder") {
                Text(notesWorkspace.rootURL.path)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)

                HStack {
                    Button("Choose Folder…", systemImage: "folder") {
                        chooseNotesFolder()
                    }
                    Button("Reset to Default") {
                        resetNotesFolder()
                    }
                }
            }

            Section("Notes organization") {
                Text("Export or import note headings, their order, and note assignments. Note files are not included.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Export…", systemImage: "square.and.arrow.up") {
                        exportOrganization()
                    }
                    Button("Import…", systemImage: "square.and.arrow.down") {
                        isImportPresented = true
                    }
                }
            }

            Section("About") {
                LabeledContent("Application version", value: appVersion)
                Text("Thank you for using my app LightNote+. Visit my website for more mnrds.org")
                    .foregroundStyle(.secondary)
                Text("Created by mnrds")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 420)
        .fileExporter(
            isPresented: $isExportPresented,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "LightNotePlus-Notes-Organization"
        ) { result in
            if case .failure(let error) = result {
                errorMessage = "Unable to export note organization: \(error.localizedDescription)"
            }
            exportDocument = nil
        }
        .fileImporter(
            isPresented: $isImportPresented,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false,
            onCompletion: handleImportSelection
        )
        .confirmationDialog(
            "Import notes organization?",
            isPresented: $isImportConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Import", role: .destructive) {
                importPendingOrganization()
            }
            Button("Cancel", role: .cancel) {
                pendingImportData = nil
            }
        } message: {
            Text("This replaces the current headings, order, and note assignments. Note files will not be changed.")
        }
        .alert(
            "Settings",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func exportOrganization() {
        do {
            exportDocument = NotesOrganizationDocument(data: try notesWorkspace.exportOrganization())
            isExportPresented = true
        } catch {
            errorMessage = "Unable to export note organization: \(error.localizedDescription)"
        }
    }

    private func chooseNotesFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Notes Folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = notesWorkspace.rootURL

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try notesWorkspace.setNotesFolder(url)
                if let workspaceError = notesWorkspace.errorMessage {
                    errorMessage = workspaceError
                }
            } catch {
                errorMessage = "Unable to change the Notes folder: \(error.localizedDescription)"
            }
        }
    }

    private func resetNotesFolder() {
        do {
            try notesWorkspace.resetNotesFolder()
            if let workspaceError = notesWorkspace.errorMessage {
                errorMessage = workspaceError
            }
        } catch {
            errorMessage = "Unable to reset the Notes folder: \(error.localizedDescription)"
        }
    }

    private func handleImportSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                pendingImportData = try Data(contentsOf: url)
                isImportConfirmationPresented = true
            } catch {
                errorMessage = "Unable to read note organization file: \(error.localizedDescription)"
            }
        case .failure(let error):
            errorMessage = "Unable to import note organization: \(error.localizedDescription)"
        }
    }

    private func importPendingOrganization() {
        guard let pendingImportData else { return }
        do {
            try notesWorkspace.importOrganization(from: pendingImportData)
        } catch {
            errorMessage = "Unable to import note organization: \(error.localizedDescription)"
        }
        self.pendingImportData = nil
    }
}
