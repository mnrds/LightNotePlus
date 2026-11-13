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

// Font size for the Notes editor and preview, combined with View > Zoom.
enum NoteEditorSettings {
    static let fontSizeKey = "notesFontSize"
    static let defaultFontSize: Double = 14
    static let fontSizeRange: ClosedRange<Double> = 10...28
    /// ZoomState's "Actual Size" font size.
    static let actualSizeZoom: CGFloat = 12

    static func scale(fontSize: Double, zoom: CGFloat) -> CGFloat {
        let clampedSize = min(max(fontSize, fontSizeRange.lowerBound), fontSizeRange.upperBound)
        return CGFloat(clampedSize / defaultFontSize) * (zoom / actualSizeZoom)
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
    @AppStorage(NoteEditorSettings.fontSizeKey) private var notesFontSize = NoteEditorSettings.defaultFontSize
    @State private var importFolderMismatch: String?
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

                Stepper(
                    "Notes font size: \(Int(notesFontSize)) pt",
                    value: $notesFontSize,
                    in: NoteEditorSettings.fontSizeRange,
                    step: 1
                )
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

            Section("Notes settings") {
                Text("Export includes the Notes folder location (relative to your home folder), headings, note assignments, and note order. Note files and folder contents are not included. If the saved folder differs from the current one, import asks you to choose a Notes folder; its files are not changed.")
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
                Text("Thank you for using my app LightNote+. Visit my website for more")
                    .foregroundStyle(.secondary)
                Link("https://mnrds.org", destination: URL(string: "https://mnrds.org")!)
                Text("For App updates check out:")
                    .foregroundStyle(.secondary)
                Link("LightNote+ website", destination: URL(string: "https://mnrds.org/light-note-plus/")!)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 420)
        .fileExporter(
            isPresented: $isExportPresented,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "LightNotePlus-Notes-Settings"
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
            "Import Notes settings?",
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
            Text("This replaces the current headings, order, and note assignments in the selected Notes folder. Note files will not be changed.")
        }
        .confirmationDialog(
            "Notes folder differs",
            isPresented: Binding(
                get: { importFolderMismatch != nil },
                set: { if !$0 { importFolderMismatch = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Choose Folder…") {
                importFolderMismatch = nil
                chooseNotesFolder { isImportConfirmationPresented = true }
            }
            Button("Use Current Folder") {
                importFolderMismatch = nil
                isImportConfirmationPresented = true
            }
            Button("Cancel", role: .cancel) {
                importFolderMismatch = nil
                pendingImportData = nil
            }
        } message: {
            Text("These settings were exported from “\(importFolderMismatch ?? "")”. Choose that Notes folder, or apply them to the current one.")
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

    private func chooseNotesFolder(onChosen: (() -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Choose Notes Folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = notesWorkspace.rootURL

        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                if onChosen != nil {
                    pendingImportData = nil
                }
                return
            }
            do {
                try notesWorkspace.setNotesFolder(url)
                if let workspaceError = notesWorkspace.errorMessage {
                    errorMessage = workspaceError
                }
                onChosen?()
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
                let data = try Data(contentsOf: url)
                pendingImportData = data
                if let savedFolder = notesWorkspace.exportedNotesFolderMismatch(in: data) {
                    importFolderMismatch = savedFolder
                } else {
                    isImportConfirmationPresented = true
                }
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
