//
//  ExportAUViewController.swift
//  ConjureDSPExportAUTemplateExtension
//

import CoreAudioKit
import SwiftUI

@MainActor
public class ExportAUViewController: AUViewController, AUAudioUnitFactory {
    var audioUnit: AUAudioUnit?
    private var hostingView: NSHostingView<ExportAUMainView>?
    private var parameterState: ExportParameterState?
    private var errorPollTimer: Timer?
    private var paramCount: Int = 8

    private static let viewWidth: CGFloat = 500

    public override var preferredMinimumSize: NSSize {
        NSSize(width: 300, height: 150)
    }

    public override var preferredMaximumSize: NSSize {
        NSSize(width: 800, height: 900)
    }

    /// Compute the ideal window height based on content.
    private func computeSize(showDebug: Bool, showError: Bool) -> NSSize {
        // Header (title + gear): ~45pt
        // Divider: 1pt
        // Each param row: ~28pt
        // Footer (Made with ConjureDSP): ~30pt
        var height: CGFloat = 45 + 1 + CGFloat(paramCount) * 28 + 30
        // Padding/spacing between sections
        height += 24

        if showError {
            // Error banner: header line + scrollable text area + padding
            height += 160
        }

        if showDebug {
            // Debug pane: header + scrollable content
            height += 350
        }

        // Enforce minimum
        height = max(height, 150)

        return NSSize(width: Self.viewWidth, height: height)
    }

    public override func loadView() {
        let initial = computeSize(showDebug: false, showError: false)
        self.view = NSView(frame: NSRect(origin: .zero, size: initial))
        self.preferredContentSize = initial
    }

    nonisolated public func createAudioUnit(
        with componentDescription: AudioComponentDescription
    ) throws -> AUAudioUnit {
        return try DispatchQueue.main.sync {
            let au = try ExportAUAudioUnit(
                componentDescription: componentDescription, options: []
            )
            audioUnit = au
            return au
        }
    }

    public override func viewWillAppear() {
        super.viewWillAppear()
        guard let audioUnit else { return }
        if hostingView == nil {
            DispatchQueue.main.async { [weak self] in
                self?.configureSwiftUIView(audioUnit: audioUnit)
            }
        }
    }

    private func configureSwiftUIView(audioUnit: AUAudioUnit) {
        guard let au = audioUnit as? ExportAUAudioUnit else { return }

        let bundle = Bundle(for: type(of: self))
        let config = RuntimeConfig.load(from: bundle)

        let ps = ExportParameterState(
            paramCount: config?.effectiveParamCount ?? 8,
            paramMetadata: config?.paramMetadata,
            debugLog: au.debugLog,
            renderStats: au.renderStats,
            pluginInfo: au.pluginInfo
        )
        self.parameterState = ps
        if let tree = au.parameterTree {
            ps.attach(to: tree)
        }

        self.paramCount = config?.effectiveParamCount ?? 8
        let content = ExportAUMainView(
            parameterState: ps,
            config: config,
            pythonRuntimeMissing: au.pythonRuntimeMissing,
            loadError: au.loadError,
            onLayoutChange: { [weak self] showDebug, showError in
                self?.updateSize(showDebug: showDebug, showError: showError)
            }
        )
        let hv = NSHostingView(rootView: content)
        hv.sizingOptions = []
        hv.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(hv)
        NSLayoutConstraint.activate([
            hv.topAnchor.constraint(equalTo: self.view.topAnchor),
            hv.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            hv.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            hv.bottomAnchor.constraint(equalTo: self.view.bottomAnchor)
        ])
        hostingView = hv

        // Always poll the 1 Hz timer — it refreshes the stats snapshot for the
        // debug pane even when the preset loaded cleanly. Runtime error polling
        // is gated internally (only reports a value if the kernel has an error).
        startPollTimer(au: au, parameterState: ps)
    }

    private func startPollTimer(au: ExportAUAudioUnit, parameterState: ExportParameterState) {
        // One 1 Hz timer does double duty: refresh runtime-error string AND
        // snapshot render stats for the debug pane. Both need to run whether
        // or not the preset loaded cleanly (stats show load failures too).
        errorPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak parameterState, weak au] _ in
            guard let ps = parameterState, let au = au else { return }
            let error = au.currentKernelError()
            let snapshot = au.renderStats.snapshot()
            DispatchQueue.main.async {
                // Log new runtime errors to the debug log
                if let err = error, err != ps.runtimeError {
                    ps.debugLog.append(level: .error, category: "render.error", message: err)
                }
                ps.runtimeError = error
                ps.statsSnapshot = snapshot
            }
        }
    }

    private func updateSize(showDebug: Bool, showError: Bool) {
        let target = computeSize(showDebug: showDebug, showError: showError)
        self.preferredContentSize = target
        // Some hosts honor frame rather than preferred size — set both.
        var frame = self.view.frame
        frame.size = target
        self.view.frame = frame
    }

    deinit {
        errorPollTimer?.invalidate()
    }
}
