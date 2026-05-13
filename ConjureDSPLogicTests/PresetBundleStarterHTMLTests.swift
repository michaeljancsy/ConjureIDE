import Foundation
import Testing

struct PresetBundleStarterHTMLTests {

    @Test func starterHTMLEmitsLayoutContainer() {
        let html = PresetBundle.starterIndexHTML()
        #expect(html.contains("class=\"conjure-ui\""),
                "Starter HTML must wrap controls in a .conjure-ui container")
        #expect(html.contains(".conjure-ui {"),
                "Starter HTML must define a .conjure-ui rule")
        #expect(html.contains("flex-direction: column"),
                "Starter HTML's container should stack controls vertically")
        #expect(html.contains("gap: 12px"),
                "Starter HTML's container should give controls breathing room")
        #expect(html.contains("padding: 12px"),
                "Starter HTML's container should pad away from window edges")
    }

    @Test func starterHTMLEmitsBaselineMinSizes() {
        let html = PresetBundle.starterIndexHTML()
        #expect(html.contains("cdp-slider { min-height: 24px; min-width: 100px; }"),
                "cdp-slider min-size baseline missing — layout-density smoke test will fail")
        #expect(html.contains("cdp-knob"),
                "cdp-knob baseline missing")
        #expect(html.contains("min-width: 40px"),
                "cdp-knob min-width baseline missing")
        #expect(html.contains("cdp-xy"),
                "cdp-xy baseline missing")
        #expect(html.contains("min-width: 80px"),
                "cdp-xy / cdp-choice min-width baseline missing")
        #expect(html.contains("cdp-toggle"),
                "cdp-toggle baseline missing")
        #expect(html.contains("cdp-choice"),
                "cdp-choice baseline missing")
    }

    // MARK: - audioFrames spectrum scaffold

    @Test func starterHTMLDefaultOmitsSpectrumScaffold() {
        // Default (audioFrames=false): no canvas, no spectrum script.
        // Authors who didn't opt into ui_audio_frames shouldn't see any
        // of the FFT machinery in their fresh scaffold.
        let html = PresetBundle.starterIndexHTML()
        #expect(!html.contains("<canvas"),
                "Default scaffold must not include a <canvas> element")
        #expect(!html.contains("SPEC_DECAY"),
                "Default scaffold must not include the spectrum scaffold")
        #expect(!html.contains("ingestSpectrum"),
                "Default scaffold must not include ingestSpectrum")
        #expect(!html.contains("audio.onFrame"),
                "Default scaffold must not subscribe to audio frames")
    }

    @Test func starterHTMLAudioFramesIncludesSpectrumScaffold() {
        let html = PresetBundle.starterIndexHTML(audioFrames: true)
        #expect(html.contains("<canvas id=\"spec\""),
                "audioFrames scaffold must include the spectrum canvas")
        #expect(html.contains("width=\"480\""),
                "Canvas must declare an explicit backing-buffer width")
        #expect(html.contains("height=\"120\""),
                "Canvas must declare an explicit backing-buffer height")
        #expect(html.contains("#spec { display: block; width: 100%; height: 120px; }"),
                "audioFrames scaffold must include a CSS rule that makes the canvas visible at panel width")
        #expect(html.contains("function ingestSpectrum"),
                "audioFrames scaffold must define ingestSpectrum")
        #expect(html.contains("function scheduleRedraw"),
                "audioFrames scaffold must define scheduleRedraw (rAF coalescer)")
        #expect(html.contains("function draw"),
                "audioFrames scaffold must define draw() — the ONLY function scheduleRedraw calls")
        #expect(html.contains("requestAnimationFrame"),
                "scheduleRedraw must rAF-coalesce")
        #expect(html.contains("SPEC_DECAY = 0.85"),
                "Peak-hold decay constant must match the canonical eq3 tuning")
        #expect(html.contains("new Float32Array(n).fill(SPEC_FLOOR)"),
                "Ingest must pre-fill prev with SPEC_FLOOR to avoid the -13.5 dB startup pop")
        #expect(html.contains("frame.sampleRate"),
                "Snippet must read sample rate from the frame, not hardcode 48000")
        #expect(html.contains("{ fft: true }"),
                "onFrame subscription must opt into FFT bins")
    }

    @Test func starterHTMLAudioFramesOmitsEq3Throttle() {
        // The eq3 source uses a 33 ms throttle on spectrum redraws because
        // it competes with parameter-curve redraws on knob drag. A pure
        // analyzer scaffold has no such competition — unthrottled rAF is
        // correct. PR #323 (the docs half) makes the same call. Pin the
        // decision so a future "copy eq3 verbatim" refactor can't quietly
        // reintroduce it.
        let html = PresetBundle.starterIndexHTML(audioFrames: true)
        #expect(!html.contains("SPEC_THROTTLE_MS"),
                "Scaffold must not name a throttle constant")
        #expect(!html.contains("lastSpecTickRedraw"),
                "Scaffold must not throttle spectrum redraws")
        #expect(!html.contains("performance.now()"),
                "Scaffold must not use performance.now() — that's the throttle marker")
    }

    @Test func starterHTMLAudioFramesDrawIsOnlyCallback() {
        // The minimal draw() stub must be the ONLY function scheduleRedraw
        // calls — eq3's drawResponse() / updateLegend() don't exist in the
        // scaffold, and copying them in would ReferenceError at load.
        let html = PresetBundle.starterIndexHTML(audioFrames: true)
        #expect(!html.contains("drawResponse"),
                "Scaffold must not reference eq3-specific drawResponse()")
        #expect(!html.contains("updateLegend"),
                "Scaffold must not reference eq3-specific updateLegend()")
        // The draw stub must early-return before any first frame to avoid
        // null-deref on specIn/specOut. Pin the guard so it can't drift.
        #expect(html.contains("if (!specIn || !specOut) return"),
                "draw() must early-return if specIn/specOut haven't been seeded yet")
    }

    @Test func starterHTMLAudioFramesPreservesBaseScaffold() {
        // Opting into audioFrames adds the spectrum surface but must not
        // remove the auto-panel or its surrounding container — authors
        // can still build a hybrid (analyzer + sliders) without re-adding
        // anything by hand.
        let html = PresetBundle.starterIndexHTML(audioFrames: true)
        #expect(html.contains("class=\"conjure-ui\""),
                "audioFrames scaffold must still wrap controls in .conjure-ui")
        #expect(html.contains("<cdp-panel auto>"),
                "audioFrames scaffold must still emit the auto-panel")
        #expect(html.contains("cdp-slider { min-height: 24px; min-width: 100px; }"),
                "audioFrames scaffold must still emit the cdp-slider baseline rule")
    }
}
