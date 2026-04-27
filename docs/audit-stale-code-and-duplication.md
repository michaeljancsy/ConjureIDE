# Audit: stale-code traps and main-extension ↔ export-template duplication

You are doing a research-and-recommendation pass. **Do not refactor or fix
anything yet.** Produce a written audit. The user will read it, decide what
to act on, and spawn implementation work separately.

## Why this audit exists

In recent sessions, debugging has repeatedly stalled because the code
actually executing wasn't the code we thought we were editing. Each
incident burned hours. Concrete examples (`git log` for full context):

1. **`10fbdeb`, `7eae15e` (cdp-ui.js / customui-bridge.js / BundleAssetSchemeHandler symlinking).** Export template shipped a 5-commit-stale `cdp-ui.js`, breaking `<cdp-xy>` in every exported AU, because the export template kept its own duplicate file. Fix: replace duplicates with symlinks; `CustomUIAssetParityTests` enforces hash equality.

2. **`c30d891` (cdp-xy stuck at parameter extremes).** The export's `ExportCustomUIWebView.paramSet` handler used `(body["value"] as? Double).map(Float.init) ?? (body["value"] as? Float)`, which Swift overload-resolves to the **failable** `Float.init?(exactly:)`. Every fractional Double silently failed the cast. The main extension's `CustomUIWebView` did `if let d = body["value"] as? Double { Float(d) }` — concrete-argument application, picks the non-failable narrowing init. Two lines that look equivalent. Aren't. Diagnosis took hours because the JS code was identical (symlinked) but Swift behavior diverged. `CustomUIParamSetCastTests` pins the language semantics + a structural grep on both handlers.

3. **`1b6fe55` (export-template build script).** Xcode's incremental Copy Bundle Resources phase tracks the symlink's own mtime, not the target's. Edits to the JS targets didn't trigger a rebuild. AND `[ "$ZIP" -nt "$SRC_APP_DIR" ]` wrongly said "zip is fresh" because the `.app` directory's mtime doesn't update when only files inside it change. So Xcode reported `BUILD SUCCEEDED` while shipping stale JS through multiple "rebuild + drag the puck" iterations. Fix: `find -L` + `.js .css .html`, always re-zip.

The pattern: **a duplicate-code situation, plus a build pipeline that
silently picks the wrong copy.** Either alone is recoverable; together
they manifest as "the test passes but the running app is broken" or
"the user sees a different bug than the static analysis suggests."

## What you must produce

A single Markdown document, `docs/audit-stale-code-and-duplication-findings.md`,
with three sections:

### Section 1 — Stale-code traps

Inventory every place where the code that *runs* could differ from the
code that's *checked into the repo*. Spend most of your time here. For
each finding, document:

- **Location** (file/path/script).
- **Mechanism** — how does the wrong copy get loaded? (Build cache,
  symlink target vs link, FSEvent debounce, lazy import, MCP server
  serving stale tool registry, packaged Python/Rust runtime in
  DerivedData, etc.)
- **Detection cost** — how would someone notice this is happening
  *before* burning an hour on phantom debugging? (mtime check, sha
  diff, test that loads the actual artifact, etc.)
- **Suggested invariant** — a one-line claim a test or build step
  could enforce. Don't write the test; just describe the contract.

Specific places worth probing (not exhaustive — find more):

- `scripts/rebuild-and-copy-export-template.sh` (recently hardened —
  any remaining gaps?)
- The `Copy Bundle Resources` Xcode phase for any symlinked source.
  Does it follow symlinks correctly across all configurations?
- `ConjureDSPExtension/Resources/presets/preset_*.cdp/` factory
  bundles — are these copied verbatim by Xcode's
  `PBXFileSystemSynchronizedRootGroup`? What if a sub-file changes?
- The bundled Python runtime (`rust/python-dist/`), bundled Rust
  compiler (`rustc-dist/`), Monaco (`Resources/monaco/`) — these are
  large, gitignored, often symlinked across worktrees. When are they
  re-staged? When are they stale?
- `WasmCache` (SHA256-keyed compiled WASM blobs in App Group). Can
  this serve a stale WASM if the source script's hash collides or if
  the cache key is wrong?
- The MCP tool registry exposed by `MCPProtocol.swift` — if the agent
  in `ConjureDSPTerminal` connects before the AU is realized, does it
  see a stale tool list? Does the embedded Claude Code CLI cache its
  tool schemas?
- `ExportTemplate.zip` bundled into the appex. The new always-re-zip
  fix landed; verify there are no other paths that touch this artifact.
- Any test fixture that's a copy of a production file (search for
  duplicate filenames across `ConjureDSPLogicTests/`, `ConjureDSPTests/`,
  `ConjureDSPExportAUTemplateTests/` and cross-check against
  `ConjureDSPExtension/`).
