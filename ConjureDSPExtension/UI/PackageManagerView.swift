//
//  PackageManagerView.swift
//  ConjureDSPExtension
//
//  Package manager UI for installing/removing Python packages and Rust crates.
//  Shown as a popover from the toolbar. Communicates with the
//  companion app via PackageInstallManager / CrateInstallManager.
//

import SwiftUI
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "PackageManagerUI")

struct PackageManagerView: View {
    @Bindable var installManager: PackageInstallManager
    @Bindable var crateInstallManager: CrateInstallManager
    let onDone: () -> Void
    /// Called after a successful install/uninstall so the AU can reload the current script.
    var onPackagesChanged: (() -> Void)?

    /// Which language tab is active. Defaults to current script language.
    var initialLanguage: PackageLanguage = .python

    enum PackageLanguage: String, CaseIterable {
        case python = "Python"
        case rust = "Rust"
    }

    @State private var language: PackageLanguage?
    @State private var packageSpec = ""
    @State private var searchText = ""
    @State private var searchResults: [SearchResult] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var confirmUninstall: String?

    struct SearchResult: Identifiable {
        var id: String { name }
        let name: String
        let version: String
        let summary: String
    }

    private var activeLanguage: PackageLanguage {
        language ?? initialLanguage
    }

    private var isInstalling: Bool {
        activeLanguage == .python ? installManager.isInstalling : crateInstallManager.isInstalling
    }

    private var statusMessage: String? {
        activeLanguage == .python ? installManager.installStatusMessage : crateInstallManager.installStatusMessage
    }

