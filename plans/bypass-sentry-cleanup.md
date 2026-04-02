# Plan: Remove Sentry Debug Toggle, Promote Bypass to First-Class Feature

## Context
The status bar at the bottom of the editor contains two debug-only text buttons: "Bypass" and "Sentry". Both were added for diagnostic purposes. The Sentry toggle is pure debugging infrastructure that should never be user-visible. Bypass, however, is a genuine A/B comparison feature that belongs prominently in the toolbar alongside other audio controls — not hidden in a monospaced status bar alongside profiler metrics.

## Changes

### 1. Remove Sentry disable feature entirely

**`ConjureDSPExtension/Common/UI/AudioUnitViewController.swift`**
- Remove `private var sentryActive: Bool = true` (line 59)
- Remove `isSentryEnabled` and `setSentryEnabled` arguments from `ConjureDSPExtensionMainView` initializer (lines 532–543)

**`ConjureDSPExtension/UI/ConjureDSPExtensionMainView.swift`**
- Remove `isSentryEnabled: () -> Bool` and `setSentryEnabled: (Bool) -> Void` properties (lines 51–52)
- Remove `@State private var sentryEnabled: Bool = true` (line 55)
- Remove `sentryEnabled = isSentryEnabled()` call in `.onAppear` (line 415)
- Remove `sentryEnabled:`, `onSentryToggle:` args from `StatusBarView(...)` call (lines 213, 221)
- In `StatusBarView`: remove `@Binding var sentryEnabled`, `var onSentryToggle`, and the Sentry `Button { }` block (lines 556, 559, 660–668)

### 2. Move Bypass toggle into PresetToolbar (script actions zone, after Run)

**`ConjureDSPExtension/UI/PresetToolbar.swift`**
- Add `@Binding var bypassed: Bool` property
- Add `var onBypassToggle: () -> Void` property
- Add Bypass button in the script actions zone, right after the Run button. Style matches other toolbar buttons (VStack icon + label, `.borderless`):
  ```swift
  Button(action: { bypassed.toggle(); onBypassToggle() }) {
      VStack(alignment: .center, spacing: 1) {
          Image(systemName: bypassed ? "waveform.slash" : "waveform")
              .frame(height: 16)
              .foregroundColor(bypassed ? .orange : .primary)
          Text("Bypass")
              .font(.system(size: 9))
              .foregroundColor(bypassed ? .orange : .secondary)
      }
  }
  .buttonStyle(.borderless)
  .fixedSize()
  .toolbarTooltip(bypassed ? "Bypass ON — click to enable processing" : "Bypass processing (A/B compare)")
  .accessibilityIdentifier("bypassButton")
  ```

**`ConjureDSPExtension/UI/ConjureDSPExtensionMainView.swift`**
- Pass `bypassed: $bypassed` and `onBypassToggle: { setBypass(bypassed) }` to `PresetToolbar`
- Remove `bypassed:` and `onBypassToggle:` from `StatusBarView(...)` call
- In `StatusBarView`: remove `@Binding var bypassed`, `var onBypassToggle`, and the Bypass `Button { }` block

## Critical Files
- `ConjureDSPExtension/Common/UI/AudioUnitViewController.swift` (lines 59, 530–543)
- `ConjureDSPExtension/UI/ConjureDSPExtensionMainView.swift` (lines 49–55, 212–221, 414–415, 548–680)
- `ConjureDSPExtension/UI/PresetToolbar.swift` (lines 51–98, 149–172)

## Verification
- Build: `xcodebuild -project ConjureDSP.xcodeproj -scheme ConjureDSP build`
- Unit tests: `xcodebuild -project ConjureDSP.xcodeproj -scheme ConjureDSP test -only-testing:ConjureDSPTests`
- Manually confirm: Bypass button appears in toolbar after Run, toggles orange with `waveform.slash` icon when active, and no Sentry/Bypass buttons appear in the status bar
