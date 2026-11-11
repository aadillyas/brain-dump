import BrainDumpLLM
import SwiftUI

/// The two models the app offers: Apple's built-in model (preferred when this Mac supports it) and LFM3 1.7B.
/// Used by Settings and the first-start intro.
struct ModelPicker: View {
    @AppStorage(Prefs.Key.localModelID) private var localModelID = ""

    var body: some View {
        let _ = localModelID  // read so the view refreshes when the choice changes
        let choice = Prefs.modelChoice
        VStack(alignment: .leading, spacing: 14) {
            AppleModelRow(selected: choice == Prefs.appleModelID) { localModelID = Prefs.appleModelID }
            LocalModelRow(model: ModelCatalog.defaultModel, selected: choice == ModelCatalog.defaultModel.id) {
                localModelID = ModelCatalog.defaultModel.id
            }
        }
    }
}

struct AppleModelRow: View {
    let selected: Bool
    let select: () -> Void

    var body: some View {
        let available = Pipeline.appleAvailable
        HStack(alignment: .top) {
            Button(action: select) { Image(systemName: selected ? "largecircle.fill.circle" : "circle") }
                .buttonStyle(.plain)
                .disabled(!available)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Apple on-device model").fontWeight(.medium)
                    if available { recommendedBadge() }
                }
                Text("Built into macOS, nothing to download. Fewer false suggestions to dismiss.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if !available {
                    Text("Not available on this Mac: \(Pipeline.appleUnavailableReason).")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { if available { select() } }
        .opacity(available ? 1 : 0.6)
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
            Button(action: choose) { Image(systemName: selected ? "largecircle.fill.circle" : "circle") }
                .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.name).fontWeight(.medium)
                    if !Pipeline.appleAvailable { recommendedBadge() }
                }
                Text(model.note).font(.system(size: 12)).foregroundStyle(.secondary)
                Text(downloaded ? "Downloaded · \(sizeText)" : "\(sizeText) download")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
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
        .contentShape(Rectangle())
        .onTapGesture(perform: choose)
        .onAppear { downloaded = ModelCatalog.isDownloaded(model) }
    }

    /// Selecting a model that is not on disk yet starts its download.
    private func choose() {
        select()
        if !downloaded && progress == nil { download() }
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

/// Offers to delete model files from earlier versions, which the app no longer uses.
struct UnusedModelsRow: View {
    @State private var files = ModelCatalog.unusedDownloads

    var body: some View {
        if !files.isEmpty {
            HStack {
                Text("Models from earlier versions use \(size) on disk.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Remove", role: .destructive) {
                    for url in files { try? FileManager.default.removeItem(at: url) }
                    files = ModelCatalog.unusedDownloads
                }
            }
        }
    }

    private var size: String {
        let bytes = files.reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private func recommendedBadge(_ text: String = "Recommended") -> some View {
    Text(text)
        .font(.system(size: 10, weight: .semibold))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
        .foregroundStyle(Color.accentColor)
}
