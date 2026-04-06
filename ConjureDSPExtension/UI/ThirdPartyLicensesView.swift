import SwiftUI

// MARK: - Data Model

private struct LicenseEntry: Decodable, Identifiable {
    let name: String
    let version: String?
    let license: String?
    let url: String?
    let text: String?

    var id: String { "\(name)-\(version ?? "")" }

    var displayVersion: String? {
        guard let v = version, !v.isEmpty else { return nil }
        return v
    }
}

private struct LicenseCategory: Decodable, Identifiable {
    let name: String
    let entries: [LicenseEntry]

    var id: String { name }
}

private struct LicensesData: Decodable {
    let categories: [LicenseCategory]
}

// MARK: - Settings Entry Point

struct ThirdPartyLicensesView: View {
    @State private var showingLicenses = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About")
                .font(.headline)
            Button("Open Source Licenses") {
                showingLicenses = true
            }
            .buttonStyle(.link)
            .accessibilityIdentifier("openLicensesButton")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showingLicenses) {
            LicensesSheet()
        }
    }
}

// MARK: - Licenses Sheet

private struct LicensesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var data: LicensesData?
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Open Source Licenses")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            // Search
            TextField("Search", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.vertical, 8)

            // Content
            if let data {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(filteredCategories(data.categories)) { category in
                            LicenseCategoryView(category: category, searchText: searchText)
                        }
                    }
                    .padding()
                }
            } else {
                Spacer()
                ProgressView()
                Spacer()
            }
        }
        .frame(width: 600, height: 500)
        .task {
            data = loadLicenses()
        }
    }

    private func filteredCategories(_ categories: [LicenseCategory]) -> [LicenseCategory] {
        guard !searchText.isEmpty else { return categories }
        let query = searchText.lowercased()
        return categories.compactMap { category in
            let filtered = category.entries.filter {
                $0.name.lowercased().contains(query) ||
                ($0.license?.lowercased().contains(query) ?? false)
            }
            guard !filtered.isEmpty else { return nil }
            return LicenseCategory(name: category.name, entries: filtered)
        }
    }

    private func loadLicenses() -> LicensesData? {
        guard let url = Bundle(for: AudioUnitViewController.self)
            .url(forResource: "licenses", withExtension: "json"),
              let jsonData = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(LicensesData.self, from: jsonData)
    }
}

// MARK: - Category View

private struct LicenseCategoryView: View {
    let category: LicenseCategory
    let searchText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(category.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            ForEach(category.entries) { entry in
                LicenseEntryView(entry: entry)
            }
        }
    }
}

// MARK: - Entry View

private struct LicenseEntryView: View {
    let entry: LicenseEntry
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Text(entry.name)
                        .font(.system(size: 12))
                    if let version = entry.displayVersion {
                        Text(version)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if let license = entry.license {
                        Text(license)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 3)

            if isExpanded, let text = entry.text {
                Text(text)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 16)
                    .padding(.vertical, 6)
                    .frame(maxHeight: 200)
            }
        }
    }
}
