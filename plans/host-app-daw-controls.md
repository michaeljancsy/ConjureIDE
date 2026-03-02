# Host App DAW Controls

## Problem
The TestPlugin host app only has Play/Stop and Validate buttons. A real DAW provides preset selection and bypass controls for audio effects. The host app should mimic these controls so developers can test preset switching and bypass behavior without loading the plugin in a DAW.

## Current State

### Host App UI (`TestPlugin/ContentView.swift`)
- Play/Stop toggle button (controls `SimplePlayEngine`)
- Validate button (runs `AudioComponentValidateWithResults`)
- AU extension view embedded via `AudioUnitViewModel`
- Crash detection display
- No preset or bypass controls

### Host App Model (`TestPlugin/Model/AudioUnitHostModel.swift`)
- Owns `SimplePlayEngine` and `AudioUnitViewModel`
- Reads AU identity from embedded extension's Info.plist
- Instantiates AU via `SimplePlayEngine.initComponent()` with `.loadInProcess`
- Exposes `viewModel` for the AU extension's UI

### AU APIs Already Available
The `AUAudioUnit` subclass (`TestPluginExtensionAudioUnit`) already exposes:
- `factoryPresets: [AUAudioUnitPreset]` — 3 factory presets (Passthrough, Tremolo, Bitcrush)
- `currentPreset: AUAudioUnitPreset?` — get/set current preset (triggers script load)
- `shouldBypassEffect: Bool` — get/set bypass state (Rust kernel passthrough)
- `selectPreset(_ preset: Preset) -> ScriptSaveResult` — internal method (not needed from host; `currentPreset` setter handles it)

### Playback Engine (`TestPlugin/Common/Audio/SimplePlayEngine.swift`)
- `isPlaying: Bool` — toggled externally
- `avAudioUnit: AVAudioUnit?` — the loaded AU instance
- The `avAudioUnit.auAudioUnit` gives access to all AU properties

## Plan

### Step 1: Add Bypass Toggle
Add a bypass toggle button to `ContentView.swift`, next to the existing Play/Stop button.

```swift
// Access the AU's bypass property via the engine
Toggle("Bypass", isOn: Binding(
    get: { engine.avAudioUnit?.auAudioUnit.shouldBypassEffect ?? false },
    set: { engine.avAudioUnit?.auAudioUnit.shouldBypassEffect = $0 }
))
```

### Step 2: Add Preset Picker
Add a preset dropdown/picker showing factory presets (and optionally user presets).

```swift
// Read available presets
let presets = engine.avAudioUnit?.auAudioUnit.factoryPresets ?? []

// Picker bound to currentPreset
Picker("Preset", selection: $currentPreset) {
    Text("None").tag(nil as AUAudioUnitPreset?)
    ForEach(presets, id: \.number) { preset in
        Text(preset.name).tag(preset as AUAudioUnitPreset?)
    }
}
```

The `currentPreset` setter on the AU handles script loading automatically.

### Step 3: Expose AU State in the Model
`AudioUnitHostModel` or a new view model needs to:
- Expose `factoryPresets` once the AU is loaded
- Provide a binding for `currentPreset`
- Provide a binding for `shouldBypassEffect`
- Update when the AU changes these values (e.g., via the extension UI)

Consider adding `@Published` properties to `AudioUnitHostModel` that sync with the AU, or create a lightweight wrapper that reads directly from `avAudioUnit.auAudioUnit`.

### Step 4: Layout
Arrange controls in a toolbar-style row above the AU extension view:
```
[Play/Stop] [Bypass] | Preset: [Dropdown ▼] | [Validate]
```

## Key Files to Modify
- `TestPlugin/ContentView.swift` — Add bypass toggle and preset picker UI
- `TestPlugin/Model/AudioUnitHostModel.swift` — Expose AU preset/bypass state
- `TestPlugin/Common/Audio/SimplePlayEngine.swift` — May need to expose `avAudioUnit` publicly (check current access level)

## Testing
- Build and run the host app
- Verify bypass toggle mutes/passes audio
- Verify preset dropdown lists all 3 factory presets
- Verify selecting a preset changes the script in the embedded AU view
- Verify play/stop still works with bypass and preset changes
- Add unit tests: bypass toggle state roundtrip, preset selection changes `currentPreset`
- Add UI test: bypass button and preset picker are visible and interactive

## Estimated Complexity
Small task — the AU APIs already exist. This is purely SwiftUI wiring. Half-day of work.
