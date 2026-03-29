//
//  PackageManagerView.swift
//  ConjureDSPExtension
//
//  Package manager UI for installing/removing Python packages.
//  Shown as a popover from the toolbar. Communicates with the
//  companion app via PackageInstallManager.
//

import SwiftUI
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "PackageManagerUI")

struct PackageManagerView: View {
    @Bindable var installManager: PackageInstallManager
    let onDone: () -> Void
    /// Called after a successful install/uninstall so the AU can reload the current script.
    var onPackagesChanged: (() -> Void)?

    @State private var packageSpec = ""
    @State private var searchText = ""
    @State private var searchResults: [PyPIPackageInfo] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var confirmUninstall: String?

    struct PyPIPackageInfo: Identifiable {
        var id: String { name }
        let name: String
        let version: String
        let summary: String
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

            Divider()

            // Search PyPI
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search PyPI...", text: $searchText)
                    .textFieldStyle(.plain)
                    .onSubmit { searchPyPI() }
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
                // Debounced search
                searchTask?.cancel()
                if newValue.count >= 2 {
                    searchTask = Task {
                        try? await Task.sleep(for: .milliseconds(400))
                        guard !Task.isCancelled else { return }
                        await MainActor.run { searchPyPI() }
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

                    // Installed packages
                    sectionHeader("Installed")

                    if installManager.installedPackages.isEmpty {
                        Text("No user-installed packages")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(installManager.installedPackages) { pkg in
                            installedPackageRow(pkg)
                        }
                    }
                }
            }

            Divider()

            // Install input
            VStack(spacing: 8) {
                HStack {
                    TextField("Package name (e.g. pedalboard==0.9.16)", text: $packageSpec)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { installPackage() }
                    Button("Install") { installPackage() }
                        .disabled(packageSpec.trimmingCharacters(in: .whitespaces).isEmpty || installManager.isInstalling)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }

                // Status
                if installManager.isInstalling {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text(installManager.installStatusMessage ?? "Installing...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if let error = installManager.lastError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 380, height: 420)
        .onAppear {
            installManager.refreshInstalledPackages()
        }
        .alert("Uninstall Package", isPresented: .init(
            get: { confirmUninstall != nil },
            set: { if !$0 { confirmUninstall = nil } }
        )) {
            Button("Cancel", role: .cancel) { confirmUninstall = nil }
            Button("Uninstall", role: .destructive) {
                if let name = confirmUninstall {
                    installManager.requestUninstall(packageName: name)
                }
                confirmUninstall = nil
            }
        } message: {
            if let name = confirmUninstall {
                Text("Remove \(name) from user packages?")
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

    private func installedPackageRow(_ pkg: PackageInstallManager.InstalledPackage) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(pkg.name)
                    .font(.system(.body, design: .monospaced))
                Text(pkg.version)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(action: { confirmUninstall = pkg.name }) {
                Image(systemName: "trash")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func searchResultRow(_ pkg: PyPIPackageInfo) -> some View {
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
                packageSpec = "\(pkg.name)==\(pkg.version)"
                installPackage()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(installManager.isInstalling)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func installPackage() {
        let spec = packageSpec.trimmingCharacters(in: .whitespaces)
        guard !spec.isEmpty else { return }
        installManager.requestInstall(packages: [spec])
        packageSpec = ""
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

            // Use PyPI JSON API to look up a specific package
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
                    searchResults = [PyPIPackageInfo(name: name, version: version, summary: summary)]
                }
            } catch {
                log.warning("PyPI search failed: \(error.localizedDescription, privacy: .public)")
                searchResults = []
            }
        }
    }
}
