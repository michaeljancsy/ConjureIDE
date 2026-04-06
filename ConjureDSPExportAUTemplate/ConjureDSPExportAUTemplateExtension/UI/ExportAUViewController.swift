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

    /// Base window size. Used when the debug pane is hidden.
    private static let collapsedSize = NSSize(width: 400, height: 300)
    /// Expanded size when the debug pane is visible (adds ~340pt for the pane).
    private static let expandedSize = NSSize(width: 400, height: 640)

    public override var preferredMinimumSize: NSSize {
        NSSize(width: 300, height: 200)
    }

    public override var preferredMaximumSize: NSSize {
        NSSize(width: 800, height: 700)
    }

    public override func loadView() {
        self.view = NSView(frame: NSRect(origin: .zero, size: Self.collapsedSize))
        self.preferredContentSize = Self.collapsedSize
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

        let content = ExportAUMainView(
            parameterState: ps,
            config: config,
            pythonRuntimeMissing: au.pythonRuntimeMissing,
            loadError: au.loadError,
            onDebugPaneToggle: { [weak self] visible in
                self?.setDebugPaneVisible(visible)
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
                ps.runtimeError = error
                ps.statsSnapshot = snapshot
            }
        }
    }

    private func setDebugPaneVisible(_ visible: Bool) {
        let target = visible ? Self.expandedSize : Self.collapsedSize
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
