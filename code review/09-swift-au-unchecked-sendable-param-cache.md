An AI has found the following issue. Please review and assess whether action is needed.

# Swift: @unchecked Sendable on AU class hides param-metadata race

## Context
The AUv3 audio unit class needs to be usable from multiple threads — the audio thread runs the render block, the main thread runs UI / state restoration / preset selection. Swift's strict concurrency requires either an actor, true `Sendable` conformance, or `@unchecked Sendable` (which silences the checker without enforcing anything).

## Issue
`ConjureDSPExtensionAudioUnit` is declared `@unchecked Sendable`. The reviewer flagged that the parameter-metadata cache (the JSON / decoded ParamMetadata array maintained alongside the AU's parameter tree) is read on the audio thread (when formatting parameter values, applying envelopes, looking up curve types) and written on the UI thread (when a script load triggers `rebuildParameterTree`). There's no lock or atomic snapshot pattern protecting it — `@unchecked Sendable` silences the compiler but the data race is real.

## Location
- `ConjureDSPExtension/Common/Audio Unit/ConjureDSPExtensionAudioUnit.swift` — class declaration; cache property (~line 93 per reviewer); read sites in render path and parameter callbacks

## Why it matters
On Apple Silicon, Swift's class instances do not give you torn-read protection for Array/Dictionary or any reference type. A read during a write can crash (segfault on a dangling buffer pointer, or hit an internal `_assertionFailure` in collection bridging). The crash will be rare, hard to reproduce, and look like a host bug. Property wrappers and `var` access on the class are the typical entry points.

## What to verify
- Read `ConjureDSPExtensionAudioUnit.swift` end to end. Inventory every mutable property reachable from the render block and from the main thread.
- Specifically look for: parameter metadata array, current preset metadata, latency value, fade-in state, anything related to script reload.
- Check whether `rebuildParameterTree` is called from a Task and whether the audio thread can observe a half-built tree.

## Suggested approach
- Replace shared mutable references with an immutable snapshot-on-publish pattern: build the new metadata array fully off-thread, then atomically swap a `ManagedAtomic<UnsafePointer<...>>` (or similar) the audio thread reads.
- Or: keep the cache only on the Rust side (which has its own atomics) and have the audio thread read it through FFI, leaving Swift with only a UI-side mirror.
- Audit every `@unchecked Sendable` in the codebase and either justify each with a comment explaining what guarantees the safety, or replace with a proper sync primitive.