- `ExportManager.swift` is duplicated into `ConjureDSPLogicTests/`
  and `ConjureDSPTests/` because the test targets can't import the
  extension module. How is drift between the three copies prevented?
  Can it be?
- Worktree-specific symlinks set up by the `.claude/settings.json`
  session-start hooks. What if a hook fails silently?

### Section 2 — Duplicated code that could be shared

Inventory every code pair / triple where the same logic exists in
multiple files. Already known:

| Main extension | Export template | Status |
|---|---|---|
| `ConjureDSPExtension/Resources/cdp-ui.js` | `…/Resources/cdp-ui.js` | Symlink (commit `10fbdeb`) |
| `…/Resources/customui-bridge.js` | `…/Resources/customui-bridge.js` | Symlink (commit `10fbdeb`) |
| `…/UI/BundleAssetSchemeHandler.swift` | `…/UI/BundleAssetSchemeHandler.swift` | Symlink (commit `7eae15e`) |
| `…/UI/CustomUIWebView.swift` | `…/UI/ExportCustomUIWebView.swift` | **Duplicate** (caused `c30d891`) |
| `…/UI/ParameterState.swift` | `…/UI/ExportParameterState.swift` | **Duplicate** (slider-drag fix `d5dc463` had to be applied twice) |
| `…/Audio/AudioCaptureManager.swift` | `…/Audio/ExportAudioCaptureManager.swift` | **Duplicate** (flagged in Asana backlog `1214270155716952`) |
| `…/Common/Audio Unit/ConjureDSPExtensionAudioUnit.swift` (parameter-tree builder + render-thread event handler) | `ExportAUAudioUnit.swift` (same) | **Partial duplicate** (commit `537aef8` was a "we forgot to mirror this" fix) |
| `ParamMetadata` struct in `ConjureDSPExtensionAudioUnit.swift` | `ExportParamMetadata` struct in `RuntimeConfig.swift` | **Duplicate**; also a third copy in `ConjureDSPLogicTests/ExportManager.swift` |
| `ExportManager.swift` (production) | `ConjureDSPLogicTests/ExportManager.swift`, `ConjureDSPTests/ExportManager.swift` | **Duplicate** (test targets can't import the extension module) |

Find anything missed. Then for each duplicate, propose ONE of:

- **(a) Symlink** — works when the files truly should be byte-identical.
  Cheap, structurally enforced. The pattern proven in `10fbdeb` /
  `7eae15e`. Note any blocker (compilation context, target membership,
  module access).
- **(b) Refactor to a shared Swift module** — e.g. a small Swift package
  or framework that both targets depend on. Heavier; may run into AU
  extension sandbox / signing concerns. Identify which files are good
  candidates and which aren't.
- **(c) Build-time generation** — one source of truth, generated into
  both. Document the trade-off (build complexity vs. drift prevention).
- **(d) Keep separate, document why** — when the "Export*" sibling is
  deliberately a stripped-down or different-purpose variant, the
  divergence is a feature. Note it explicitly so future audits know.
- **(e) Equivalence test** — when actual sharing is impractical, a
  unit test that exercises both copies' behavior on the same input
  and asserts identical output. The pattern from
  `CustomUIParamSetCastTests` (which scans both `CustomUIWebView` and
  `ExportCustomUIWebView` source for a forbidden idiom). Cheap;
  fails fast on regressions.

### Section 3 — Prioritized recommendations

A short list (5–10 items) sorted by **expected hours saved per quarter
× ease of implementation**. Each item one paragraph: what to do, what
the trade-off is, what the rough effort is. Don't write code. Don't
estimate in story points; just say "small / medium / large" and
explain.

## Constraints

- **Read-only investigation.** No edits to source files. Run `Grep`,
  `Read`, `Glob`, `git log`, `git blame`, scripts that inspect the
  build output. The single artifact you produce is the audit
  Markdown.
- **Verify claims.** Don't assert "X drifts from Y" without showing
  a diff or a hash mismatch. The user has been burned multiple times
  by confident-sounding analysis that turned out to be wrong.
- **Cite paths and commits.** Every finding should reference at least
  one specific file path and one git commit when relevant. Use
  `git log --follow <path>` to trace history through renames.
- **Be specific about cost.** "Refactor X into a shared module" is
  worthless without a sense of whether that means an afternoon or a
  week. When uncertain, say so.
- **Don't speculate about Apple internals.** When you say "Xcode does
  X with symlinks," verify with a quick experiment (extract the
  bundled artifact, sha vs source, etc.) rather than asserting from
  memory.
- **Read `CLAUDE.md` first** — it documents the architecture, build
  pipeline, and prior decisions you'll need context for.

## Definition of done

A reviewer should be able to read your audit and, for any single
recommendation, immediately know:

1. What problem it solves (linked to a real past incident or a
   plausible future one).
2. Roughly what the implementation looks like.
3. Roughly how long it'll take.
4. Whether it's worth doing now vs. later.

If a recommendation can't be answered with all four, leave it out.
