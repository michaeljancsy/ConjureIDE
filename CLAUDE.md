# TestPlugin

AUv3 audio effect plugin (volume control) for macOS, iOS, and visionOS. Built with Apple's Audio Unit Extension framework.

## Build

Xcode project with a Rust build phase. Open `TestPlugin.xcodeproj` or build from CLI:

```bash
xcodebuild -project TestPlugin.xcodeproj -scheme TestPlugin build
xcodebuild -project TestPlugin.xcodeproj -scheme TestPlugin test   # runs unit + UI tests
```

### Prerequisites
- Xcode with Swift 5.0+
- Rust toolchain (`rustup`, `cargo`) with targets: `aarch64-apple-darwin`, `aarch64-apple-ios`, `aarch64-apple-ios-sim`
- `cbindgen` (`cargo install cbindgen`)

Deployment targets: macOS 26.2+, iOS 26.2+, visionOS 26.2+.

### Rust build
The `TestPluginExtension` target has a Run Script build phase that calls `rust/build-rust.sh`. This:
1. Builds the Rust static library (`libtest_plugin_dsp.a`) via `cargo build`
2. Generates the C header (`rust/include/test_plugin_dsp.h`) via `cbindgen`

To build/test the Rust crate standalone: `cd rust && cargo test`

## Architecture

- **Swift + SwiftUI** for all UI, host app logic, buffer management, and render block
- **Rust** for the real-time DSP kernel (pure math, no allocations — render-thread safe)
- **C FFI** via bridging header (`TestPluginExtension-Bridging-Header.h`) imports `test_plugin_dsp.h`

## Project Structure

```
TestPlugin/                  Host app — loads and tests the AU extension
  Model/                     AudioUnitHostModel, AudioUnitViewModel
  Common/Audio/              SimplePlayEngine (AVAudioEngine wrapper)
  Common/MIDI/               MIDIManager
TestPluginExtension/         The AU plugin itself
  Parameters/                Parameter addresses (Swift enum) and specs
  UI/                        SwiftUI views (ParameterSlider, MainView)
  Common/Audio Unit/         TestPluginExtensionAudioUnit.swift — AUAudioUnit subclass + render block
  Common/UI/                 AudioUnitViewController, ObservableAUParameter
  Common/Parameters/         ParameterSpecBase (result-builder DSL)
rust/                        Rust DSP crate
  test_plugin_dsp/src/       kernel.rs (DSP), lib.rs (FFI), params.rs (addresses)
  include/                   Generated C header (test_plugin_dsp.h)
  build-rust.sh              Xcode build phase script
TestPluginTests/             Unit tests (Swift Testing)
TestPluginUITests/           UI tests (XCUITest)
```

## Parameter System

Parameters are defined in three layers that must stay in sync:

1. **Rust constant** (`rust/test_plugin_dsp/src/params.rs`) — `PARAM_GAIN = 0`
2. **Swift enum** (`Parameters.swift`) — `TestPluginExtensionParameterAddress.gain = 0`
3. **Swift spec** (`Parameters.swift`) — `ParameterSpec` with range, default, units
4. **Rust kernel** (`rust/test_plugin_dsp/src/kernel.rs`) — `set_parameter`/`get_parameter` match arms

Currently one parameter: `gain` (address 0, linear 0.0–1.0, default 0.25).

## DSP Conventions

- The DSP kernel (`DSPKernel` in Rust) is pure computation — no allocations, no locks, no syscalls on the audio thread
- Swift calls Rust via C FFI: `dsp_kernel_create()`, `dsp_kernel_process()`, `dsp_kernel_set_parameter()`, etc.
- Processing is sample-by-sample per channel
- Bypass copies input to output unchanged
- Event processing loop (parameter automation) lives in Swift alongside the render block

## Dependencies

- **Apple frameworks**: AudioToolbox, AVFoundation, CoreAudioKit, CoreMIDI, SwiftUI, Combine
- **Rust**: no external crates (pure `std` only)

## Plugin Identity

- Type: `aufx` (effect)
- Manufacturer: `A000`
- Subtype: `0000`
