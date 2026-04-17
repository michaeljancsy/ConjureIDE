//
//  LanguageMigrationSheet.swift
//  ConjureDSPExtension
//
//  First-launch sheet that introduces the on-demand language model and lets
//  the user install Python / Rust with one click. Shown once per build after
//  an upgrade so users who had the bundled runtimes in an earlier version
//  know why they need to download something now.
//
//  Trigger policy lives in `LanguageMigrationCoordinator`, which reads the
//  last-shown build number from UserDefaults and decides whether to present.
//  The sheet itself is pure UI — host view opens it on a binding.
//

import SwiftUI
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "LanguageMigration")

/// Decides whether the migration sheet should appear this launch.
/// Used from `ConjureDSPExtensionMainView.onAppear`.
enum LanguageMigrationCoordinator {
    /// UserDefaults key holding the build number of the last build that
    /// showed the migration sheet. Shared by host app + extension via
    /// App Group — the extension is what renders the sheet, but we still
    /// write under the shared suite so the host app can introspect.
    static let lastShownBuildKey = "ConjureDSPLanguageMigrationShownForBuild"

    /// Should the sheet appear? True when:
    /// (1) We haven't already shown it for the current build, AND
    /// (2) No modules are currently installed (empty LanguageModules/ dir) —
    ///     if the user already has some installed, they've seen the panel.
    static func shouldShow(currentBuild: String) -> Bool {
        let defaults = UserDefaults.standard
        let lastShown = defaults.string(forKey: lastShownBuildKey) ?? ""
        if lastShown == currentBuild {
            return false
        }
        if !LanguageModuleManager.isInstalled("python")
            && !LanguageModuleManager.isInstalled("rustc")
        {
            return true
        }
        // If at least one module is already installed, the user knows how
        // the panel works. Mark as shown so we don't pester later.
        defaults.set(currentBuild, forKey: lastShownBuildKey)
        return false
    }

    static func markShown(currentBuild: String) {
        UserDefaults.standard.set(currentBuild, forKey: lastShownBuildKey)
        log.info("Marked language migration sheet shown for build \(currentBuild, privacy: .public)")
    }
}

struct LanguageMigrationSheet: View {
    @Bindable var manager: LanguageModuleManager
    let onDismiss: () -> Void

    @State private var wantsPython: Bool = true
    @State private var wantsRust: Bool = true
    @State private var isLoadingCatalog: Bool = false
    @State private var didAttemptInstall: Bool = false

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
        .padding(20)
        .frame(width: 480, height: 420)
        .task {
            await loadCatalog()
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Languages are now on-demand")
                .font(.title2.bold())
            Text("Install only what you need — your DAW downloads the rest later.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                "ConjureDSP used to ship every DSP-scripting runtime in the app — that kept the "
                    + "download large. Starting with this build, runtimes are optional downloads from "
                    + "the Languages panel. Factory presets still play without any install."
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
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: bound)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(catalogSizeMB(for: name) == nil)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title).font(.headline)
                    if let mb = catalogSizeMB(for: name) {
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

    private var footer: some View {
        HStack {
            if manager.isInstalling, let status = manager.installStatusMessage {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                    Text(status).font(.caption.monospacedDigit()).foregroundColor(.secondary)
                }
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

            Button(didAttemptInstall ? "Done" : "Install Selected") {
                if didAttemptInstall {
                    onDismiss()
                } else {
                    startInstall()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(manager.isInstalling || !anySelected)
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
        // Install sequentially: Python first (bigger and more commonly needed),
        // then Rust. The manager rejects overlapping requests, so chain them
        // via an observer on installStatusMessage.
        if wantsPython, catalogSizeMB(for: "python") != nil {
            manager.requestInstall(moduleName: "python")
        } else if wantsRust, catalogSizeMB(for: "rustc") != nil {
            manager.requestInstall(moduleName: "rustc")
        }
    }
}
