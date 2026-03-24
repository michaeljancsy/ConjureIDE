import SwiftUI

/// Popover browser for finding and selecting presets with a spreadsheet-style
/// table layout. Each column header has a filter dropdown for its data.
struct PresetBrowserView: View {
    let presets: [Preset]
    let currentPreset: Preset?
    let isModified: Bool
    let hasRepoPresets: Bool
    let onSelectPreset: (Preset) -> Void
    let onBrowseCommunity: () -> Void
    let onImportURL: () -> Void
    let onDismiss: () -> Void

    @State private var searchText = ""
    @State private var selectedCategories: Set<PresetCategory> = []
    @State private var selectedLanguages: Set<ScriptLanguage> = Set(ScriptLanguage.allCases)
    @State private var selectedSources: Set<SourceFilter> = Set(SourceFilter.allCases)
    @State private var hoveredPresetID: String?

    enum SourceFilter: String, CaseIterable, Hashable {
        case factory = "Factory"
        case user = "User"
        case repo = "Repo"
    }

    // MARK: - Column widths

    private static let categoryWidth: CGFloat = 100
    private static let languageWidth: CGFloat = 65
    private static let sourceWidth: CGFloat = 60

    // MARK: - Filtering

    private var filteredPresets: [Preset] {
        presets.filter { preset in
            // Source filter
            let sourceMatch: Bool
            switch preset.source {
            case .factory: sourceMatch = selectedSources.contains(.factory)
            case .user: sourceMatch = selectedSources.contains(.user)
            case .repo: sourceMatch = selectedSources.contains(.repo)
            }
            guard sourceMatch else { return false }

            // Language filter
            guard selectedLanguages.contains(preset.language) else { return false }

            // Category filter (empty = show all)
            if !selectedCategories.isEmpty {
                guard let cat = preset.category, selectedCategories.contains(cat) else { return false }
            }

            // Search filter
            if !searchText.isEmpty {
                let query = searchText.lowercased()
                let nameMatch = preset.name.lowercased().contains(query)
                let categoryMatch = preset.category?.displayName.lowercased().contains(query) ?? false
                let descMatch = preset.descriptionText?.lowercased().contains(query) ?? false
                let authorMatch = preset.author?.lowercased().contains(query) ?? false
                guard nameMatch || categoryMatch || descMatch || authorMatch else { return false }
            }

            return true
        }
    }

