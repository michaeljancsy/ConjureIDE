# Adding Faust as a Third DSP Language

## Overview

Add [Faust](https://faust.grame.fr/) — a functional DSP programming language — as a third scripting language alongside Python and Rust. Faust source is compiled to C via the `faust` CLI, then a generated C shim adapts Faust's API to ConjureDSP's WASM ABI, and finally clang/wasi-sdk compiles the shim to WASM. The existing `WasmBackend` runs the result unchanged — zero Rust kernel changes needed.

### Why Faust?

- **Functional DSP language** designed specifically for audio signal processing, with 20+ years of maturity
- **Rich standard library** (filters, oscillators, delays, compressors, reverbs, etc.) — no need for a separate `conjuredsp` library
- **Natural fit**: Faust's `compute(count, float** inputs, float** outputs)` output maps to ConjureDSP's flat-buffer `process()` paradigm, unlike Cmajor (which has an incompatible endpoint/graph execution model)
- **Well-established community** in academic and electronic music / sound design circles

### Why not Cmajor?

Cmajor was evaluated but has a fundamental execution model mismatch: it uses an endpoint/graph model with per-sample `advance()` loops, not a per-buffer `process()` function. Bridging this would require a new backend type in the Rust kernel. See the analysis in `plans/scripting-languages.md` (Existing Art section) for context.

### Dependency on C support

This plan requires the wasi-sdk infrastructure from `docs/adding C support.md` — specifically `scripts/setup-clang.sh`, the bundled clang-dist, and the CCompiler class. The FaustCompiler internally delegates to CCompiler for the C→WASM stage.

## Compilation Pipeline

```
user.dsp (Faust source)
    → faust -lang c -cn dsp (generates C code with struct + compute)
    → FaustShimGenerator (Swift) prepends WASM ABI wrapper + parameter metadata
    → clang (wasi-sdk, wasm32-wasip1) → .wasm
    → existing WasmBackend (unchanged)
```

## What Faust Looks Like

A simple gain effect:

```faust
import("stdfaust.lib");

gain = hslider("Gain[unit:dB]", 0, -24, 12, 0.1) : si.smoo;

process = _ * ba.db2linear(gain);
```

- `process` is the entry point (like Python's `def process()` or Rust's `fn process()`)
- `_` represents an input signal
- `:` chains operations (like Unix pipes)
- Parameters are declared inline via `hslider`/`vslider`/`nentry`/`checkbox`/`button`
- `si.smoo` adds exponential parameter smoothing
- Faust auto-broadcasts mono operations to match channel count

A resonant lowpass filter:

```faust
import("stdfaust.lib");

cutoff = hslider("Cutoff[unit:Hz][scale:log]", 1000, 20, 20000, 1) : si.smoo;
q = hslider("Resonance", 1, 0.5, 10, 0.01) : si.smoo;

process = fi.resonlp(cutoff, q, 1);
```

## Implementation Phases

### Phase 1: ScriptLanguage Enum + Detection

**File: `ConjureDSPExtension/Compilation/ScriptLanguage.swift`**

Add `.faust` case. Detection heuristics — checked after Rust (which has unambiguous markers) but before the Python default:

```swift
enum ScriptLanguage: String, CaseIterable {
    case python
    case rust
    case faust

    static func detect(from source: String) -> ScriptLanguage {
        // Rust: unambiguous markers (modern process! + persist! / legacy setup!() / hand-rolled #[no_mangle])
        if source.contains("process!") || source.contains("persist!") || source.contains("persist_buf!")
            || source.contains("fn process(") || source.contains("#[no_mangle]")
            || source.contains("use conjuredsp") || source.contains("setup!()")
        {
            return .rust
        }
        // Faust: process = ... is the canonical entry point
        if source.contains("process =") || source.contains("import(\"stdfaust.lib\")")
            || source.contains("hslider(") || source.contains("vslider(")
            || source.contains("library(\"")
        {
            return .faust
        }
        return .python
    }
}
```

`process =` is the canonical Faust entry point (it's an assignment, not a function definition like Python's `def process` or Rust's `fn process`). Combined with `hslider(`/`vslider(` and `import("stdfaust.lib")`, this gives strong detection without false positives.

Add computed properties used by UI and Monaco:

```swift
var displayName: String {
    switch self {
    case .python: "Python"
    case .rust: "Rust"
    case .faust: "Faust"
    }
}

var monacoLanguageId: String {
    switch self {
    case .python: "python"
    case .rust: "rust"
    case .faust: "faust"  // custom language definition needed
    }
}

var fileExtension: String {
    switch self {
    case .python: "py"
    case .rust: "rs"
    case .faust: "dsp"  // Faust convention
    }
}
```

---

### Phase 2: Faust Template Script

**New file: `ConjureDSPExtension/Resources/process.dsp`**

```faust
// ConjureDSP DSP — Faust Template
//
// Faust is a functional DSP language. The `process` expression defines
// the audio signal flow. Parameters are declared with hslider/vslider.
//
// Docs: https://faustdoc.grame.fr

import("stdfaust.lib");

gain = hslider("Gain[unit:dB]", 0, -24, 12, 0.1) : si.smoo;

process = _ * ba.db2linear(gain);
```

---

### Phase 3: Parameter Extraction from Faust Source

**New utility: `FaustParameterParser`**

Parse the Faust source text for UI element declarations to generate `ParamMetadata` JSON. Faust UI elements follow a consistent syntax:

```
hslider("Name[key:value][key:value]", default, min, max, step)
vslider("Name[key:value]", default, min, max, step)
nentry("Name", default, min, max, step)
checkbox("Name")
button("Name")
```

**Regex patterns:**

```swift
// Match: hslider("Name[metadata]", default, min, max, step)
let sliderPattern = #"(?:hslider|vslider|nentry)\s*\(\s*"([^"]+)"\s*,\s*([^,]+)\s*,\s*([^,]+)\s*,\s*([^,]+)\s*,\s*([^)]+)\)"#

// Match: checkbox("Name") — always 0/1
let checkboxPattern = #"checkbox\s*\(\s*"([^"]+)"\s*\)"#

// Match: button("Name") — always 0/1
let buttonPattern = #"button\s*\(\s*"([^"]+)"\s*\)"#
```

**Metadata annotation mapping** from the name string (e.g., `"Cutoff[unit:Hz][scale:log]"`):

| Faust annotation | ConjureDSP ParamMetadata field |
|-----------------|-------------------------------|
| `[unit:dB]` | `"unit": "dB"` |
| `[unit:Hz]` | `"unit": "Hz"` |
| `[scale:log]` | `"curve": "log"` |
| `[scale:exp]` | `"curve": "log"` (same mapping) |
| `[style:knob]` | `"style": "slider"` (visual only, same type) |
| checkbox/button | `"style": "toggle"`, min:0, max:1 |

Strip annotations from name for display: `"Cutoff[unit:Hz][scale:log]"` → name: `"Cutoff"`, unit: `"Hz"`, curve: `"log"`.

ConjureDSP supports max 16 parameters. If the Faust source declares more, take the first 16 and log a warning.

---

### Phase 4: C Shim Generation

After `faust -lang c` generates C code and parameters are parsed, generate a C wrapper that bridges Faust's API to the ConjureDSP WASM ABI.

The core bridging challenge: Faust's `compute()` expects `float**` (array of per-channel pointers) while ConjureDSP uses channel-sequential flat arrays. The shim handles this de-interleaving, along with copying parameter values from the flat `PARAMS_BUF[16]` into Faust's struct member fields.

The generated C file concatenates:
1. The Faust-generated C code (struct definition, init, compute, buildUserInterface)
2. The WASM ABI shim (static buffers, exports, process wrapper)

**Shim template** (the `{PLACEHOLDERS}` are filled by Swift):

```c
// --- Begin ConjureDSP WASM ABI Shim ---

#define MAX_CH 2
#define MAX_FR 4096

static float INPUT_BUF[MAX_CH * MAX_FR];
static float OUTPUT_BUF[MAX_CH * MAX_FR];
static float PARAMS_BUF[16];
static float TRANSPORT_BUF[6];

// Faust DSP instance (global, persistent across process() calls)
static dsp faust_dsp;
static int initialized = 0;

// Per-channel pointer arrays for Faust's compute()
static float* input_ptrs[MAX_CH];
static float* output_ptrs[MAX_CH];

__attribute__((export_name("get_input_ptr")))
int get_input_ptr(void) { return (int)INPUT_BUF; }

__attribute__((export_name("get_output_ptr")))
int get_output_ptr(void) { return (int)OUTPUT_BUF; }

__attribute__((export_name("get_params_ptr")))
int get_params_ptr(void) { return (int)PARAMS_BUF; }

__attribute__((export_name("get_transport_ptr")))
int get_transport_ptr(void) { return (int)TRANSPORT_BUF; }

// Parameter metadata (generated from Faust source)
static const char METADATA[] = {METADATA_JSON};

__attribute__((export_name("get_param_metadata_ptr")))
int get_param_metadata_ptr(void) { return (int)METADATA; }

__attribute__((export_name("get_param_metadata_len")))
int get_param_metadata_len(void) { return sizeof(METADATA) - 1; }

__attribute__((export_name("process")))
void process(int input_addr, int output_addr, int channels, int frame_count, float sample_rate) {
    if (!initialized) {
        initdsp(&faust_dsp, (int)sample_rate);
        initialized = 1;
    }

    // Map PARAMS_BUF values to Faust struct fields
    {PARAM_MAPPING}
    // e.g.: faust_dsp.fHslider0 = PARAMS_BUF[0];
    //       faust_dsp.fHslider1 = PARAMS_BUF[1];

    // Convert channel-sequential layout to per-channel pointers
    int ch = channels < MAX_CH ? channels : MAX_CH;
    for (int c = 0; c < ch; c++) {
        input_ptrs[c] = INPUT_BUF + c * frame_count;
        output_ptrs[c] = OUTPUT_BUF + c * frame_count;
    }

    computedsp(&faust_dsp, frame_count, input_ptrs, output_ptrs);
}
```

**The `{PARAM_MAPPING}` placeholder** is generated by matching Faust parameter names to struct fields. The `faust -lang c` output's `buildUserInterface` function contains lines like:

```c
ui_interface->addHorizontalSlider(ui_interface->uiInterface, "Gain", &dsp->fHslider0, ...);
```

Parse these to build the mapping: parameter index (from extraction order in Phase 3) → struct field name (`fHslider0`, `fVslider0`, `fCheckbox0`, etc.).

**Important:** Use `faust -cn dsp` to name the struct `dsp` (instead of default `mydsp`) so the shim can use predictable function names: `initdsp()`, `computedsp()`.

---

### Phase 5: FaustCompiler Implementation

**New file: `ConjureDSPExtension/Compilation/FaustCompiler.swift`**

Implements `ScriptCompiler` protocol. Compilation flow:

1. Find faust binary (bundled `Resources/faust-dist/bin/faust` or system fallback)
2. Parse parameters from Faust source (Phase 3)
3. Run `faust -lang c -cn dsp -o dsp.c input.dsp`
4. Read generated C, parse `buildUserInterface` for field→param mapping
5. Generate combined C file (Faust output + WASM ABI shim)
6. Delegate to `CCompiler` for C→WASM compilation

Follows the same pattern as `RustCompiler.swift`: bundled toolchain preferred for sandbox compatibility, system fallback for development.

---

### Phase 6: Faust Compiler Bundling (Deferred)

**New file: `scripts/setup-faust.sh`**

Downloads a minimal Faust compiler binary + standard libraries.

**What to bundle:**
- `bin/faust` — the compiler binary
- `share/faust/*.lib` — standard libraries (filters.lib, oscillators.lib, etc. — ~2MB)

**Bundle size concern:** The Homebrew faust formula depends on LLVM (~500MB). But `faust -lang c` doesn't need LLVM at runtime. Options:
1. Build faust from source with only C/C++ backends (no LLVM) — ~5-10MB binary
2. Start with system-only (require Homebrew) and add bundling later

**Recommendation:** Start with system fallback only. Bundle later once the feature is validated.

---

### Phase 7: Error Parsing

**File: `ConjureDSPExtension/Compilation/ErrorLineParser.swift`**

Add `case .faust`. Two error formats to parse:

**Faust errors** (from `faust -lang c`):
```
input.dsp : 5 : ERROR : undefined symbol 'foo'
```

**Clang errors** (from C→WASM stage):
```
dsp.c:42:5: error: use of undeclared identifier 'bar'
```

The parser tries both patterns. Faust errors map directly to user source lines. Clang errors reference the generated C file — shown as-is since they indicate issues in the shim/codegen rather than user code.

---

### Phase 8: AU Integration

**File: `ConjureDSPExtension/Common/Audio Unit/ConjureDSPExtensionAudioUnit.swift`**

The `.faust` case in `compileAndRun()` is identical to `.rust` — detect language, check WASM cache, compile if miss, load WASM. Refactor into a shared WASM compilation path:

```swift
case .rust, .faust:
    let compiler: ScriptCompiler = language == .rust ? RustCompiler() : FaustCompiler()
    // ... shared cache → compile → load WASM logic ...
    currentScriptLanguage = language
```

Also update: `fullState` restore, factory preset loading, file extension lookup.

---

### Phase 9: Preset System

**File: `ConjureDSPExtension/Model/Preset.swift`**
- `fileExtension`: add `.faust` → `"dsp"`
- Factory preset registry: add Faust presets (Gain, Tremolo at minimum)

**File: `ConjureDSPExtension/Model/PresetManager.swift`**
- Add `"dsp"` to `supportedExtensions`
- Update extension→language ternaries to switches

---

### Phase 10: UI Updates

Many files use `language == .rust ? X : Y` ternaries. Replace with computed properties from Phase 1.

**Files to update:**

| File | Change |
|------|--------|
| `UI/PresetToolbar.swift` | Add "Faust" button to new script dialog, use `displayName` |
| `UI/PresetBrowserView.swift` | Use `displayName` |
| `UI/CommunityBrowserView.swift` | Use `displayName` |
| `UI/ExportPopover.swift` | Add `"Faust (WASM)"` display |
| `UI/ImportURLPopover.swift` | Display name + extension detection |
| `UI/MonacoEditorView.swift` | Use `monacoLanguageId` |
| `GitHub/GitHubService.swift` | File extension + subdirectory |
| `GitHub/PersonalRepoSync.swift` | Extension + subdirectory |
| `GitHub/CommunityPresetStore.swift` | Language display |
| `Export/ExportManager.swift` | WASM guard + preset write (same as .rust) |
| `Common/UI/AudioUnitViewController.swift` | Extension + WASM guard |

---

### Phase 11: Monaco Editor Support

**File: `ConjureDSPExtension/Resources/monaco/editor-bridge.js`**

Monaco doesn't have built-in Faust support. Register a custom language with:
- Monarch tokenizer (keywords, UI elements, operators, comments, strings)
- Completion provider (standard library functions, UI element snippets)
- Hover provider (documentation for common functions)

---

### Phase 12: Export Pipeline

Faust presets export as WASM (identical to Rust path):

```swift
case .rust, .faust:
    guard let wasmData = wasmData else { throw ExportError.missingWasmData }
    try wasmData.write(to: appexResourcesURL.appendingPathComponent("preset.wasm"))
```

---

### Phase 13: Tests

**Unit tests:**
- `ScriptLanguageTests`: detection for `process =`, `hslider(`, `import("stdfaust.lib")` → `.faust`
- `FaustParameterParser` tests: parse hslider/vslider/nentry/checkbox with metadata annotations
- `ErrorLineParser` tests: parse Faust error format

**Integration tests (requires faust + wasi-sdk):**
- Compile Faust gain template end-to-end → verify WASM output
- Load compiled WASM into DSP kernel → process sine wave → verify gain applied
- Verify WasmCache stores and retrieves Faust-compiled WASM

---

### Phase 14: Documentation

- Update `CLAUDE.md`: Faust in multi-language DSP section, compilation pipeline, prerequisites
- Update `backlog.md`: track Faust support status

## Implementation Order

C support infrastructure (`docs/adding C support.md` Phases 1-3) is a prerequisite. Then:

1. Phase 1 — ScriptLanguage enum
2. Phase 2 — Template script
3. Phase 3 — Parameter parser
4. Phase 4 — Shim generator
5. Phase 5 — FaustCompiler
6. Phase 8 — AU integration
7. Phase 9 — Preset system
8. Phase 10 — UI ternary cleanup
9. Phase 11 — Monaco editor support
10. Phase 7 — Error parsing
11. Phase 12 — Export
12. Phase 13 — Tests (alongside each phase)
13. Phase 6 — Faust bundling (deferred)
14. Phase 14 — Documentation

## Effort Estimates

| Phase | Effort |
|-------|--------|
| C support prerequisite (Phases 1-3 of C plan) | 3-4 days |
| Phases 1-2: Language enum + template | 1 hour |
| Phases 3-4: Parameter parser + shim generator | 2-3 days |
| Phase 5: FaustCompiler | 1 day |
| Phase 6: Bundling (deferred) | 1-2 days |
| Phase 7: Error parsing | 2 hours |
| Phases 8-10: AU + presets + UI | 1-2 days |
| Phase 11: Monaco | 1 day |
| Phase 12: Export | 1 hour |
| Phases 13-14: Tests + docs | 1-2 days |
| **Total (including C prerequisite)** | **~10-14 days** |

## Verification Plan

1. Install faust via Homebrew: `brew install faust`
2. Run `scripts/setup-clang.sh` for wasi-sdk
3. Open app → New Script → Faust → see template
4. Click Run → compiles (faust → C → WASM) → audio passes through
5. Modify gain parameter in UI → audio level changes
6. Add a second parameter (e.g., cutoff filter) → parameter appears in UI with correct range
7. Load Tremolo (Faust) factory preset → modulation effect audible
8. Export Faust preset as standalone AU → loads in Logic Pro
9. Save Faust preset → `.dsp` file created → reloads correctly
10. Type invalid Faust syntax → error markers appear in editor at correct line

## Key Design Decisions

**Why faust → C → WASM (not faust → WASM directly)?**
Faust's built-in WASM backend (`-lang wasm`) generates browser-targeted WebAssembly that imports `Math.*` from JavaScript. It doesn't produce wasm32-wasip1 modules. Going through C avoids this mismatch and reuses the existing wasi-sdk infrastructure.

**Why parse Faust source for parameters (not generated C)?**
The Faust source has clean, parseable parameter declarations (`hslider("Name", default, min, max, step)`). The generated C's `buildUserInterface` is also parseable but more fragile (depends on faust codegen format). We parse source for metadata and generated C only for field name mapping (which struct field corresponds to which parameter).

**Why not bundle faust initially?**
The faust binary from Homebrew links LLVM (~500MB). Building a minimal faust without LLVM is possible but requires building from source with CMake. Deferring bundling lets us validate the feature before investing in the build infrastructure.

**Why `.dsp` extension (not `.faust`)?**
`.dsp` is Faust's standard file extension, used by all Faust tools and documentation. Existing Faust files can be dropped into ConjureDSP without renaming.
