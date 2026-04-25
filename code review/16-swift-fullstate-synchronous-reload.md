An AI has found the following issue. Please review and assess whether action is needed.

# Swift: fullState setter triggers synchronous script reload on main thread

## Context
The AUv3 host app or DAW restores plugin state via `fullState` (or `fullStateForDocument`). For ConjureDSP, restoring state means deserializing the embedded preset and re-running script load — Python imports + numpy buffer setup, or WASM compile + wasmtime instantiation.

## Issue
The reviewer flagged (around lines 1078–1107) that the `fullState` setter calls `reloadScript()` synchronously on the main thread. Script load can take hundreds of milliseconds (Python interpreter import, WASM compile via wasmtime). During this time the host's UI thread is blocked, which on Logic Pro / Live can manifest as a beachball or "host not responding" briefly.

## Location
- `ConjureDSPExtension/Common/Audio Unit/ConjureDSPExtensionAudioUnit.swift` — `fullState` setter, ~lines 1078–1107

## Why it matters
- Project load time inflates linearly with the number of ConjureDSP instances in the project.
- For Rust/WASM presets compiled via the bundled rustc, the worst case is several seconds (cold rustc invocation). On project load, that multiplies.
- Hosts may time out plugin instantiation if it takes too long.

## What to verify
- Read the `fullState` setter in `ConjureDSPExtensionAudioUnit.swift`.
- Trace `reloadScript()` to see what it calls — Python init, WASM cache check, rustc compile.
- Check the `WasmCache` behavior: cached binaries should be near-instant; uncached ones are slow. Is the cache populated before `fullState` is set on first project open?

## Suggested approach
- Make `reloadScript()` async and return a placeholder (passthrough) until it's ready. The audio thread already falls back to passthrough when no script is loaded.
- Indicate "loading" in the UI so the user knows why the plugin isn't audible yet.
- Alternatively: keep load synchronous but only for the cached-WASM / instant-Python case, and dispatch the slow path off-thread.
- Be careful with state restoration semantics — DAWs expect `fullState` to be applied before `allocateRenderResources` is called for playback. An async load means the first few buffers are silent. Consider whether that's acceptable.
