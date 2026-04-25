An AI has found the following issue. Please review and assess whether action is needed.

# Swift: Combine .send() and Sentry calls in AU render-resource lifecycle

## Context
ConjureDSP is an AUv3 plugin. The `AUAudioUnit` subclass's `internalRenderBlock` is the audio thread and must not allocate, lock, log, or call ObjC. Less obvious is `allocateRenderResources()` / `deallocateRenderResources()` — these run on a host-controlled queue around audio start/stop and can be called repeatedly during a session (e.g., when the host changes sample rate or buffer size mid-session).

## Issue
The reviewer flagged that `renderConfigurationChanged.send()` (a Combine subject) and `SentryHelper.breadcrumb()` are called from `allocateRenderResources()` / `deallocateRenderResources()` in `ConjureDSPExtension/Common/Audio Unit/ConjureDSPExtensionAudioUnit.swift`. Both can allocate, take locks (Sentry serializes breadcrumbs), and dispatch — none of which are appropriate on a render-adjacent path that the host expects to return promptly.

## Location
- `ConjureDSPExtension/Common/Audio Unit/ConjureDSPExtensionAudioUnit.swift` — `allocateRenderResources()` and `deallocateRenderResources()` overrides; line numbers approximate (~1250, ~1263 per the reviewer)

## Why it matters
The render block itself is tightly controlled, but `allocateRenderResources` is called within the host's audio engine setup. Hosts like Logic Pro can call it on the audio I/O thread or a tightly time-budgeted sibling. Long blocking calls here cause clicks at start, late driver callbacks, or Sentry's serial queue contention surfacing as audio glitches. This is the kind of bug that's invisible on a development machine and shows up on a customer's busy session.

## What to verify
- Read `ConjureDSPExtensionAudioUnit.swift` end to end — find every override of `allocateRenderResources`, `deallocateRenderResources`, `reset`, and any property setters that are called by the host between renders.
- Check what thread Apple's docs / sample code say invokes these overrides. Confirm whether the project's tests exercise repeated allocate/deallocate cycles.
- Audit `SentryHelper.breadcrumb` for whether it's actually synchronous or already dispatches off-thread.

## Suggested approach
- Wrap the `Combine` send and Sentry call in a `DispatchQueue.main.async { ... }` (or a dedicated background queue) so the audio-adjacent path returns immediately.
- Better: have the render-config publisher observe a state value the audio thread updates with an atomic, and let a UI-side Timer/CADisplayLink read it. That removes the producer-side allocation entirely.
- Apply the same audit to any other lifecycle overrides (`reset()`, `shouldChangeToFormat`, parameter observer registration).
