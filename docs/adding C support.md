# Adding C as a DSP Scripting Language

## Overview

Add C as a third DSP scripting language alongside Python and Rust. C scripts are compiled to WASM via clang and run through the existing `WasmBackend` — no Rust kernel changes needed. The integration mirrors how Rust/WASM already works: detect language → compile to WASM → cache → load via `loadWasm()`.

### Architecture

```
C source → clang (wasm32-wasip1) → .wasm → WasmBackend (existing)
                                          ↕
Rust source → rustc (wasm32-wasip1) → .wasm → WasmBackend (existing)
```

The `WasmBackend` is language-agnostic. It loads any WASM module that exports the expected functions (`process`, `get_input_ptr`, `get_output_ptr`, `get_params_ptr`, `get_param_metadata_ptr`, `get_param_metadata_len`). C modules export these identically to Rust modules.

## Implementation Phases

### Phase 1: Language Enum & Detection

**File: `ConjureDSPExtension/Compilation/ScriptLanguage.swift`**

Add `.c` case and update detection heuristics. Check for C before defaulting to Python, but after Rust (since `fn process(` is unambiguous for Rust):

```swift
enum ScriptLanguage: String, CaseIterable {
    case python
    case rust
    case c

    static func detect(from source: String) -> ScriptLanguage {
        // Rust: unambiguous markers
        if source.contains("fn process(") || source.contains("#[no_mangle]") {
            return .rust
        }
        // C: void process signature or C-specific includes
        if source.contains("void process(") || source.contains("#include") {
            return .c
        }
        return .python
    }
}
```

Note: `#include` doesn't appear in Python or Rust DSP scripts, so this is safe. `void process(` is the canonical C entry point for the template.

---

### Phase 2: C Process Template

**New file: `ConjureDSPExtension/Resources/process.c`**

The default template users see when starting a new C script. Must export the same WASM interface as Rust modules:

```c
// ConjureDSP DSP — C Template
//
// This script is compiled to WebAssembly and runs in the audio render callback.
// The process() function is called once per audio buffer.
//
// Rich parameters: Declare metadata so the host shows real ranges and units.
// PARAMS_BUF receives actual denormalized values (not 0–1).
//
// Safety: avoid allocations, I/O, or undefined behavior in process().

#include <math.h>

#define MAX_CH 2
#define MAX_FR 4096

static float INPUT_BUF[MAX_CH * MAX_FR];
static float OUTPUT_BUF[MAX_CH * MAX_FR];
static float PARAMS_BUF[16];

// Parameter indices
#define GAIN 0  // -24 to +12 dB

static const char METADATA[] =
    "[{\"name\":\"Gain\",\"min\":-24.0,\"max\":12.0,\"unit\":\"dB\",\"default\":0.0}]";

__attribute__((export_name("get_input_ptr")))
int get_input_ptr(void) { return (int)INPUT_BUF; }

__attribute__((export_name("get_output_ptr")))
int get_output_ptr(void) { return (int)OUTPUT_BUF; }

__attribute__((export_name("get_params_ptr")))
int get_params_ptr(void) { return (int)PARAMS_BUF; }

__attribute__((export_name("get_param_metadata_ptr")))
int get_param_metadata_ptr(void) { return (int)METADATA; }

__attribute__((export_name("get_param_metadata_len")))
int get_param_metadata_len(void) { return sizeof(METADATA) - 1; }

__attribute__((export_name("process")))
void process(const float* input, float* output,
             int channels, int frame_count, float sample_rate) {
    float gain_db = PARAMS_BUF[GAIN];
    float gain = powf(10.0f, gain_db / 20.0f);

    int total = channels * frame_count;
    for (int i = 0; i < total; i++) {
        output[i] = input[i] * gain;
    }
}
```

Key differences from Rust template:
- Uses `__attribute__((export_name(...)))` instead of `#[no_mangle] pub extern "C" fn` — this is how clang marks WASM exports
- Uses `#define` for constants instead of `const`
- `static` globals for buffers (same layout as Rust)
- `#include <math.h>` for `powf`, `expf`, `sinf`, etc. — provided by wasi-libc

---

### Phase 3: Compiler Infrastructure

#### 3a: wasi-sdk Setup Script

**New file: `scripts/setup-clang.sh`**

Downloads wasi-sdk (clang + wasi-libc pre-built for WASM targets). This is analogous to `scripts/setup-rustc.sh` for the Rust compiler.

