An AI has found the following issue. Please review and assess whether action is needed.

# Swift: try! and force unwraps on regex / JSON in production paths

## Context
ConjureDSP's Swift code uses `try!` and `!` in paths that run during normal user activity (script reload, export), not just one-time test fixtures.

## Issue
The reviewer flagged at least two specific instances:
1. `try!` on a regex compilation in `ConjureDSPExtensionAudioUnit.swift` (~line 523/524). If the pattern is malformed or a future edit breaks it, the AU crashes on the operation that triggers it.
2. `try! JSONSerialization.data(...)` in the export path (`ExportManager`, ~line 340). JSON serialization can fail when the dictionary contains non-encodable types (e.g., a `nil` where `NSNull` was expected, or a custom Swift type that didn't bridge cleanly).

Both crash the process on failure rather than surfacing an error.

## Location
- `ConjureDSPExtension/Common/Audio Unit/ConjureDSPExtensionAudioUnit.swift` — line ~523 (regex)
- `ConjureDSPExtension/Export/ExportManager.swift` — line ~340 (JSONSerialization)
- Worth a wider sweep: `grep -rn "try!" ConjureDSPExtension ConjureDSP ConjureDSPTerminal` and `grep -n "as! "` on the same paths.

## Why it matters
Crashes inside an AU extension take the host's audio engine down (Logic / Live / etc. may recover, but the user sees their plugin disappear and may lose unsaved automation). Even when the host recovers, this is the kind of issue that ends up in Sentry as a recurring crash with no useful stack frame for the user. The owner's stated preference (per memory) is to surface real errors, not crash or guess.

## What to verify
- Read both flagged sites and confirm the `try!` / `!` is actually present.
- Sweep the whole Swift source tree for `try!`, `as!`, and `!.` patterns. Most are likely fine (constants known at compile time), but flag any in I/O or user-data paths.
- For each occurrence, decide: is the failure truly impossible (compile-time constant) or is it just unlikely?

## Suggested approach
- Move regex compilation to a `static let` initialized with a `do/catch` and a developer-friendly fatalError message that names the bad pattern. That's still a crash on truly broken patterns but moves it to load time, where it's caught in dev.
- Replace `try! JSONSerialization.data(...)` with `do/catch` and propagate the failure as an `ExportError.serializationFailed(underlying:)` so the UI can show the real reason.
- Prefer `JSONEncoder` with `Codable` types where possible — it's harder to construct an invalid input.
