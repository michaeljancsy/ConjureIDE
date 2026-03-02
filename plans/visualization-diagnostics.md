# Visualization and Diagnostics in the Mac Host App

## Problem
The host app currently only shows Play/Stop and Validate controls. There's no way to see what the audio looks like before/after the DSP effect, monitor levels, or diagnose performance issues. Audio visualization would make the host app a useful development tool and help users understand what their Python DSP scripts are doing to the audio.

## Current State

### Host App Audio Pipeline (`TestPlugin/Common/Audio/SimplePlayEngine.swift`)
```
AVAudioPlayerNode (file: Synth.aif) → AVAudioUnit (the AU effect) → mainMixerNode → outputNode
```
- `player: AVAudioPlayerNode` — plays bundled audio file
- `avAudioUnit: AVAudioUnit?` — the loaded AU effect
- Audio graph is connected/disconnected in `connectEffect()` / `disconnectEffect()`
- No taps currently installed on any nodes

### Host App UI (`TestPlugin/ContentView.swift`)
- Simple VStack with Play/Stop, Validate, and the embedded AU view
- No visualization components

### Existing Diagnostics in AU Extension
- Benchmark timing display (green/orange/red) after script reload
- Error messages in the status bar
- Build ID display
- These are in the AU extension UI only — not in the host app

## Research Findings

### Audio Capture: `installTap(onBus:bufferSize:format:block:)`
- Available on any `AVAudioNode` in the engine graph
- Delivers `AVAudioPCMBuffer` in a callback (~10 times/sec with default 4096 bufferSize at 44.1kHz)
- Non-main thread — must dispatch UI updates to main
- Only one tap per bus per node
- For before/after: tap the `player` node (pre-effect) and the `avAudioUnit` node (post-effect)

### Audio Analysis: Accelerate/vDSP
- **RMS metering**: `vDSP_rmsqv()` — single vectorized call
- **Peak detection**: `vDSP_maxmgv()` — single vectorized call
- **FFT**: `vDSP.FFT` with Hann window — for spectrum analysis
- **dB conversion**: `vDSP_vdbcon()` — linear to decibels
- All hardware-accelerated on Apple Silicon

### Rendering Options
| Visualization | Best Renderer | Complexity |
|---------------|---------------|------------|
| Level meters | SwiftUI Rectangle/Gauge | Low |
| Waveform | SwiftUI Canvas + TimelineView | Medium |
| Spectrum bars | Swift Charts or Canvas | Medium |
| Spectrogram | Metal | High |

### Key Apple APIs
- `TimelineView(.animation)` — drives per-frame SwiftUI updates at display refresh rate
- `Canvas` — immediate-mode 2D drawing, good for waveforms
- Swift Charts — declarative chart API, good for bar-style spectrum displays

## Recommended Implementation Plan

### Phase 1: Stereo Level Meters (Start Here)

The simplest and most universally useful visualization. Shows real-time input/output levels.

**Audio capture:**
```swift
// In SimplePlayEngine, after connecting the effect:
mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in
    let rms = self.computeRMS(buffer)
    let peak = self.computePeak(buffer)
    DispatchQueue.main.async {
        self.audioLevels = AudioLevels(rms: rms, peak: peak)
    }
}
```

**Analysis (`AudioAnalyzer.swift` — new file):**
```swift
class AudioAnalyzer: ObservableObject {
    @Published var levels: StereoLevels = .zero

    struct StereoLevels {
        var leftRMS: Float = 0
        var rightRMS: Float = 0
        var leftPeak: Float = 0
        var rightPeak: Float = 0
    }

    func analyze(buffer: AVAudioPCMBuffer) {
        // Use vDSP_rmsqv and vDSP_maxmgv
        // Apply smoothing: fast attack (~5ms), slow release (~300ms)
        // Convert to dB scale
    }
}
```

**UI (new `LevelMeterView.swift`):**
- Two vertical bars (L/R) with gradient: green → yellow → red
- Peak hold indicators (small line at max recent level)
- dB scale markings (-60, -40, -20, -12, -6, -3, 0)
- Compact: fits in a sidebar or below the AU view

### Phase 2: Before/After Waveform Display

Shows the effect of the DSP script by overlaying input and output waveforms.

**Audio capture:**
- Tap the `player` node for pre-effect signal (dry)
- Tap the `avAudioUnit` node for post-effect signal (wet)
- Store rolling buffer (~2048 samples) for each