wasi-sdk is the standard toolchain for compiling C/C++ to WASM. It bundles:
- clang (C/C++ compiler)
- wasi-libc (libc implementation for WASM, provides `math.h`, `string.h`, `stdlib.h`, etc.)
- compiler-rt builtins (soft-float, etc.)

```bash
#!/bin/bash
# Download wasi-sdk for C → WASM compilation.
# Result: clang-dist/ directory with clang binary and wasi-libc sysroot.

set -euo pipefail

VERSION="25"  # Check https://github.com/WebAssembly/wasi-sdk/releases for latest
PLATFORM="macos"
ARCH="$(uname -m)"  # arm64 or x86_64

DEST="$(dirname "$0")/../clang-dist"

if [ -d "$DEST/bin/clang" ] || [ -L "$DEST/bin/clang" ]; then
    echo "clang-dist already exists, skipping download"
    exit 0
fi

URL="https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-${VERSION}/wasi-sdk-${VERSION}.0-${ARCH}-${PLATFORM}.tar.gz"
TMPFILE=$(mktemp /tmp/wasi-sdk.XXXXXX.tar.gz)

echo "Downloading wasi-sdk ${VERSION} for ${ARCH}..."
curl -L -o "$TMPFILE" "$URL"

echo "Extracting to ${DEST}..."
mkdir -p "$DEST"
tar xzf "$TMPFILE" -C "$DEST" --strip-components=1

rm -f "$TMPFILE"
echo "Done. clang at ${DEST}/bin/clang"
```

Expected size: ~200MB (comparable to rustc-dist). The `clang-dist/` directory should be gitignored.

#### 3b: CCompiler Class

**New file: `ConjureDSPExtension/Compilation/CCompiler.swift`**

Follows the same pattern as `RustCompiler.swift`: prefer bundled clang (for sandboxed DAW hosts), fall back to system clang.

```swift
import Foundation
import os

/// Compiles C source files to WASM via clang (wasi-sdk).
///
/// Prefers the bundled wasi-sdk compiler (shipped inside the extension's Resources)
/// which works even in sandboxed DAW hosts. Falls back to system wasi-sdk
/// for development convenience.
final class CCompiler: ScriptCompiler {
    let displayName = "C"

    private var cachedClangURL: URL?
    private var cachedSysroot: URL?
    private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "CCompiler")

    func isAvailable() async -> Bool {
        return findClang() != nil
    }

    func compile(source: String) async throws -> Data {
        guard let clang = findClang() else {
            throw CompilationError.compilerNotFound(
                "C compiler not found. The bundled compiler may be missing — "
                + "run scripts/setup-clang.sh and rebuild.")
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("conjuredsp-compile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let inputFile = tempDir.appendingPathComponent("dsp.c")
        let outputFile = tempDir.appendingPathComponent("dsp.wasm")
        try source.write(to: inputFile, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = clang

        var args = [
            "--target=wasm32-wasip1",
            "-O2",
            "-Wl,--no-entry",           // No main() — library mode
            "-Wl,--export-dynamic",      // Export all non-static symbols
            "-mexec-model=reactor",      // WASI reactor (no _start)
            "-o", outputFile.path,
            inputFile.path,
        ]

        // When using bundled compiler, set explicit sysroot
        if let sysroot = cachedSysroot {
            args = ["--sysroot=\(sysroot.path)"] + args
        }

        process.arguments = args

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw CompilationError.sandboxRestriction(
                "Failed to run C compiler: \(error.localizedDescription)")
        }

        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: stderrData, encoding: .utf8)
                ?? "Unknown compilation error"
            throw CompilationError.compilationFailed(stderr)
        }

        return try Data(contentsOf: outputFile)
    }

    // MARK: - Private

    private func bundledSysroot() -> URL? {
        let bundle = Bundle(for: CCompiler.self)
        guard let path = bundle.path(forResource: "clang-dist", ofType: nil) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    private func bundledClang() -> URL? {
        guard let sysroot = bundledSysroot() else { return nil }
        let clang = sysroot.appendingPathComponent("bin/clang")
        if FileManager.default.fileExists(atPath: clang.path) {
            return clang
        }
        return nil
    }

    private var realUserHome: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    private func findClang() -> URL? {
        if let cached = cachedClangURL { return cached }

        // Prefer bundled (works in sandbox)
        if let bundled = bundledClang(), let sysroot = bundledSysroot() {
            cachedClangURL = bundled
            cachedSysroot = sysroot
            return cachedClangURL
        }

        // Fall back to system wasi-sdk or Homebrew clang
        let home = realUserHome
        let candidates = [
            // wasi-sdk default install location
            "/opt/wasi-sdk/bin/clang",
            "\(home)/wasi-sdk/bin/clang",
            // Homebrew
            "/opt/homebrew/opt/llvm/bin/clang",
            "/usr/local/opt/llvm/bin/clang",
        ]

        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
                cachedClangURL = resolved
                // System clang needs wasi-sysroot — check sibling directory
                let sysroot = resolved
                    .deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("share/wasi-sysroot")
                if FileManager.default.fileExists(atPath: sysroot.path) {
                    cachedSysroot = sysroot
                }
                return cachedClangURL
            }
        }

        return nil
    }
}
```

