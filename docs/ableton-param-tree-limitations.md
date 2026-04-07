# Ableton Live Parameter Tree Limitations

## Summary

Ableton Live does not support dynamic AUv3 parameter tree updates at runtime. When ConjureDSP switches presets with different parameter metadata (names, ranges, units), Ableton continues showing the parameter names and ranges from plugin instantiation time. This is a fundamental limitation of how Ableton hosts AU plugins, not a bug in ConjureDSP.

## Root Cause

Ableton uses the **AUv2 hosting API** (C-based `AudioComponentInstanceNew`) to load all Audio Units, including AUv3 plugins. Apple provides a compatibility bridge that wraps AUv3 `AUAudioUnit` instances behind the AUv2 C API.

In the AUv2 world, hosts learn about parameter changes via **property listener callbacks**:

```
AudioUnitAddPropertyListener(audioUnit, kAudioUnitProperty_ParameterList, callback, ...)
AudioUnitAddPropertyListener(audioUnit, kAudioUnitProperty_ParameterInfo, callback, ...)
```

Plugins signal changes by calling `PropertyChanged()` on `AUBase` (the C++ AU SDK base class), which directly invokes these host callbacks. **This is the only mechanism Ableton responds to.**

AUv3 plugins use a completely different notification system: **KVO on `parameterTree`**. The AUv2 compatibility bridge does NOT translate KVO notifications into AUv2 property listener callbacks. So when ConjureDSP fires:

```swift
willChangeValue(forKey: "parameterTree")
self.parameterTree = newTree
didChangeValue(forKey: "parameterTree")
```

...Ableton never receives the notification.

## Why JUCE Plugins Can Do This

JUCE's default macOS AU build is **AUv2** (not AUv3). It subclasses `AUBase` and has direct access to `PropertyChanged()`:

```cpp
// From juce_AU_Wrapper.mm
void audioProcessorChanged(AudioProcessor*) override {
    PropertyChanged(kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0);
    PropertyChanged(kAudioUnitProperty_ParameterInfo, kAudioUnitScope_Global, 0);
}
```

JUCE's AUv3 wrapper (`juce_AUv3_Wrapper.mm`) does NOT fire these property notifications — it only fires KVO on `allParameterValues`. So even JUCE AUv3 plugins would have the same limitation in Ableton.

## What Works

- **Parameter values** update correctly in Ableton when presets change, because the implementor callbacks (`implementorValueProvider`, `implementorValueObserver`) dynamically reference the current metadata for normalization/denormalization.
- **Logic Pro, AUM, and other hosts** that natively use the AUv3 API (not the AUv2 bridge) properly observe KVO on `parameterTree` and update their UI.
- **`allParameterValues` KVO** signals hosts to re-read parameter values after preset changes.

## What Doesn't Work

- **Parameter names** in Ableton's device panel remain frozen from instantiation time.
- **Parameter ranges** (min/max) shown in Ableton don't update.
- **Parameter units** (Hz, dB, ms, %) shown in Ableton don't update.

## Our Mitigation

ConjureDSP uses a **stable generic parameter tree** built once at init:

1. All 16 parameters are created with generic names ("Param 0" through "Param 15") and 0-1 ranges.
2. The tree is **never rebuilt** — this prevents automation breakage and host instability.
3. Implementor callbacks reference `currentParamMetadata` dynamically, so normalization/denormalization stays correct as presets change.
4. The plugin's own UI (`ParameterSlidersView`) always shows correct parameter names and ranges, independent of what the DAW displays.
5. `allParameterValues` KVO fires after every preset load so hosts re-read values.
6. `currentPreset` KVO fires so hosts update their preset display.

This matches the strategy used by JUCE (never rebuild the tree) and Mela (fixed "perform slot" parameters).

## Host Compatibility Matrix

| Host | Parameter names update | Parameter values update | Notes |
|------|----------------------|------------------------|-------|
| Ableton Live | No | Yes | Uses AUv2 bridge, doesn't observe KVO |
| Logic Pro | Yes | Yes | Native AUv3 hosting |
| AUM | Yes | Yes | Native AUv3 hosting |
| GarageBand | Partial | Yes | Breaks `implementorValueObserver` after tree rebuild |
| Cubasis | No | No | Automation breaks after tree changes |

## Possible Future Fix

Shipping a **dual AUv2+AUv3 build** would give the AUv2 version access to `PropertyChanged()`, making parameter name updates work in Ableton. This would require:

- Subclassing `AUBase` (Apple's C++ AU SDK) for the AUv2 component
- Bridging the Rust FFI layer to the AUv2 C++ API
- Maintaining two plugin binaries (AUv2 component bundle + AUv3 app extension)

This is a significant architectural effort and is tracked as a potential future enhancement.

## References

- [Apple: AUAudioUnit.parameterTree](https://developer.apple.com/documentation/audiotoolbox/auaudiounit/parametertree) — KVO is the documented AUv3 mechanism
- [Apple: Hosting AU Extensions Using AUv2 API](https://developer.apple.com/documentation/audiotoolbox/hosting-audio-unit-extensions-using-the-auv2-api) — confirms bridge exists
- [Apple Developer Forums: Recreating AUParameterTree](https://developer.apple.com/forums/thread/72168) — "a popular host app crashes when updating the parameterTree"
- [Nikolozi: AUv3 Dynamic Parameter Tree](https://nikolozi.com/mela/tech-notes/parameter-tree/) — host compatibility testing
- [JUCE AU Wrapper source](https://github.com/juce-framework/JUCE/blob/master/modules/juce_audio_plugin_client/AU/juce_AU_Wrapper.mm) — fires `PropertyChanged` (AUv2 only)
- [JUCE AUv3 Wrapper source](https://github.com/juce-framework/JUCE/blob/master/modules/juce_audio_plugin_client/AU/juce_AUv3_Wrapper.mm) — only fires KVO on `allParameterValues`