    /// Categories that actually have presets (for showing relevant filter options).
    private var availableCategories: [PresetCategory] {
        let cats = Set(presets.compactMap(\.category))
        return PresetCategory.allCases.filter { cats.contains($0) }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Presets")
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

            // Column headers with filters
            columnHeaderRow

            Divider()

            // Table rows
            if filteredPresets.isEmpty {
                Spacer()
                Text(searchText.isEmpty ? "No matching presets" : "No results for \u{201C}\(searchText)\u{201D}")
                    .foregroundColor(.secondary)
                    .font(.subheadline)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredPresets.enumerated()), id: \.element.id) { index, preset in
                            presetRow(preset, index: index)
                        }
                    }
                }
            }

            Divider()

            // Bottom bar
            HStack(spacing: 12) {
                Button(action: {
                    onDismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        onBrowseCommunity()
                    }
                }) {
                    Label("Browse Community\u{2026}", systemImage: "globe")
                        .font(.caption)
                }
                .buttonStyle(.borderless)

                Button(action: {
                    onDismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        onImportURL()
                    }
                }) {
                    Label("Import from URL\u{2026}", systemImage: "link")
                        .font(.caption)
                }
                .buttonStyle(.borderless)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 480, height: 460)
    }

    // MARK: - Column Header Row

    private var columnHeaderRow: some View {
        HStack(spacing: 0) {
            // Name column (flexible)
            Text("Name")
                .font(.caption.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)

            // Category column with filter
            ColumnFilterMenu(
                label: "Category",
                isFiltered: !selectedCategories.isEmpty
            ) {
                Button(action: {
                    selectedCategories.removeAll()
                }) {
                    HStack {
                        Text("All")
                        Spacer()
                        if selectedCategories.isEmpty {
                            Image(systemName: "checkmark")
                        }
                    }
                }

                Divider()

                ForEach(availableCategories) { category in
                    Button(action: {
                        if selectedCategories.contains(category) {
                            selectedCategories.remove(category)
                        } else {
                            selectedCategories.insert(category)
                        }
                    }) {
                        HStack {
                            Text(category.displayName)
                            Spacer()
                            if selectedCategories.contains(category) {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            .frame(width: Self.categoryWidth, alignment: .leading)

            // Language column with filter
            ColumnFilterMenu(
                label: "Lang",
                isFiltered: selectedLanguages.count < ScriptLanguage.allCases.count
            ) {
                ForEach(ScriptLanguage.allCases, id: \.self) { lang in
                    Button(action: { toggleLanguage(lang) }) {
                        HStack {
                            Text(lang == .python ? "Python" : "Rust")
                            Spacer()
                            if selectedLanguages.contains(lang) {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            .frame(width: Self.languageWidth, alignment: .leading)

            // Source column with filter
            ColumnFilterMenu(
                label: "Source",
                isFiltered: {
                    let visibleSources: Set<SourceFilter> = hasRepoPresets
                        ? [.factory, .user, .repo]
                        : [.factory, .user]
                    return !visibleSources.isSubset(of: selectedSources)
                }()
            ) {
                Button(action: { toggleSource(.factory) }) {
                    HStack {
                        Text("Factory")
                        Spacer()
                        if selectedSources.contains(.factory) {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                Button(action: { toggleSource(.user) }) {
                    HStack {
                        Text("User")
                        Spacer()
                        if selectedSources.contains(.user) {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                if hasRepoPresets {
                    Button(action: { toggleSource(.repo) }) {
                        HStack {
                            Text("Repo")
                            Spacer()
                            if selectedSources.contains(.repo) {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            .frame(width: Self.sourceWidth, alignment: .leading)
        }
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.08))
    }

    // MARK: - Preset Row

    @ViewBuilder
    private func presetRow(_ preset: Preset, index: Int) -> some View {
        let isCurrent = currentPreset?.id == preset.id
        let isHovered = hoveredPresetID == preset.id
        let isOddRow = index % 2 == 1

        Button(action: { onSelectPreset(preset) }) {
            HStack(spacing: 0) {
                // Name column
                HStack(spacing: 4) {
                    if isCurrent {
                        Image(systemName: "checkmark")
                            .font(.caption2)
                            .foregroundColor(.accentColor)
                            .frame(width: 12)
                        if isModified {
                            Text("*")
                                .font(.caption.bold())
                                .foregroundColor(.orange)
                                .frame(width: 6)
                        }
                    } else {
                        // Reserve same width as checkmark (12) + modified asterisk (6)
                        // so all rows align regardless of current/modified state
                        Spacer().frame(width: 12)
                    }

                    Text(preset.name)
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)

                // Category column
                Text(preset.category?.displayName ?? "\u{2014}")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(width: Self.categoryWidth, alignment: .leading)

                // Language column
                Text(preset.language == .rust ? "Rust" : "Python")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: Self.languageWidth, alignment: .leading)

                // Source column
                Text(sourceLabel(for: preset))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: Self.sourceWidth, alignment: .leading)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                isCurrent
                    ? Color.accentColor.opacity(0.12)
                    : isHovered
                        ? Color.secondary.opacity(0.08)
                        : isOddRow
                            ? Color.secondary.opacity(0.03)
                            : Color.clear
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredPresetID = hovering ? preset.id : nil
        }
    }

    // MARK: - Helpers

    private func sourceLabel(for preset: Preset) -> String {
        switch preset.source {
        case .factory: return "Factory"
        case .user: return "User"
        case .repo: return "Repo"
        }
    }

    private func toggleLanguage(_ lang: ScriptLanguage) {
        if selectedLanguages.contains(lang) {
            if selectedLanguages.count > 1 {
                selectedLanguages.remove(lang)
            }
        } else {
            selectedLanguages.insert(lang)
        }
    }

    private func toggleSource(_ source: SourceFilter) {
        if selectedSources.contains(source) {
            if selectedSources.count > 1 {
                selectedSources.remove(source)
            }
        } else {
            selectedSources.insert(source)
        }
    }
}

// MARK: - Column Filter Menu

/// A column header label with a funnel icon that opens a filter menu.
private struct ColumnFilterMenu<MenuContent: View>: View {
    let label: String
    let isFiltered: Bool
    @ViewBuilder let menuContent: () -> MenuContent

    var body: some View {
        Menu {
            menuContent()
        } label: {
            HStack(spacing: 2) {
                Text(label)
                    .font(.caption.bold())
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 8))
                    .foregroundColor(isFiltered ? .accentColor : .secondary)
            }
            .foregroundColor(isFiltered ? .accentColor : .primary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }
}