**UI (new `WaveformView.swift`):**
```swift
struct WaveformView: View {
    let inputSamples: [Float]   // pre-effect
    let outputSamples: [Float]  // post-effect

    var body: some View {
        TimelineView(.animation) { _ in
            Canvas { context, size in
                // Draw input waveform (blue, semi-transparent)
                // Draw output waveform (green, semi-transparent)
                // Overlay shows the effect visually
            }
        }
    }
}
```

**Downsampling:** For display, reduce samples to 1 min/max pair per pixel using `vDSP`. A 600px-wide view only needs 600 sample pairs.

### Phase 3: Spectrum Analyzer

FFT-based frequency domain display.

**Analysis:**
```swift
// In AudioAnalyzer
func computeSpectrum(buffer: AVAudioPCMBuffer) -> [Float] {
    // 1. Apply Hann window: vDSP_vmul
    // 2. FFT: vDSP.FFT (1024-point → 512 bins)
    // 3. Magnitude: vDSP_zvabs
    // 4. Convert to dB: vDSP_vdbcon
    // 5. Group into logarithmic bands (e.g., 1/3 octave)
    // 6. Apply smoothing between frames
}
```

**UI (new `SpectrumView.swift`):**
- Bar chart with logarithmic frequency axis (20Hz → 20kHz)
- Smoothed animation between frames
- Can use Swift Charts `BarMark` or Canvas for rendering

### Phase 4: Performance Diagnostics

**CPU timing:**
- Add `dsp_kernel_last_process_time()` FFI function in Rust
- Measures wall-clock time of each `process()` call
- Display as percentage of audio budget

**Diagnostics panel:**
- Sample rate, buffer size, channel count
- Latency (input + output + AU)
- Script execution time (avg, max)
- Buffer underrun count (if detectable)

## Key Files to Create
- `TestPlugin/Audio/AudioAnalyzer.swift` — Tap management + vDSP analysis
- `TestPlugin/Views/LevelMeterView.swift` — Stereo level meter UI
- `TestPlugin/Views/WaveformView.swift` — Before/after waveform overlay
- `TestPlugin/Views/SpectrumView.swift` — FFT spectrum display
- `TestPlugin/Views/DiagnosticsView.swift` — Performance diagnostics panel

## Key Files to Modify
- `TestPlugin/Common/Audio/SimplePlayEngine.swift` — Install/remove taps, expose audio data
- `TestPlugin/Model/AudioUnitHostModel.swift` — Own AudioAnalyzer, pass to views
- `TestPlugin/ContentView.swift` — Add visualization views to layout
- `rust/test_plugin_dsp/src/kernel.rs` — Add process timing (Phase 4)
- `rust/test_plugin_dsp/src/lib.rs` — Add timing FFI function (Phase 4)

## Layout Proposal
```
┌──────────────────────────────────────────────┐
│  [Play/Stop] [Bypass] Preset: [▼]  [Validate]│  ← toolbar (see host-app-daw-controls.md)
├──────────┬───────────────────────────────────┤
│  Level   │                                   │
│  Meters  │   AU Extension View               │
│  L  R    │   (Python script editor)          │
│  ██ ██   │                                   │
│  ██ ██   │                                   │
│  ██ ██   │                                   │
├──────────┴───────────────────────────────────┤
│  Waveform: ~~~input(blue)~~~ ~~~output(green)│  ← before/after overlay
├──────────────────────────────────────────────┤
│  Spectrum: ▐▐▐▐▐▐▐▐▐▐▐▐▐▐▐▐▐▐▐▐▐▐▐▐▐▐▐▐▐▐ │  ← FFT display
├──────────────────────────────────────────────┤
│  44.1kHz | 512 frames | 0.8ms/11.6ms (7%)   │  ← diagnostics
└──────────────────────────────────────────────┘
```

Visualization panels should be collapsible/toggleable so they don't clutter the UI when not needed.

## Testing
- Unit tests: AudioAnalyzer RMS/peak computation with known signals (silence, full-scale sine, DC offset)
- Unit tests: FFT bin frequency accuracy
- UI tests: level meters visible and updating (check accessibility identifiers)
- Manual: Play audio, verify meters respond. Change preset, verify waveform/spectrum changes.
- Performance: Verify taps don't add noticeable CPU overhead or cause audio glitches

## Estimated Complexity
Medium-large task. Phase 1 (level meters) is ~1 day. Each subsequent phase is ~1 day. Full implementation: ~4 days.
