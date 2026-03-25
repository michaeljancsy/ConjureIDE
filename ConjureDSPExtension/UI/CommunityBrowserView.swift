import SwiftUI

/// Browse and install presets from the ConjureDSP community GitHub repo.
struct CommunityBrowserView: View {
    @ObservedObject var store: CommunityPresetStore
    let presetManager: PresetManager
    let onInstalled: (Preset) -> Void
    let onDismiss: () -> Void

    @State private var searchText = ""
    @State private var previewEntry: RepoPresetEntry?
    @State private var previewSource: String?
    @State private var isLoadingPreview = false
    @State private var installingEntryID: String?
    @State private var installError: String?

    private var filteredPresets: [RepoPresetEntry] {
        if searchText.isEmpty { return store.catalog }
        let query = searchText.lowercased()
        return store.catalog.filter {
            $0.name.lowercased().contains(query)
                || ($0.metadata.category?.lowercased().contains(query) ?? false)
                || ($0.metadata.author?.lowercased().contains(query) ?? false)
                || ($0.metadata.description?.lowercased().contains(query) ?? false)
        }
    }

    private var groupedPresets: [(category: String, presets: [RepoPresetEntry])] {
        let grouped = Dictionary(grouping: filteredPresets, by: { $0.metadata.category ?? "Other" })
        return grouped.keys.sorted().map { (category: $0, presets: grouped[$0]!) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Community Presets")
                    .font(.headline)
                Spacer()
                Button("Done") { onDismiss() }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search presets\u{2026}", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            // Content
            if store.isLoading && store.catalog.isEmpty {
                Spacer()
                ProgressView("Loading community presets\u{2026}")
                Spacer()
            } else if let error = store.error, store.catalog.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "wifi.slash")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Failed to load")
                        .font(.subheadline)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        Task { await store.loadCatalog() }
                    }
                }
                .padding()
                Spacer()
            } else if filteredPresets.isEmpty {
                Spacer()
                Text(searchText.isEmpty ? "No presets available" : "No matching presets")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groupedPresets, id: \.category) { group in
                            Section {
                                ForEach(group.presets) { entry in
                                    presetRow(entry)
                                    Divider().padding(.leading, 12)
                                }
                            } header: {
                                Text(group.category.uppercased())
                                    .font(.caption2.bold())
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 12)
                                    .padding(.bottom, 4)
                            }
                        }
                    }
                }
            }

            // Error banner
            if let error = installError {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                    Spacer()
                    Button(action: { installError = nil }) {
                        Image(systemName: "xmark")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.1))
            }
        }
        .frame(width: 380, height: 420)
        .task {
            await store.loadCatalog()
        }
    }

    @ViewBuilder
    private func presetRow(_ entry: RepoPresetEntry) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(entry.name)
                        .font(.system(size: 13, weight: .medium))
                    Text(entry.language == .rust ? "Rust" : "Python")
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(3)
                }
                if let desc = entry.metadata.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                if let author = entry.metadata.author, !author.isEmpty {
                    Text("by \(author)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Preview button
            Button(action: { loadPreview(entry) }) {
                if isLoadingPreview && previewEntry?.id == entry.id {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "eye")
                }
            }
            .buttonStyle(.borderless)
            .popover(isPresented: Binding(
                get: { previewEntry?.id == entry.id && previewSource != nil },
                set: { if !$0 { previewEntry = nil; previewSource = nil } }
            )) {
                previewPopover(entry)
            }

            // Install button
            let isInstalled = presetManager.presets.contains { !$0.isFactory && $0.name == entry.name }
            Button(action: { installPreset(entry) }) {
                if installingEntryID == entry.id {
                    ProgressView().controlSize(.small)
                } else if isInstalled {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else {
                    Text("Install")
                        .font(.caption)
                }
            }
            .buttonStyle(.borderless)
            .disabled(installingEntryID != nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func previewPopover(_ entry: RepoPresetEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(entry.name)
                    .font(.headline)
                Spacer()
                Button("Close") {
                    previewEntry = nil
                    previewSource = nil
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                Text(previewSource ?? "")
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 420, height: 320)
    }

    // MARK: - Actions

    private func loadPreview(_ entry: RepoPresetEntry) {
        previewEntry = entry
        previewSource = nil
        isLoadingPreview = true
        Task {
            do {
                let source = try await store.fetchPresetSource(for: entry)
                previewSource = source
            } catch {
                previewSource = "// Error loading source: \(error.localizedDescription)"
            }
            isLoadingPreview = false
        }
    }

    private func installPreset(_ entry: RepoPresetEntry) {
        installingEntryID = entry.id
        installError = nil
        Task {
            do {
                let preset = try await store.installPreset(entry, into: presetManager)
                onInstalled(preset)
            } catch {
                installError = "Failed to install \(entry.name): \(error.localizedDescription)"
            }
            installingEntryID = nil
        }
    }
}
