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

    /// Fallback window width when the manifest doesn't declare one. Old
    /// exports without `ui.width` in their runtime-config (or generic-slider
    /// presets that ship no `ui` block at all) fall back to this.
    private static let defaultViewWidth: CGFloat = 500

    /// Resolved window width — populated from `runtime-config.json`'s
    /// `ui.width` at `loadView` time (so the very first frame uses the
    /// right size and the host doesn't see a brief 500pt → declared-width
    /// jump). Falls back to `defaultViewWidth` when the manifest doesn't
    /// declare a width.
    private var resolvedViewWidth: CGFloat = defaultViewWidth

    public override var preferredMinimumSize: NSSize {
        NSSize(width: 300, height: 150)
    }

    public override var preferredMaximumSize: NSSize {
        // Generous cap. Authors can declare manifest.ui.width up to 1600pt
        // and manifest.ui.height up to ~1080pt without the host clamping;
        // anything past that, they're outside our supported range and the
        // host can clip if it wants. The earlier 800×900 cap clipped any
        // preset wider than 800pt (Round 8's Dyn EQ Triad declared 1200pt,
        // got squeezed back to 800pt by Ableton).
        NSSize(width: 1600, height: 1080)
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
            viewWidth: resolvedViewWidth
        )
    }

    public override func loadView() {
        // Resolve the manifest-declared dimensions up front so the window
        // opens at the right size on the very first frame.
        //
        // ExportManager writes manifest.ui.{width,height,entryHTML} into
        // runtime-config.json during export. Without reading them here in
        // loadView, computeSize falls back to (default 500pt × 320pt body)
        // for the initial preferredContentSize — and SwiftUI re-layouts
        // triggered by configureSwiftUIView later don't update
        // preferredContentSize unless an explicit `onLayoutChange` fires
        // (which only happens on debug-toggle / error-banner show). Result:
        // the window opens too small and stays too small.
        //
        // Reading the full UI block here means the window opens at exactly
        // the manifest-declared size on first paint. Old exports / generic-
        // slider presets that don't have a `ui` block in runtime-config
        // fall through to the existing defaults.
        let bundle = Bundle(for: type(of: self))
        if let cfg = RuntimeConfig.load(from: bundle) {
            if let w = cfg.ui?.width { self.resolvedViewWidth = CGFloat(w) }
            if let h = cfg.ui?.height { self.customUIHeight = h }
            // hasCustomUI is gated on customUIEntryURL being non-nil, so
            // we need the resolved URL here too — otherwise computeSize
            // would treat this as a generic-slider preset and use the
            // paramCount * 28 body-height formula instead of the
            // manifest's customUIHeight.
            self.customUIEntryURL = cfg.customUIEntryURL(in: bundle)
        }

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
            let sr = au.outputBusses[0].format.sampleRate
            mgr.sampleRate = sr > 0 ? sr : 44100.0
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