Key compilation flags:
- `--target=wasm32-wasip1` — WASM target with WASI preview 1
- `-O2` — optimization (same as Rust)
- `-Wl,--no-entry` — no `main()` / `_start` function (this is a library, not a program)
- `-Wl,--export-dynamic` — export all non-static functions (so `process`, `get_input_ptr`, etc. are visible)
- `-mexec-model=reactor` — WASI reactor model (initialized once, called many times)

#### 3c: Build Phase for Bundling clang-dist

Add a "Copy C Compiler" Run Script build phase to the ConjureDSPExtension target in `ConjureDSP.xcodeproj/project.pbxproj`. Model it on the existing "Copy Rust Compiler" phase:

1. Copy `clang-dist/` into the extension's `Resources/` directory
2. Code-sign all executables and dylibs with `$EXPANDED_CODE_SIGN_IDENTITY`

Alternatively, extend the existing "Copy Rust Compiler" phase to also handle clang-dist.

#### 3d: Worktree Support

Add symlink logic for `clang-dist/` analogous to how `rust/build-rust.sh` handles `python-dist/` and the build phase handles `rustc-dist/`. Either:
- Add to the SessionStart hook in `.claude/settings.json`, or
- Add to the "Copy C Compiler" build phase to create the symlink if in a worktree

---

### Phase 4: AU Integration

**File: `ConjureDSPExtension/Common/Audio Unit/ConjureDSPExtensionAudioUnit.swift`**

#### 4a: `compileAndRun()` (line ~540)

Add a `.c` case that mirrors `.rust` — the only difference is instantiating `CCompiler()` instead of `RustCompiler()`:

```swift
case .c:
    let sourceParamNames = Self.parseRustParamNames(fromSource: source)
    // Note: parseRustParamNames works for C too — it looks for "// N (Name):" comments

    let cache = WasmCache()
    if let cachedWasm = cache.cachedWasm(for: source) {
        let result = loadWasm(bytes: cachedWasm)
        if result.success {
            currentScriptSource = source
            currentScriptLanguage = .c
            currentWasmBytes = cachedWasm
            if currentParamMetadata == nil, let names = sourceParamNames {
                currentParamNames = names
                paramNamesDidChange.send(names)
            }
        }
        return result
    }

    let compiler = CCompiler()
    do {
        let wasmBytes = try await compiler.compile(source: source)
        cache.cache(wasm: wasmBytes, for: source)
        let result = loadWasm(bytes: wasmBytes)
        if result.success {
            currentScriptSource = source
            currentScriptLanguage = .c
            currentWasmBytes = wasmBytes
            if currentParamMetadata == nil, let names = sourceParamNames {
                currentParamNames = names
                paramNamesDidChange.send(names)
            }
        }
        return result
    } catch {
        return (false, error.localizedDescription, nil, nil)
    }
```

Consider refactoring the `.rust` and `.c` cases into a shared helper since they're nearly identical — the only difference is which `ScriptCompiler` is instantiated. Something like:

```swift
case .rust, .c:
    let compiler: ScriptCompiler = language == .rust ? RustCompiler() : CCompiler()
    // ... shared compilation logic ...
```

#### 4b: `fullState` restore (line ~680)

Add `.c` case — same as `.rust` (try cached WASM bytes, fall back to recompilation):

```swift
case .c:
    if let wasmBytes = state[Self.wasmBytesKey] as? Data {
        let result = loadWasm(bytes: wasmBytes)
        // ... same as .rust case ...
    }
```

#### 4c: Factory preset loading (line ~790)

Add `.c` case — same pattern as `.rust`:

```swift
case .c:
    currentScriptSource = source
    currentScriptLanguage = .c
    scriptSourceDidChange.send(ScriptSourceChange(source: source))
    Task {
        let result = await self.compileAndRun(source: source)
        // ...
    }
```

