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
    /// Resolved entry HTML for a custom UI (when the preset shipped one).
    /// Null means the AU falls back to the generic slider layout. Cached at
    /// `configureSwiftUIView` time so `computeSize` doesn't re-stat the FS.
    private var customUIEntryURL: URL?
    /// Preferred height the preset's manifest asked for. Only honored when
    /// `customUIEntryURL` resolved to a real file.
    private var customUIHeight: Int?
    /// Audio capture pipeline for the custom UI. Owned by the view
    /// controller (not the view) so it survives DAW-driven view
    /// re-creation. Created lazily on first view setup since we need
    /// the kernel handle from the AU.
    private var captureManager: ExportAudioCaptureManager?

    private static let viewWidth: CGFloat = 500

    public override var preferredMinimumSize: NSSize {
        NSSize(width: 300, height: 150)
    }

    public override var preferredMaximumSize: NSSize {
        NSSize(width: 800, height: 900)
    }

    /// Compute the ideal window height based on content. Values here are
    /// conservative upper bounds — underestimating causes the title/gear to
    /// clip at the top or "Made with ConjureDSP" to disappear at the bottom
    /// when the DAW honors `preferredContentSize`. The earlier 45/30 values
    /// were short by ~15pt because they didn't account for SwiftUI's
    /// implicit spacing + `.padding(.top, 12)` / `.padding(.bottom, 8)` in
    /// the main view.
    private func computeSize(showDebug: Bool, showError: Bool) -> NSSize {
        ExportAUWindowSizing.computeSize(
            showDebug: showDebug,
            showError: showError,
            hasCustomUI: customUIEntryURL != nil,
            customUIHeight: customUIHeight,
            paramCount: paramCount,
            viewWidth: Self.viewWidth
        )
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
        // Resolve the custom UI once per view setup so the SwiftUI body
        // stays pure and doesn't re-stat the filesystem on every render.
        // If either hasCustomUI is false or ui/index.html is missing from
        // Resources, the view falls back to generic sliders.
        self.customUIEntryURL = config?.customUIEntryURL(in: bundle)
        self.customUIHeight = config?.ui?.height

        // Stand up the capture manager for custom UIs that subscribe to
        // audio.onFrame. Kernel handle comes from the AU; host NSView is
        // this controller's view so the display link has a render target.
        // Only instantiated when we're actually showing a custom UI —
        // there's no point spinning it up for the generic slider path.
        if self.customUIEntryURL != nil {
            let mgr = self.captureManager ?? ExportAudioCaptureManager()
            mgr.kernel = au.kernelRef
            mgr.hostView = self.view
            self.captureManager = mgr
        }

        let content = ExportAUMainView(
            parameterState: ps,
            config: config,
            customUIEntryURL: self.customUIEntryURL,
            captureManager: self.captureManager,
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
