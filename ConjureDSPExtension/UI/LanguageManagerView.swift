//
//  LanguageManagerView.swift
//  ConjureDSPExtension
//
//  Settings panel for installing / uninstalling optional DSP-language runtime
//  modules (Python, Rust compiler, Lua, libpd, WASI SDK, CMajor, ...).
//  Mirrors the UX of PackageManagerView but targets language runtimes rather
//  than per-language packages.
//

import SwiftUI
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "LanguageManagerUI")

struct LanguageManagerView: View {
    @Bindable var manager: LanguageModuleManager
    let onDone: () -> Void

    /// Fired after a successful install/uninstall so callers can reload
    /// the active script if it was blocked waiting on a module.
    var onModulesChanged: (() -> Void)?

    @State private var isLoadingCatalog = false
    @State private var confirmUninstall: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 520, height: 480)
        .task {
            await refreshCatalog()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Language Modules")
                .font(.headline)
            if isLoadingCatalog {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 16, height: 16)
            }
            Spacer()
            Button {
                Task { await refreshCatalog() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(isLoadingCatalog || manager.isInstalling)
            .accessibilityIdentifier("languageManagerRefreshButton")

            Button("Done") { onDone() }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("languageManagerDoneButton")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let catalog = manager.catalog {
            if catalog.modules.isEmpty {
                emptyState(message: "No language modules are available yet.")
            } else {
                List {
                    ForEach(sortedModuleNames(catalog: catalog), id: \.self) { name in
                        if let spec = catalog.modules[name] {
                            moduleRow(name: name, spec: spec)
                        }
                    }
                }
                .listStyle(.inset)
            }
        } else if isLoadingCatalog {
            emptyState(message: "Loading catalog...")
        } else if let error = manager.lastError {
            emptyState(message: error)
        } else {
            emptyState(message: "Tap ↻ to load the catalog.")
        }
    }

    private func emptyState(message: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Text(message)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func moduleRow(name: String, spec: LanguageModuleSpec) -> some View {
        let installed = manager.installedModules.first { $0.name == name }

        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(name).font(.headline.monospaced())
                    if let installed {
                        Text("v\(installed.version)")
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                        if installed.version != spec.version {
                            Text("→ v\(spec.version)")
                                .font(.caption.monospaced())
                                .foregroundColor(.accentColor)
                        }
                    } else {
                        Text("v\(spec.version)")
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                    }
                }
                if let description = spec.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 10) {
                    Text(String(format: "%.0f MB", spec.sizeMB))
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                    if spec.licenseGate != nil {
                        Label("License required", systemImage: "lock.fill")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
            }

            Spacer()

            if let installed {
                if installed.version != spec.version {
                    Button("Update") {
                        manager.requestInstall(moduleName: name)
                    }
                    .disabled(manager.isInstalling)
                }
                Button("Remove", role: .destructive) {
                    confirmUninstall = name
                }
                .disabled(manager.isInstalling)
            } else {
                Button("Install") {
                    manager.requestInstall(moduleName: name)
                }
                .disabled(manager.isInstalling || spec.licenseGate != nil)
            }
        }
        .padding(.vertical, 4)
        .confirmationDialog(
            "Remove \(confirmUninstall ?? "module")?",
            isPresented: Binding(
                get: { confirmUninstall == name },
                set: { if !$0 { confirmUninstall = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let target = confirmUninstall {
                    manager.requestUninstall(moduleName: target)
                }
                confirmUninstall = nil
            }
            Button("Cancel", role: .cancel) { confirmUninstall = nil }
        } message: {
            Text("Any presets using this module will need to reinstall it before they can run.")
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            if let status = manager.installStatusMessage {
                HStack(spacing: 6) {
                    if manager.isInstalling {
                        ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                    }
                    Text(status)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            } else if let error = manager.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
            } else {
                Text(diskSummary)
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private func refreshCatalog() async {
        isLoadingCatalog = true
        defer { isLoadingCatalog = false }
        manager.clearError()
        await manager.loadCatalog()
        manager.refreshInstalledModules()
    }

    private var diskSummary: String {
        let totalBytes = manager.installedModules.reduce(UInt64(0)) { $0 + $1.installedBytes }
        let mb = Double(totalBytes) / (1024 * 1024)
        return "\(manager.installedModules.count) installed · \(String(format: "%.0f MB", mb)) on disk"
    }

    private func sortedModuleNames(catalog: LanguageModuleCatalog) -> [String] {
        catalog.modules.keys.sorted()
    }
}