#### 4d: Factory preset resource loading (line ~784)

Update the file extension lookup:

```swift
// Before:
let ext = entry.language == .rust ? "rs" : "py"

// After:
let ext: String
switch entry.language {
case .rust: ext = "rs"
case .c: ext = "c"
case .python: ext = "py"
}
```

---

### Phase 5: Preset System

#### 5a: Preset Model

**File: `ConjureDSPExtension/Model/Preset.swift`** (line 65–67)

```swift
// Before:
var fileExtension: String {
    language == .rust ? "rs" : "py"
}

// After:
var fileExtension: String {
    switch language {
    case .rust: return "rs"
    case .c: return "c"
    case .python: return "py"
    }
}
```

#### 5b: Factory Preset Registry

**File: `ConjureDSPExtension/Model/Preset.swift`** (line 80+)

Add C factory presets. Start with a passthrough and a gain preset at minimum:

```swift
Entry(name: "Passthrough (C)", number: 47, resourceName: "preset_passthrough_c", language: .c, category: .utility),
Entry(name: "Gain + Pan (C)", number: 48, resourceName: "preset_gainpan_c", language: .c, category: .utility),
```

Create corresponding files: `ConjureDSPExtension/Resources/preset_passthrough_c.c`, `preset_gainpan_c.c`.

#### 5c: PresetManager

**File: `ConjureDSPExtension/Model/PresetManager.swift`** (lines 168, 190)

Two places with `language == .rust ? "rs" : "py"` — update to switch or use `preset.fileExtension`.

---

### Phase 6: UI Updates

Many files use `language == .rust ? "Rust" : "Python"` ternaries. First, add a `displayName` computed property to `ScriptLanguage` to DRY this up:

**File: `ConjureDSPExtension/Compilation/ScriptLanguage.swift`**

```swift
var displayName: String {
    switch self {
    case .python: return "Python"
    case .rust: return "Rust"
    case .c: return "C"
    }
}
```

Then update all ternaries to use `language.displayName`. Files affected:

| File | Lines | Current Pattern |
|------|-------|----------------|
| `UI/PresetToolbar.swift` | 125 | `selectedLanguage == .python ? "Python" : "Rust"` |
| `UI/CommunityBrowserView.swift` | 149 | `entry.language == .rust ? "Rust" : "Python"` |
| `UI/PresetBrowserView.swift` | 223, 325 | `lang == .python ? "Python" : "Rust"` |
| `UI/ExportPopover.swift` | 34 | `language == .rust ? "Rust (WASM)" : "Python"` |
| `UI/ImportURLPopover.swift` | 52 | `detectedLanguage == .rust ? "Rust" : "Python"` |
| `UI/MonacoEditorView.swift` | 75, 157, 222 | `language == .rust ? "rust" : "python"` (Monaco lang ID) |

For `MonacoEditorView.swift`, add a `monacoLanguageId` property to `ScriptLanguage`:

```swift
var monacoLanguageId: String {
    switch self {
    case .python: return "python"
    case .rust: return "rust"
    case .c: return "c"
    }
}
```

For `ExportPopover.swift`, the display is `"Rust (WASM)"` vs `"Python"`. C should show `"C (WASM)"`:

```swift
var exportDisplayName: String {
    switch self {
    case .python: return "Python"
    case .rust: return "Rust (WASM)"
    case .c: return "C (WASM)"
    }
}
```

---

### Phase 7: GitHub Integration

**File: `ConjureDSPExtension/GitHub/GitHubService.swift`** (lines 66–67, 81–82, 195)

Three places with `language == .rust ? "rs" : "py"` and `language == .rust ? "rust" : "python"` (subdirectory name). Update to switches:

```swift
let ext = language.fileExtension  // use Preset's computed property or duplicate on ScriptLanguage
let subdir: String
switch language {
case .rust: subdir = "rust"
case .c: subdir = "c"
case .python: subdir = "python"
}
```

**File: `ConjureDSPExtension/GitHub/PersonalRepoSync.swift`** (line 178)

Same pattern — `conflict.language == .rust ? "rust" : "python"` → switch.

**File: `ConjureDSPExtension/GitHub/CommunityPresetStore.swift`** (line 191)

Same pattern.

---

### Phase 8: Export Pipeline

**File: `ConjureDSPExtension/Export/ExportManager.swift`** (lines 66–68, 86–96)

