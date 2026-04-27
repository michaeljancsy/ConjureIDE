---
name: check-drift
description: Check for drift between the main extension and the export AU template. Reports any files that should be in sync but aren't, and surfaces likely candidates for new sync points.
user_invocable: true
---

# Check Drift Between Main Extension and Export Template

The main extension (`ConjureDSPExtension/`) and the export AU template
(`ConjureDSPExportAUTemplate/ConjureDSPExportAUTemplateExtension/`) ship
some files that MUST stay in sync — drift between them has previously
caused exported AUs to break in ways that were hard to diagnose (most
recently: cdp-ui.js was 5 commits stale in the template, breaking
`<cdp-xy>` in every exported AU that used it).

The structural defense is symlinks: the template's copy of each
shared file is a symlink to the main extension's source. The
`CustomUIAssetParityTests` test target enforces hash equality. This
slash command runs both kinds of checks at once and surfaces:

1. **Hard drift** — any tracked sync point where the file content
   actually differs (means a symlink got replaced with a stale
   duplicate, OR a new sync point was added without a symlink).
2. **Symlink integrity** — any tracked sync point where the
   template's file should be a symlink but isn't.
3. **Suspect candidates** — any file basename that appears in both
   `ConjureDSPExtension` and the export template that isn't already a
   tracked sync point. These may need to be added to the sync list,
   OR they may be deliberately-different siblings (like the
   `Export*` "stripped down" variants — `ExportCustomUIWebView` etc.
   which are intentionally smaller versions of their main-extension
   counterparts).
4. **Test result** — the `CustomUIAssetParityTests` suite outcome.

Do NOT auto-fix. This command DETECTS drift; the user decides what to
do about each finding.

## Step 1: List the tracked sync points

These are the files that are currently maintained as symlinks
template → main:

```
ConjureDSPExportAUTemplate/.../Resources/cdp-ui.js
  → ConjureDSPExtension/Resources/cdp-ui.js

ConjureDSPExportAUTemplate/.../Resources/customui-bridge.js
  → ConjureDSPExtension/Resources/customui-bridge.js

ConjureDSPExportAUTemplate/.../UI/BundleAssetSchemeHandler.swift
  → ConjureDSPExtension/UI/BundleAssetSchemeHandler.swift
```

For each, verify both:
- `[ -L <template_path> ]` — the template path IS a symlink
- `shasum <main_path> <template_path>` — both resolve to identical content

If a symlink got replaced by a real file, both checks will surface it.

```bash
PAIRS=(
  "ConjureDSPExtension/Resources/cdp-ui.js|ConjureDSPExportAUTemplate/ConjureDSPExportAUTemplateExtension/Resources/cdp-ui.js"
  "ConjureDSPExtension/Resources/customui-bridge.js|ConjureDSPExportAUTemplate/ConjureDSPExportAUTemplateExtension/Resources/customui-bridge.js"
  "ConjureDSPExtension/UI/BundleAssetSchemeHandler.swift|ConjureDSPExportAUTemplate/ConjureDSPExportAUTemplateExtension/UI/BundleAssetSchemeHandler.swift"
)

drift_count=0
broken_links=0
for pair in "${PAIRS[@]}"; do
  main="${pair%|*}"
  template="${pair#*|}"

  # Symlink check
  if [ ! -L "$template" ]; then
    echo "BROKEN SYMLINK: $template is not a symlink (should point at $main)"
    broken_links=$((broken_links+1))
  fi

  # Content equality
  main_hash=$(shasum "$main" 2>/dev/null | awk '{print $1}')
  tpl_hash=$(shasum "$template" 2>/dev/null | awk '{print $1}')
  if [ "$main_hash" != "$tpl_hash" ]; then
    echo "DRIFT: $main"
    echo "       main:     $main_hash"
    echo "       template: $tpl_hash"
    drift_count=$((drift_count+1))
  fi
done

if [ $drift_count -eq 0 ] && [ $broken_links -eq 0 ]; then
  echo "Tracked sync points: all $((${#PAIRS[@]})) clean."
fi
```

## Step 2: Suspect candidates

Surface any filename that appears in both trees but isn't already
tracked. Useful for catching "someone added a new shared file but
forgot the symlink." Filter out the deliberately-stripped-down `Export*`
siblings (those have an `Export` prefix in the template and a different
name in the main extension; they're not drift candidates).

```bash
echo
echo "=== Files with same basename in both extension and template ==="
echo "(excluding tracked sync points and deliberate Export* siblings)"
echo

# All template Swift files + non-export-only resources
TPL_FILES=$(find ConjureDSPExportAUTemplate/ConjureDSPExportAUTemplateExtension -type f \
  \( -name "*.swift" -o -name "*.js" -o -name "*.css" -o -name "*.html" -o -name "*.json" \) \
  ! -name "preset.wasm" ! -name "runtime-config.json" 2>/dev/null)

TRACKED_BASENAMES="cdp-ui.js customui-bridge.js BundleAssetSchemeHandler.swift"

for tpl in $TPL_FILES; do
  base=$(basename "$tpl")

  # Skip already-tracked
  if echo " $TRACKED_BASENAMES " | grep -q " $base "; then
    continue
  fi

  # Skip deliberate Export-prefixed siblings (e.g. ExportCustomUIWebView.swift)
  if [[ "$base" == Export* ]]; then
    continue
  fi

  # Look for a same-named file in the main extension
  main=$(find ConjureDSPExtension -name "$base" -type f 2>/dev/null | head -1)
  if [ -n "$main" ] && [ "$main" != "$tpl" ]; then
    main_hash=$(shasum "$main" 2>/dev/null | awk '{print $1}')
    tpl_hash=$(shasum "$tpl" 2>/dev/null | awk '{print $1}')
    if [ "$main_hash" = "$tpl_hash" ]; then
      echo "SUSPECT (identical content, untracked): $base"
      echo "  main:     $main"
      echo "  template: $tpl"
    else
      echo "SUSPECT (different content, untracked): $base"
      echo "  main:     $main"
      echo "  template: $tpl"
    fi
  fi
done
```

For each suspect, the user has to decide:
- **Identical content, untracked** → likely needs to become a tracked
  sync point (add a symlink + extend `CustomUIAssetParityTests`)
- **Different content, untracked** → either a deliberate stripped-down
  sibling (and should be renamed with an `Export` prefix to make that
  clear), or actual drift that needs investigation

## Step 3: Run the parity tests

Always run these even if Step 1 came back clean — they're the
authoritative regression net and will catch anything the heuristic
checks missed.

```bash
xcodebuild -project ConjureDSP.xcodeproj -scheme ConjureDSP test \
  -only-testing:ConjureDSPLogicTests/CustomUIAssetParityTests 2>&1 | \
  tail -8
```

## Step 4: Summarize

Give the user a compact summary:
- Tracked sync points: clean / N drifted / N broken symlinks
- Suspect candidates: list them with the user's decision required
- Parity tests: pass / fail (with names of failing assertions)

If everything is clean, one line is fine ("No drift detected. 3 tracked
sync points clean, no new suspects, parity tests pass.").

If anything is drifted or missing, give the exact paths and let the
user decide. Do NOT auto-fix.
