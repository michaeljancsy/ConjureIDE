# Run Button Label: UX Analysis

## Problem
Is "Run" the right label for the button that hot-reloads the Python script into the DSP kernel? Does it need to be a separate action from Save?

## Current UX

### Toolbar Actions (in `TestPluginExtension/UI/PresetToolbar.swift`)
The toolbar currently has these distinct actions:

| Button | Label | What It Does | When Enabled |
|--------|-------|-------------|--------------|
| **Run** | "Run" | Hot-reload script into kernel, benchmark, show timing | Always |
| **Save** | "Save" | Write to disk + hot-reload + benchmark | Only when editing a user preset AND script is modified |
| **Save As** | "Save As..." | Prompt for name, write new file + hot-reload | Always |
| **New** | "New" | Reset to default passthrough script | Always |
| **Delete** | trash icon | Delete current user preset | Only on user presets |

### The Key Distinction: Run vs Save
- **Run** = load the current editor text into the Rust kernel (hot-reload). Does NOT persist to disk. The script is only in memory until the DAW project is saved (via `fullState`).
- **Save** = write to `~/Library/Application Support/TestPlugin/Presets/<name>.py` AND hot-reload.

### Keyboard Shortcut (`TestPluginExtension/UI/TestPluginExtensionMainView.swift`)
- **Cmd+S**: If current is a user preset and modified → Save. Otherwise → Save As popover.
- No keyboard shortcut for Run.

### User Mental Models

**"Code editor" mental model** (VS Code, Xcode):
- "Run" means "execute" — familiar from IDEs. Makes sense.
- Save and Run are always separate (Cmd+S to save, Cmd+R or play button to run).
- Users expect Run to execute whatever is in the editor, even if unsaved.

**"DAW plugin" mental model** (Ableton, Logic):
- Presets are selected, not "run." You save them or discard changes.
- There is no "run" concept — parameters take effect immediately.
- The closest analog is "Apply" or "Load."

**"Scripting environment" mental model** (Jupyter, REPL):
- "Run" is perfect — it means "execute this cell/script."
- Run doesn't imply save. You can run without saving.

## Analysis

### Arguments for Keeping "Run" Separate from Save
1. **Safe experimentation**: Users can try script changes without overwriting their saved preset. This is the primary value.
2. **Familiar to programmers**: The target audience writes Python DSP scripts — they understand Run vs Save.
3. **DAW state persistence**: Even without Save, the script survives DAW project save/load via `fullState`. So "Run" isn't volatile — it persists through the DAW's own save mechanism.
4. **Existing Cmd+S**: Save already has a keyboard shortcut. Adding a Run shortcut (Cmd+R or Cmd+Enter) would complete the picture.

### Arguments for Merging Run into Save
1. **Simpler UI**: Fewer buttons, less cognitive load.
2. **Prevents confusion**: Users might forget to Save after Running, then lose changes when switching presets.
3. **DAW users' expectation**: In DAW-land, changes are either committed or discarded.

### Arguments for Renaming "Run"
- **"Reload"**: Emphasizes that it hot-reloads the kernel. But sounds like "reload from disk," which is the opposite of what it does.
- **"Apply"**: DAW-friendly. But feels passive for executing code.
- **"Execute"**: Too formal/long for a small button.
- **"Load"**: Ambiguous — load from where?
- **"Run"**: Actually the best option. Clear, concise, universally understood in a coding context.

## Recommendation

**Keep "Run" as a separate action with its current name.** The reasons:

1. **"Run" is the right word.** The target user is writing Python code. "Run" is the universal term for executing code. No alternative is better.

2. **Separate from Save is correct.** The ability to experiment without committing to disk is a core workflow benefit. Merging would force users to choose a preset name before they can hear their changes.

3. **Add a keyboard shortcut for Run.** This is the missing piece. Options:
   - **Cmd+R** — Standard "Run" shortcut (Xcode, most IDEs). Conflicts with nothing in the current app.
   - **Cmd+Enter** — Common in Jupyter notebooks and REPLs. Feels natural for "execute this script."
   - Recommend **Cmd+R** as primary, since the audience is macOS developers familiar with Xcode conventions.

4. **Consider auto-running on Save.** Currently Save already hot-reloads (calls `reloadScript`). This is correct — saving should always apply the changes. No change needed here.

### Optional Enhancement: Run-on-Save Indication
When the user hits Save and it also runs, the status bar already shows the benchmark timing. This implicitly communicates that the script was also loaded. No additional UX change needed.

## Implementation (if any changes are made)

### Add Cmd+R Shortcut for Run
In `TestPluginExtensionMainView.swift`, add alongside the existing Cmd+S handler:

```swift
.onKeyPress(KeyEquivalent("r"), modifiers: .command) {
    onRun(scriptSource)
    return .handled
}
```

### Files to Modify
- `TestPluginExtension/UI/TestPluginExtensionMainView.swift` — Add Cmd+R keyboard shortcut

### Testing
- Verify Cmd+R triggers script reload and shows benchmark timing
- Verify Cmd+S still saves (user preset) or opens Save As (factory/no preset)
- UI test: Run button still accessible and functional

## Estimated Complexity
Minimal — the only concrete change is adding a Cmd+R keyboard shortcut. The label "Run" should stay as-is.