```swift
// Guard: C also needs WASM data (same as Rust)
if language == .rust || language == .c {
    guard wasmData != nil else { throw ExportError.missingWasmData }
}

// Write preset:
switch language {
case .rust, .c:
    try wasmData!.write(to: appexResourcesURL.appendingPathComponent("preset.wasm"))
case .python:
    try Data(source.utf8).write(to: appexResourcesURL.appendingPathComponent("preset.py"))
    // Remove placeholder WASM...
}
```

**File: `ConjureDSPExtension/Common/UI/AudioUnitViewController.swift`** (lines 355, 393)

```swift
// Line 355: file extension for export
let ext = language.fileExtension  // or switch

// Line 393: WASM data requirement
if (language == .rust || language == .c) && wasmData == nil {
```

---

### Phase 9: AI Chat Integration

#### 9a: C API Contract

**File: `ConjureDSPExtension/AI/AnthropicProvider.swift`**

Add `static let cApiContract` string (analogous to `rustApiContract`). Content should describe:
- The C WASM function signature
- Buffer layout (channel-sequential float arrays)
- Parameter metadata JSON format
- `__attribute__((export_name(...)))` for WASM exports
- Available headers: `math.h`, `string.h`, `stdlib.h` (via wasi-libc)
- Persistent state via `static` variables
- Restrictions: no file I/O, no dynamic allocation in hot path, no printf

#### 9b: System Prompt Dispatch

**File: `ConjureDSPExtension/AI/AnthropicProvider.swift`** (line ~238)

```swift
case .c:
    languageContract = cApiContract
    languageRules = cRealTimeRules  // similar to rustRealTimeRules
    otherLanguageNote = "Python and Rust scripts are also supported."
```

#### 9c: Tool Descriptions

**File: `ConjureDSPExtension/AI/ChatTools.swift`**

Update `compile_and_run` description to mention C:
```
"For Python, Rust, or C scripts. Language is auto-detected from source."
```

---

### Phase 10: Syntax Highlighting (Optional)

Monaco already supports C syntax highlighting natively. The `MonacoEditorView` just needs to pass `"c"` as the language ID (covered in Phase 6).