    private var lastError: String? {
        activeLanguage == .python ? installManager.lastError : crateInstallManager.lastError
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Packages")
                    .font(.headline)
                Spacer()
                Button("Done") { onDone() }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Language picker
            Picker("Language", selection: Binding(
                get: { activeLanguage },
                set: { newValue in
                    language = newValue
                    searchText = ""
                    searchResults = []
                    packageSpec = ""
                }
            )) {
                ForEach(PackageLanguage.allCases, id: \.self) { lang in
                    Text(lang.rawValue).tag(lang)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.bottom, 4)

            Divider()

            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField(activeLanguage == .python ? "Search PyPI..." : "Search crates.io...",
                          text: $searchText)
                    .textFieldStyle(.plain)
                    .onSubmit { performSearch() }
                if !searchText.isEmpty {
                    Button(action: {
                        searchText = ""
                        searchResults = []
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .onChange(of: searchText) { _, newValue in
                searchTask?.cancel()
                if newValue.count >= 2 {
                    searchTask = Task {
                        try? await Task.sleep(for: .milliseconds(400))
                        guard !Task.isCancelled else { return }
                        await MainActor.run { performSearch() }
                    }
                } else {
                    searchResults = []
                }
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Search results
                    if !searchResults.isEmpty {
                        sectionHeader("Search Results")
                        ForEach(searchResults) { pkg in
                            searchResultRow(pkg)
                        }
                        Divider().padding(.vertical, 4)
                    }

                    if activeLanguage == .python {
                        pythonPackageList
                    } else {
                        rustCrateList
                    }
                }
            }

            Divider()

            // Install input
            VStack(spacing: 8) {
                HStack {
                    TextField(
                        activeLanguage == .python
                            ? "Package name (e.g. pedalboard==0.9.16)"
                            : "Crate name (e.g. dasp = \"0.11\")",
                        text: $packageSpec
                    )
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { installPackage() }
                    Button("Install") { installPackage() }
                        .disabled(packageSpec.trimmingCharacters(in: .whitespaces).isEmpty || isInstalling)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }

                if isInstalling {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text(statusMessage ?? "Installing...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if let error = lastError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                if activeLanguage == .rust {
                    Text("Crates are compiled from source for WebAssembly. First install may take 1–2 minutes.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(12)
        }
        .frame(width: 380, height: 460)
        .onAppear {
            installManager.refreshInstalledPackages()
            crateInstallManager.refreshInstalledCrates()
        }
        .alert("Uninstall", isPresented: .init(
            get: { confirmUninstall != nil },
            set: { if !$0 { confirmUninstall = nil } }
        )) {
            Button("Cancel", role: .cancel) { confirmUninstall = nil }
            Button("Uninstall", role: .destructive) {
                if let name = confirmUninstall {
                    if activeLanguage == .python {
                        installManager.requestUninstall(packageName: name)
                    } else {
                        crateInstallManager.requestUninstall(crateName: name)
                    }
                }
                confirmUninstall = nil
            }
        } message: {
            if let name = confirmUninstall {
                Text("Remove \(name)?")
            }
        }
    }

    // MARK: - Python package list

    @ViewBuilder
    private var pythonPackageList: some View {
        let bundled = installManager.installedPackages.filter(\.isBundled)
        let userInstalled = installManager.installedPackages.filter { !$0.isBundled }

        if !bundled.isEmpty {
            sectionHeader("Built-in")
            ForEach(bundled) { pkg in
                installedRow(name: pkg.name, version: pkg.version, isBundled: true)
            }
        }

        if !userInstalled.isEmpty {
            sectionHeader("User-installed")
            ForEach(userInstalled) { pkg in
                installedRow(name: pkg.name, version: pkg.version, isBundled: false)
            }
        }
    }

    // MARK: - Rust crate list

    @ViewBuilder
    private var rustCrateList: some View {
        let bundled = crateInstallManager.installedCrates.filter(\.isBundled)
        let userInstalled = crateInstallManager.installedCrates.filter { !$0.isBundled }

        if !bundled.isEmpty {
            sectionHeader("Built-in")
            ForEach(bundled) { crate in
                installedRow(name: crate.name, version: crate.version, isBundled: true)
            }
        }

        if !userInstalled.isEmpty {
            sectionHeader("User-installed")
            ForEach(userInstalled) { crate in
                installedRow(name: crate.name, version: crate.version, isBundled: false)
            }
        }
    }

    // MARK: - Rows

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.bold())
            .foregroundColor(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    private func installedRow(name: String, version: String, isBundled: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(.body, design: .monospaced))
                Text(version)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if !isBundled {
                Button(action: { confirmUninstall = name }) {
                    Image(systemName: "trash")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func searchResultRow(_ pkg: SearchResult) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(pkg.name)
                    .font(.system(.body, design: .monospaced))
                if !pkg.summary.isEmpty {
                    Text(pkg.summary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(pkg.version)
                .font(.caption)
                .foregroundColor(.secondary)
            Button("Install") {
                if activeLanguage == .python {
                    packageSpec = "\(pkg.name)==\(pkg.version)"
                } else {
                    packageSpec = "\(pkg.name) = \"\(pkg.version)\""
                }
                installPackage()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isInstalling)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func installPackage() {
        let spec = packageSpec.trimmingCharacters(in: .whitespaces)
        guard !spec.isEmpty else { return }

        if activeLanguage == .python {
            installManager.requestInstall(packages: [spec])
        } else {
            // Parse "name = version" or "name = \"version\"" or just "name"
            let (name, version) = parseCrateSpec(spec)
            crateInstallManager.requestInstall(crates: [
                CrateInstallManager.CrateSpec(name: name, version: version)
            ])
        }
        packageSpec = ""
    }

    /// Parse user input like "dasp = 0.11" or "dasp = \"0.11\"" or "dasp" into (name, version).
    private func parseCrateSpec(_ input: String) -> (name: String, version: String) {
        let parts = input.split(separator: "=", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
        }
        if parts.count == 2 {
            return (parts[0], parts[1])
        }
        return (input.trimmingCharacters(in: .whitespaces), "*")
    }

    private func performSearch() {
        if activeLanguage == .python {
            searchPyPI()
        } else {
            searchCratesIO()
        }
    }

    private func searchPyPI() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            searchResults = []
            return
        }

        isSearching = true
        Task { @MainActor in
            defer { isSearching = false }

            guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: "https://pypi.org/pypi/\(encoded)/json") else { return }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    searchResults = []
                    return
                }
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let info = json["info"] as? [String: Any],
                   let name = info["name"] as? String,
                   let version = info["version"] as? String {
                    let summary = (info["summary"] as? String) ?? ""
                    searchResults = [SearchResult(name: name, version: version, summary: summary)]
                }
            } catch {
                log.warning("PyPI search failed: \(error.localizedDescription, privacy: .public)")
                searchResults = []
            }
        }
    }

    private func searchCratesIO() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            searchResults = []
            return
        }

        isSearching = true
        Task { @MainActor in
            defer { isSearching = false }

            guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://crates.io/api/v1/crates?q=\(encoded)&per_page=10") else { return }

            var request = URLRequest(url: url)
            request.setValue("ConjureDSP/1.0 (https://conjuredsp.com)", forHTTPHeaderField: "User-Agent")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    searchResults = []
                    return
                }
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let crates = json["crates"] as? [[String: Any]] {
                    searchResults = crates.compactMap { crate in
                        guard let name = crate["name"] as? String,
                              let version = crate["max_version"] as? String else { return nil }
                        let description = (crate["description"] as? String) ?? ""
                        return SearchResult(name: name, version: version, summary: description)
                    }
                }
            } catch {
                log.warning("crates.io search failed: \(error.localizedDescription, privacy: .public)")
                searchResults = []
            }
        }
    }
}
