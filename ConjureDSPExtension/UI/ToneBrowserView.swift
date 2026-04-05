//
//  ToneBrowserView.swift
//  ConjureDSPExtension
//
//  Browse, search, and download NAM tones from tone3000.com.
//  Displayed as a popover from the toolbar Tones button.
//

import SwiftUI
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "ToneBrowser")

/// A NAM tone selected for insertion into the script editor.
/// Carries enough context for the receiver to place imports and the
/// model instantiation in language-appropriate locations.
struct NAMToneInsertion {
    let toneId: String
    let modelId: String
    let title: String
    let url: String?
}

struct ToneBrowserView: View {
    let client: Tone3000Client
    let modelStore: ToneModelStore
    var selectedLanguage: ScriptLanguage = .python
    let onDone: () -> Void
    let onInsertTone: (NAMToneInsertion) -> Void

    @Environment(\.openURL) private var openURL

    enum Tab: String, CaseIterable {
        case search = "Search"
        case myTones = "My Tones"
        case favorites = "Favorites"
    }

    @State private var tab: Tab = .search
    @State private var searchText = ""
    @State private var searchResults: [Tone] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var selectedSort: ToneSort = .bestMatch
    @State private var expandedToneId: String?
    @State private var toneModels: [String: [ToneModel]] = [:]
    @State private var downloadingModelId: String?
    @State private var showingAuth = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Tones")
                    .font(.headline)
                Spacer()
                if client.isAuthenticated, let username = client.username {
                    Text(username)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Done") { onDone() }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if !client.isAuthenticated {
                // Auth gate
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "guitars")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("Connect your tone3000 account to browse and download amp/pedal tones.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Button("Connect tone3000") {
                        showingAuth = true
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                }
            } else {
                // Tab bar
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)

                // Search bar (for search tab)
                if tab == .search {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search tones...", text: $searchText)
                            .textFieldStyle(.plain)
                            .onChange(of: searchText) { _, newValue in
                                debounceSearch(query: newValue)
                            }
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                        Picker("", selection: $selectedSort) {
                            ForEach(ToneSort.allCases, id: \.self) { sort in
                                Text(sort.displayName).tag(sort)
                            }
                        }
                        .frame(width: 110)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }

                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 12)
                }

                // Results
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // Downloaded section (My Tones tab only)
                        if tab == .myTones && !modelStore.downloadedModels.isEmpty {
                            Section {
                                ForEach(modelStore.downloadedModels) { model in
                                    downloadedModelRow(model)
                                }
                            } header: {
                                Text("Downloaded")
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 8)
                            }

                            Divider()
                                .padding(.vertical, 4)
                        }

                        // Search / browse results
                        if isSearching {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                            .padding()
                        } else {
                            ForEach(searchResults) { tone in
                                toneRow(tone)
                            }
                            if searchResults.isEmpty && !searchText.isEmpty {
                                Text("No tones found")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding()
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 380, height: 460)
        .sheet(isPresented: $showingAuth) {
            Tone3000AuthView(
                client: client,
                onSuccess: {
                    showingAuth = false
                },
                onCancel: {
                    showingAuth = false
                }
            )
        }
        .task {
            if client.isAuthenticated && tab == .search && searchResults.isEmpty {
                await performSearch(query: "")
            }
        }
        .onChange(of: tab) { _, newTab in
            Task {
                switch newTab {
                case .search: await performSearch(query: searchText)
                case .myTones: await fetchMyTones()
                case .favorites: await fetchFavorites()
                }
            }
        }
    }

    // MARK: - Tone Row

    @ViewBuilder
    private func toneRow(_ tone: Tone) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        expandedToneId = expandedToneId == tone.id.stringValue ? nil : tone.id.stringValue
                    }
                    if expandedToneId == tone.id.stringValue {
                        Task { await fetchModels(toneId: tone.id.stringValue) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tone.title)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                if let user = tone.user {
                                    Text(user.username)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if let gear = tone.gear {
                                    Text("·")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(gear)
                                        .font(.caption2)
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        Spacer()
                        if let downloads = tone.downloadsCount, downloads > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "arrow.down.circle")
                                    .font(.caption2)
                                Text("\(downloads)")
                                    .font(.caption2)
                            }
                            .foregroundStyle(.secondary)
                        }
                        Image(systemName: expandedToneId == tone.id.stringValue ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 12)

                if let url = URL(string: "https://www.tone3000.com/tones/\(tone.id.stringValue)") {
                    Button {
                        openURL(url)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open on tone3000.com")
                }
            }

            // Expanded: show models
            if expandedToneId == tone.id.stringValue {
                if let models = toneModels[tone.id.stringValue] {
                    let sizesVary = Set(models.compactMap(\.size)).count > 1
                    ForEach(models) { model in
                        modelRow(tone: tone, model: model, showSize: sizesVary)
                    }
                } else {
                    HStack {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private func modelRow(tone: Tone, model: ToneModel, showSize: Bool) -> some View {
        let isDownloaded = modelStore.modelURL(toneId: tone.id.stringValue, modelId: model.id.stringValue) != nil
        let isDownloading = downloadingModelId == model.id.stringValue
        let displayName = Self.shortenModelName(model.name ?? model.id.stringValue, toneTitle: tone.title)

        HStack(spacing: 8) {
            Text(displayName)
                .font(.system(size: 11))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if showSize, let size = model.size {
                Text(size)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(3)
            }
            Spacer()
            if isDownloading {
                ProgressView()
                    .controlSize(.small)
            } else if isDownloaded {
                Button("Use") {
                    onInsertTone(NAMToneInsertion(
                        toneId: tone.id.stringValue,
                        modelId: model.id.stringValue,
                        title: tone.title,
                        url: tone.url
                    ))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Button {
                    Task { await downloadModel(tone: tone, model: model) }
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func downloadedModelRow(_ model: ToneModelStore.DownloadedModel) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.toneName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(model.modelName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if !model.modelSize.isEmpty && model.modelSize != "unknown" {
                        Text(model.modelSize)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 3)
                            .background(Color.secondary.opacity(0.15))
                            .cornerRadius(2)
                    }
                }
            }
            Spacer()
            Button("Use") {
                onInsertTone(NAMToneInsertion(
                    toneId: model.toneId,
                    modelId: model.modelId,
                    title: model.toneName,
                    url: model.toneUrl
                ))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button {
                modelStore.delete(toneId: model.toneId, modelId: model.modelId)
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func downloadModel(tone: Tone, model: ToneModel) async {
        guard let urlStr = model.modelUrl, let url = URL(string: urlStr) else {
            error = "No download URL for this model"
            return
        }
        guard let token = await client.accessToken else {
            error = "Not authenticated"
            return
        }

        downloadingModelId = model.id.stringValue
        error = nil

        do {
            try await modelStore.download(
                toneId: tone.id.stringValue,
                toneName: tone.title,
                toneUrl: tone.url,
                gear: tone.gear ?? "",
                author: tone.user?.username ?? "",
                tags: tone.tags?.map(\.name) ?? [],
                makes: tone.makes?.map(\.name) ?? [],
                modelId: model.id.stringValue,
                modelName: model.name ?? model.id.stringValue,
                modelSize: model.size ?? "",
                modelURL: url,
                accessToken: token
            )
        } catch {
            self.error = error.localizedDescription
            log.error("Download failed: \(error.localizedDescription, privacy: .public)")
        }

        downloadingModelId = nil
    }

    // MARK: - Search

    private func debounceSearch(query: String) {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled {
                await performSearch(query: query)
            }
        }
    }

    private func performSearch(query: String) async {
        isSearching = true
        error = nil
        do {
            let result = try await client.searchTones(query: query, sort: selectedSort)
            searchResults = result.items
        } catch {
            self.error = error.localizedDescription
        }
        isSearching = false
    }

    private func fetchMyTones() async {
        isSearching = true
        error = nil
        do {
            let result = try await client.createdTones()
            searchResults = result.items
        } catch {
            self.error = error.localizedDescription
        }
        isSearching = false
    }

    private func fetchFavorites() async {
        isSearching = true
        error = nil
        do {
            let result = try await client.favoritedTones()
            searchResults = result.items
        } catch {
            self.error = error.localizedDescription
        }
        isSearching = false
    }

    private func fetchModels(toneId: String) async {
        // Skip if already fetched — avoids redundant API calls when re-expanding
        if toneModels[toneId] != nil { return }

        do {
            let models = try await client.models(forToneId: toneId)
            toneModels[toneId] = models
        } catch {
            log.error("Failed to fetch models: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Model Name Helpers

    /// Strips redundant tone-title words from a model name to show only the differentiating info.
    /// e.g. "[AMP] JCM800-2203-MODIFIED-HI Bad Boys" with tone "Marshall JCM800 2203 Modified"
    /// → "[AMP] HI Bad Boys"
    static func shortenModelName(_ modelName: String, toneTitle: String) -> String {
        var name = modelName

        // Extract bracket tag if present, e.g. [AMP], [PRE], [POW], [OD]
        var tag = ""
        if name.hasPrefix("["), let closeBracket = name.firstIndex(of: "]") {
            tag = String(name[name.startIndex...closeBracket])
            var rest = String(name[name.index(after: closeBracket)...])
            while rest.first == " " { rest.removeFirst() }
            name = rest
        }

        // Build set of title words (lowercase, alphanumeric only)
        let titleWords = Set(
            toneTitle.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )

        // Split model name into alphanumeric words for matching
        let nameWords = name.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        // Count consecutive leading words that appear in the tone title
        var matchedWords = 0
        for word in nameWords {
            if titleWords.contains(word.lowercased()) {
                matchedWords += 1
            } else {
                break
            }
        }

        if matchedWords > 0 {
            // Advance past matched words in the original string
            var pos = name.startIndex
            for _ in 0..<matchedWords {
                while pos < name.endIndex && !name[pos].isLetter && !name[pos].isNumber {
                    pos = name.index(after: pos)
                }
                while pos < name.endIndex && (name[pos].isLetter || name[pos].isNumber) {
                    pos = name.index(after: pos)
                }
            }
            // Skip trailing separators
            while pos < name.endIndex && !name[pos].isLetter && !name[pos].isNumber {
                pos = name.index(after: pos)
            }
            let remaining = String(name[pos...])
            if !remaining.isEmpty {
                name = remaining
            }
        }

        if !tag.isEmpty {
            return "\(tag) \(name)"
        }
        return name
    }
}