For the fallback `HighlightedTextEditor` (used when Monaco isn't available), optionally create a `CSyntaxHighlighter` following the `SyntaxHighlighter` protocol. This is low priority — Monaco is the primary editor.

---

### Phase 11: Tests

#### Unit Tests

**File: `ConjureDSPTests/ConjureDSPTests.swift`** (or new test file)

- `ScriptLanguage.detect()` tests:
  - `void process(...)` → `.c`
  - `#include <math.h>` → `.c`
  - `fn process(` → `.rust` (not misdetected as C)
  - `def process(` → `.python`
  - Ambiguous/empty → `.python` (default)

- `Preset.fileExtension` tests:
  - `.c` → `"c"`

- Factory preset count: update the Rust preset count assertion to include C presets

#### Integration Tests

- Compile the C gain template end-to-end via `CCompiler.compile()` and verify WASM output
- Load compiled WASM into `WasmBackend` and verify `process()` executes
- Verify `WasmCache` stores and retrieves C-compiled WASM

---

## C-Specific Design Decisions

### Which headers to support

wasi-libc provides the standard C library. For DSP, the most relevant headers are:
- `<math.h>` — `sinf`, `cosf`, `expf`, `powf`, `fabsf`, `sqrtf`, `log10f`, `tanhf`, `fmodf`, `floorf`, `ceilf`
- `<string.h>` — `memcpy`, `memset` (for buffer initialization)
- `<stdlib.h>` — `malloc`/`free` (discouraged in real-time code, but available)
- `<stdint.h>` — `int32_t`, `uint32_t`, etc.

### What about C++?

Not included in this plan. C++ would require bundling `libc++` for WASM (~additional 50MB) and introduces complexity around templates, exceptions, and RTTI in WASM. C covers the "familiar compiled language" use case. C++ can be added later if there's demand.

### WASM export mechanism

C uses `__attribute__((export_name("...")))` to mark WASM exports. This is a clang extension that's the standard way to export functions from C to WASM. It's equivalent to Rust's `#[no_mangle] pub extern "C" fn`.

Alternative: use `-Wl,--export=process,--export=get_input_ptr,...` linker flags. But the attribute approach is self-documenting in the source code.

### Persistent state

C uses `static` variables for persistent state (delay lines, filter memory, etc.), same as Rust uses `static mut`. In WASM, these live in linear memory and persist across `process()` calls. They're reset when the module is reloaded (same behavior as Rust).

---

## File Summary

### New files
| File | Description |
|------|-------------|
| `ConjureDSPExtension/Compilation/CCompiler.swift` | C → WASM compiler (mirrors RustCompiler) |
| `ConjureDSPExtension/Resources/process.c` | Default C template |
| `ConjureDSPExtension/Resources/preset_passthrough_c.c` | Factory preset |
| `scripts/setup-clang.sh` | Downloads wasi-sdk |

### Modified files
| File | Change |
|------|--------|
| `ConjureDSPExtension/Compilation/ScriptLanguage.swift` | Add `.c` case, detection, `displayName`, `monacoLanguageId` |
| `ConjureDSPExtension/Common/Audio Unit/ConjureDSPExtensionAudioUnit.swift` | Add `.c` to `compileAndRun()`, fullState, factory loading |
| `ConjureDSPExtension/Model/Preset.swift` | `fileExtension` switch, factory registry entries |
| `ConjureDSPExtension/Model/PresetManager.swift` | File extension ternaries → switch (2 places) |
| `ConjureDSPExtension/Export/ExportManager.swift` | WASM guard + preset write for `.c` |
| `ConjureDSPExtension/AI/AnthropicProvider.swift` | Add `cApiContract`, update `chatSystemPrompt()` |
| `ConjureDSPExtension/AI/ChatTools.swift` | Update tool descriptions |
| `ConjureDSPExtension/UI/MonacoEditorView.swift` | Language ID mapping (3 places) |
| `ConjureDSPExtension/UI/PresetToolbar.swift` | Display name |
| `ConjureDSPExtension/UI/PresetBrowserView.swift` | Display name (2 places) |
| `ConjureDSPExtension/UI/CommunityBrowserView.swift` | Display name |
| `ConjureDSPExtension/UI/ExportPopover.swift` | Display name |
| `ConjureDSPExtension/UI/ImportURLPopover.swift` | Display name |
| `ConjureDSPExtension/Common/UI/AudioUnitViewController.swift` | File extension + WASM guard |
| `ConjureDSPExtension/GitHub/GitHubService.swift` | File extension + subdirectory (3 places) |
| `ConjureDSPExtension/GitHub/PersonalRepoSync.swift` | Subdirectory mapping |
| `ConjureDSPExtension/GitHub/CommunityPresetStore.swift` | Language display |
| `ConjureDSP.xcodeproj/project.pbxproj` | Add new files, build phase for clang-dist |
| `.gitignore` | Add `clang-dist/` |
| `CLAUDE.md` | Document C as third language |

### Unchanged (no modifications needed)
| File | Reason |
|------|--------|
| `rust/conjure_dsp/src/*` | WasmBackend is already language-agnostic |
| `ConjureDSPExtension/Compilation/ScriptCompiler.swift` | Protocol is generic enough |
| `ConjureDSPExtension/Compilation/WasmCache.swift` | Caches by source hash, language-agnostic |

---

## Verification Plan

1. **Unit tests pass**: `xcodebuild test` — ScriptLanguage detection, preset counts, file extensions
2. **C template compiles**: Open app → new C script → click Run → no errors, audio passes through
3. **Factory presets load**: Passthrough (C) appears in preset browser, loads and runs
4. **WASM caching**: Compile a C script, modify it slightly, verify cache miss; revert, verify cache hit
5. **Export works**: Export a C preset as standalone AU, verify it loads in a DAW
6. **AI generates C**: Switch to C script, ask AI to "make a low-pass filter" — verify it produces valid C
7. **Monaco highlighting**: C syntax is highlighted correctly (keywords, types, comments)
8. **GitHub sync**: Save a C preset to personal repo, verify it appears in `c/` subdirectory
9. **Sandboxed DAW**: Load ConjureDSP in Logic Pro, compile a C script — verify bundled clang works

---

## Recommended Implementation Order

1. **Phase 1** (ScriptLanguage) — everything depends on this
2. **Phase 2** (process.c template) — needed for manual testing
3. **Phase 3** (CCompiler + setup script) — core functionality
4. **Phase 4** (AU integration) — makes it actually work end-to-end
5. **Phase 5** (Preset system) — file extensions + factory presets
6. **Phase 6** (UI updates) — display names everywhere
7. **Phase 7** (GitHub) — sync support
8. **Phase 8** (Export) — standalone AU export
9. **Phase 9** (AI) — chat sidebar support
10. **Phase 11** (Tests) — can be written alongside each phase
11. **Phase 10** (Syntax highlighting fallback) — lowest priority, Monaco handles it
