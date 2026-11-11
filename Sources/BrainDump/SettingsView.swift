import AppKit
import BrainDumpCore
import BrainDumpLLM
import EventKit
import SwiftUI

struct SettingsView: View {
    @AppStorage(Prefs.Key.notesPath) private var notesPath = ""
    @AppStorage(Prefs.Key.useCloud) private var useCloud = false
    @AppStorage(Prefs.Key.localModelID) private var localModelID = ""
    @AppStorage(Prefs.Key.cloudModel) private var cloudModel = ""
    @AppStorage(Prefs.Key.remindersList) private var remindersList = "Brain Dump"
    @AppStorage(Prefs.Key.autoApproveReminders) private var autoReminders = false
    @AppStorage(Prefs.Key.autoApproveNotes) private var autoNotes = false
    @AppStorage(Prefs.Key.remindersEnabled) private var remindersEnabled = true
    @AppStorage(Prefs.Key.notesEnabled) private var notesEnabled = true
    @State private var remindersStatus = EKEventStore.authorizationStatus(for: .reminder)
    @State private var apiKey = Keychain.get() ?? ""

    private var notesURL: URL { notesPath.isEmpty ? NotesStore.defaultRoot : URL(fileURLWithPath: notesPath) }

    var body: some View {
        Form {
            Section("Notes") {
                LabeledContent("Folder") {
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(notesURL.path).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack {
                            Button("Choose…", action: chooseFolder)
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([notesURL]) }
                            if !notesPath.isEmpty { Button("Use default") { notesPath = "" } }
                        }
                    }
                }
            }

            Section("Model") {
                Picker("Run the model", selection: $useCloud) {
                    Text("On this Mac").tag(false)
                    Text("Cloud (Anthropic)").tag(true)
                }
                .pickerStyle(.segmented)
                if useCloud {
                    SecureField("API key", text: $apiKey)
                        .onChange(of: apiKey) { _, new in Keychain.set(new) }
                    TextField("Model", text: $cloudModel, prompt: Text(CloudLLM.defaultModel))
                    Text("Cloud mode sends the transcript of your dump to Anthropic. Local mode keeps everything on this Mac.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    ForEach(ModelCatalog.all) { model in
                        LocalModelRow(model: model, selected: effectiveModelID == model.id) { localModelID = model.id }
                    }
                }
            }

            Section("Connectors") {
                connectorRow(
                    icon: "checklist", name: "Reminders", kinds: "To-dos",
                    destination: "Reminders › \(remindersList.isEmpty ? "Default" : remindersList)",
                    status: reminderStatusText, enabled: $remindersEnabled)
                TextField("Reminders list", text: $remindersList, prompt: Text("Default list"))
                Toggle("Auto-approve Reminders", isOn: $autoReminders)
                connectorRow(
                    icon: "folder", name: "Notes", kinds: "Ideas and Thoughts",
                    destination: notesURL.path,
                    status: FileManager.default.fileExists(atPath: notesURL.path) ? "Folder ready" : "Folder will be created",
                    enabled: $notesEnabled)
                Toggle("Auto-approve Notes", isOn: $autoNotes)
                Text("Auto-approved items are created straight after reading, without review. Items for a disabled connector show no destination and are skipped.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                HStack {
                    Label("Add connector…", systemImage: "plus.circle")
                    Spacer()
                }
                .foregroundStyle(.tertiary)
                Text("Calendar, Research and MCP connectors coming soon")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 640)
    }

    private var reminderStatusText: String {
        switch remindersStatus {
        case .fullAccess: return "Access granted"
        case .notDetermined: return "Not requested yet"
        default: return "Access denied. Allow in System Settings."
        }
    }

    private func connectorRow(icon: String, name: String, kinds: String, destination: String, status: String, enabled: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 18)).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).fontWeight(.medium)
                Text("Handles: \(kinds)").font(.system(size: 12)).foregroundStyle(.secondary)
                Text("Destination: \(destination)").font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                Text(status).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: enabled).labelsHidden()
        }
        .onAppear { remindersStatus = EKEventStore.authorizationStatus(for: .reminder) }
    }

    private var effectiveModelID: String {
        localModelID.isEmpty ? ModelCatalog.defaultModel.id : localModelID
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = notesURL
        if panel.runModal() == .OK, let url = panel.url { notesPath = url.path }
    }
}

struct LocalModelRow: View {
    let model: LocalModel
    let selected: Bool
    let select: () -> Void
    @State private var downloaded = false
    @State private var progress: Double?
    @State private var error: String?

    var body: some View {
        HStack(alignment: .top) {
            Button(action: select) { Image(systemName: selected ? "largecircle.fill.circle" : "circle") }
                .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.name)  ·  \(sizeText)")
                Text(model.note).font(.system(size: 12)).foregroundStyle(.secondary)
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(.orange) }
            }
            Spacer()
            if let progress {
                ProgressView(value: progress).frame(width: 80)
            } else if downloaded {
                Button("Delete", role: .destructive) {
                    try? FileManager.default.removeItem(at: ModelCatalog.localURL(for: model))
                    downloaded = ModelCatalog.isDownloaded(model)
                }
            } else {
                Button("Download", action: download)
            }
        }
        .onAppear { downloaded = ModelCatalog.isDownloaded(model) }
    }

    private var sizeText: String {
        model.sizeMB >= 1000 ? String(format: "%.1f GB", Double(model.sizeMB) / 1000) : "\(model.sizeMB) MB"
    }

    private func download() {
        progress = 0
        error = nil
        Task {
            do {
                try await ModelCatalog.download(model) { fraction in
                    Task { @MainActor in progress = fraction }
                }
            } catch {
                self.error = error.localizedDescription
            }
            progress = nil
            downloaded = ModelCatalog.isDownloaded(model)
        }
    }
}
