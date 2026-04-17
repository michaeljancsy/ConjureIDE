//
//  LanguageMigrationSheet.swift
//  ConjureDSPExtension
//
//  First-launch welcome sheet. Lets the user pick which DSP-language
//  runtimes (Python, Rust) to install up front, or skip and do it later
//  from the Languages panel. Shown once per build when no modules are
//  installed yet — purely onboarding UX, not a migration from any prior
//  state.
//
//  Trigger policy lives in `LanguageMigrationCoordinator`: it reads the
//  last-shown build number from UserDefaults and decides whether to
//  present. The sheet itself is pure UI — host view opens it on a binding.
//

import SwiftUI
import os.log

// `LanguageMigrationCoordinator` lives in LanguageMigrationCoordinator.swift
// so its pure-logic policy can be unit-tested without pulling SwiftUI.

struct LanguageMigrationSheet: View {
    @Bindable var manager: LanguageModuleManager
    let onDismiss: () -> Void

    @State private var wantsPython: Bool = true
    @State private var wantsRust: Bool = true
    @State private var isLoadingCatalog: Bool = false
    @State private var didAttemptInstall: Bool = false
    /// Modules the user selected when they clicked Install that haven't yet
    /// been kicked off. Popped front-to-back as each finishes.
    @State private var installQueue: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            explanation
            languagesList
            Spacer(minLength: 0)
            Divider()
            footer
        }
        .onChange(of: manager.isInstalling) { _, nowInstalling in
            // When the current install finishes, start the next queued one.
            // Also refresh `installedModules` so row states flip to "Installed".
            if !nowInstalling {
                manager.refreshInstalledModules()
                if !installQueue.isEmpty {
                    let next = installQueue.removeFirst()
                    manager.requestInstall(moduleName: next)
                }
            }
        }
        .padding(20)
        .frame(width: 480, height: 420)
        .task {
            await loadCatalog()
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Pick your languages")
                .font(.title2.bold())
            Text("Select the languages you'd like to use.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                "ConjureDSP scripts DSP in Python or Rust. Each language's runtime is an "
                    + "optional download — install what you need below, or skip and do it later "
                    + "from the Languages panel. Factory presets keep playing either way."
            )
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

            if let sizeFootprint = totalSelectedMB {
                Text("Selected: ~\(sizeFootprint) MB total")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var languagesList: some View {
        VStack(alignment: .leading, spacing: 10) {
            row(
                name: "python",
                title: "Python",
                blurb: "Python 3.14 + numpy + scipy — for all Python-based presets.",
                bound: $wantsPython
            )
            row(
                name: "rustc",
                title: "Rust compiler",
                blurb: "Rust + wasm32-wasip1 toolchain — needed to edit or author new Rust presets. Factory Rust presets play without it.",
                bound: $wantsRust
            )
        }
        .padding(.vertical, 4)
    }

    private func row(name: String, title: String, blurb: String, bound: Binding<Bool>) -> some View {
        let installed = isInstalled(name)
        let installing = manager.isInstalling && manager.installStatusMessage?.contains(name) == true
        return HStack(alignment: .top, spacing: 10) {
            // Checkbox is disabled once the module is installed — the user
            // can't uncheck a successful install from here. Still disabled
            // if the catalog didn't load for this module.
            Toggle("", isOn: bound)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(catalogSizeMB(for: name) == nil || installed)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title).font(.headline)
                    if installed {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.green)
                    } else if installing {
                        HStack(spacing: 4) {
                            ProgressView().scaleEffect(0.45).frame(width: 12, height: 12)
                            Text("Installing…")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                    } else if let mb = catalogSizeMB(for: name) {
                        Text("(\(mb) MB)")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    } else if isLoadingCatalog {
                        Text("(loading…)")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    } else {
                        Text("(unavailable)")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.orange)
                    }
                }
                Text(blurb)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func isInstalled(_ name: String) -> Bool {
        manager.installedModules.contains { $0.name == name }
    }

    private var footer: some View {
        HStack {
            if manager.isInstalling, let status = manager.installStatusMessage {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                    Text(status).font(.caption.monospacedDigit()).foregroundColor(.secondary)
                }
            } else if selectedInstallsComplete {
                Label("All set.", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.green)
            } else if let err = manager.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(2)
            }
            Spacer()
            Button("Skip for now") { onDismiss() }
                .buttonStyle(.borderless)
                .disabled(manager.isInstalling)
                .accessibilityIdentifier("languageMigrationSkipButton")

            Button(selectedInstallsComplete || didAttemptInstall && !anySelected ? "Done" : "Install Selected") {
                if selectedInstallsComplete || didAttemptInstall {
                    onDismiss()
                } else {
                    startInstall()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(manager.isInstalling || (!selectedInstallsComplete && !anySelected))
            .accessibilityIdentifier("languageMigrationInstallButton")
        }
    }

    // MARK: - Helpers

    private var anySelected: Bool {
        (wantsPython && catalogSizeMB(for: "python") != nil)
            || (wantsRust && catalogSizeMB(for: "rustc") != nil)
    }

    private var totalSelectedMB: Int? {
        var total = 0
        var any = false
        if wantsPython, let mb = catalogSizeMB(for: "python") { total += mb; any = true }
        if wantsRust, let mb = catalogSizeMB(for: "rustc") { total += mb; any = true }
        return any ? total : nil
    }

    private func catalogSizeMB(for name: String) -> Int? {
        guard let spec = manager.catalog?.modules[name] else { return nil }
        return Int(spec.sizeMB.rounded())
    }

    private func loadCatalog() async {
        isLoadingCatalog = true
        defer { isLoadingCatalog = false }
        await manager.loadCatalog()
    }

    private func startInstall() {
        didAttemptInstall = true
        // Queue every selected-and-available module. The onChange observer on
        // `manager.isInstalling` pops the next item off as each finishes, so
        // we end up doing them sequentially without trying to fire two
        // requestInstall calls concurrently (the manager rejects those).
        var queue: [String] = []
        if wantsPython, catalogSizeMB(for: "python") != nil, !isInstalled("python") {
            queue.append("python")
        }
        if wantsRust, catalogSizeMB(for: "rustc") != nil, !isInstalled("rustc") {
            queue.append("rustc")
        }
        guard let first = queue.first else { return }
        installQueue = Array(queue.dropFirst())
        manager.requestInstall(moduleName: first)
    }

    /// True once every module the user requested has successfully installed.
    private var selectedInstallsComplete: Bool {
        guard didAttemptInstall else { return false }
        if wantsPython, catalogSizeMB(for: "python") != nil, !isInstalled("python") { return false }
        if wantsRust, catalogSizeMB(for: "rustc") != nil, !isInstalled("rustc") { return false }
        return true
    }
}
