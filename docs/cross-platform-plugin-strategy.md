# Cross-Platform Plugin Strategy

## Context

ConjureDSP is currently macOS-only, built as an AUv3 (Audio Unit v3) plugin. This document explores what it would take to support other plugin formats (VST3, CLAP, AAX) for broader DAW compatibility.

## Current Architecture Portability

The **Rust DSP core** (`rust/conjure_dsp/`) is already platform-agnostic: the kernel, Python backend (pyo3), WASM backend (wasmtime), parameter system, ring buffers, and Ed25519 license verification all have no Apple dependencies. This is the strategic asset for any cross-platform effort.

The **Swift layer** (AUv3 integration, SwiftUI UI, Monaco WKWebView, spectrogram, export pipeline) is entirely macOS-specific. Rebuilding the UI is the majority of the work for any cross-platform port.

**Moving more Swift into Rust preemptively is not recommended.** The current boundary is well-drawn: Rust owns the audio path and platform-agnostic logic, Swift owns Apple platform integration. The only exception: if duplicated logic appears in both layers (e.g., test target's separate `ParamMetadata`), consolidate on the Rust side.

## Recommended Approach: nih-plug

[nih-plug](https://github.com/robbert-vdh/nih-plug) is a Rust-native plugin framework that outputs VST3, CLAP, and standalone builds from a single codebase. Since the DSP core is already Rust, it's the most natural fit:

- Wrap `conjure_dsp` kernel in a nih-plug `Plugin` impl
- Map the parameter system to nih-plug's parameter model
- Build cross-platform UI (nih-plug supports egui, iced, or VIZIA)
- Python/WASM backends work as-is

**License**: nih-plug is ISC (permissive, similar to MIT). No fees or royalties.

## Format Coverage

| Format | Tool | DAWs Covered |
|---|---|---|
| AU (existing) | Current AUv3 build | Logic Pro |
| VST3 (nih-plug) | nih-plug | Ableton, Cubase, Studio One, FL Studio, Reaper, Bitwig |
| CLAP (nih-plug) | nih-plug | Reaper, Bitwig, FL Studio |
| AAX (not covered) | Separate effort required | Pro Tools |

**AUv3 + nih-plug (VST3/CLAP) covers every major DAW except Pro Tools.**

Pro Tools only supports AAX, which nih-plug does not output. Supporting it would require Avid's developer program and a separate AAX wrapper. Given ConjureDSP's creative/experimental audience vs Pro Tools' mixing/mastering user base, this is low priority.

## Licensing Landscape

- **VST3**: Steinberg relicensed the SDK to **MIT in late 2025**. No agreements to sign, no GPL obligation, no trademark requirements. Zero friction for commercial use.
- **CLAP**: Fully open (MIT). No licensing complexity.
- **AAX**: Requires Avid developer program approval.
- **AU**: Apple framework, no separate license needed.

## Effort Estimate

- **Smallest viable step**: A nih-plug wrapper with no custom UI (just parameter sliders) could validate the DSP pipeline as VST3/CLAP quickly. This proves the audio path works in non-AU hosts.
- **Full port**: The UI rebuild (code editor, spectrogram, settings views) is 60-70% of the total effort. Monaco in a cross-platform web view is the biggest challenge.
