# BearBone Preset Repo Format

This document specifies the structure of a GitHub repository that BearBone can connect to for browsing, syncing, and sharing DSP preset scripts.

Both the community preset repo and user-owned personal repos follow this format.

## Required Structure

```
bearbone.json                        ← required marker file
python/                              ← Python presets
  my-filter.py                       ← preset script
  my-filter_metadata.json            ← sidecar metadata (optional)
  delay.py
  delay_metadata.json
rust/                                ← Rust presets
  compressor.rs
  compressor_metadata.json
```

### `bearbone.json` (required)

A marker file at the repository root that identifies the repo as a BearBone preset repo. BearBone checks for this file when connecting to an existing repo and rejects repos without it.

```json
{
  "version": 1,
  "type": "presets"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `version` | int | Format version. Currently `1`. |
| `type` | string | Must be `"presets"`. |

### `python/` and `rust/` directories

Preset scripts are organized by language:

- **`python/`** — Python scripts (`.py` files)
- **`rust/`** — Rust scripts (`.rs` files)

Both directories are optional — a repo may contain only Python presets, only Rust presets, or both. BearBone lists the contents of each directory to discover presets.

Files that don't end in `.py` (in `python/`) or `.rs` (in `rust/`) are ignored, except for `_metadata.json` sidecars and `.gitkeep` placeholders.

### `<name>_metadata.json` (optional)

A sidecar JSON file providing metadata for a preset script. The filename must match the script's stem with `_metadata.json` appended:

| Script | Metadata file |
|--------|---------------|
| `python/slicer.py` | `python/slicer_metadata.json` |
| `rust/compressor.rs` | `rust/compressor_metadata.json` |

```json
{
  "name": "Reverse Slicer",
  "category": "Delay",
  "author": "BearBone",
  "description": "Rhythmic slicer that reverses audio in timed chunks."
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | yes | Display name shown in the preset browser. |
| `category` | string | no | Grouping category (e.g. "Utility", "Distortion", "Filter", "Dynamics", "Modulation", "Delay", "Generator"). Defaults to "Other" if omitted. |
| `author` | string | no | Author name shown in the community browser. |
| `description` | string | no | Short description of what the preset does. |

If no metadata file exists for a script, BearBone uses the filename stem as the display name with no category, author, or description.

## Behavior

### Community repos

BearBone ships with a default community repo (`michaeljancsy/bearbone-presets`). The "Browse Community..." menu item fetches this repo's `python/` and `rust/` directories, reads sidecar metadata for each script, and displays them grouped by category with search, preview, and one-click install.

Community repos are read-only — BearBone never pushes to them.

### Personal repos

Users can connect an existing repo or have BearBone create one via Settings → GitHub. When BearBone creates a repo, it initializes it with `bearbone.json` and empty `python/` and `rust/` directories.

When connected:
- **Saves** auto-push the script and a sidecar `_metadata.json` to the appropriate subdirectory.
- **Deletes** remove both the script and its metadata file from the repo.
- **On launch**, BearBone runs a bidirectional sync: pulling new remote presets and pushing new local ones, with per-file conflict resolution for divergent changes.

### Validation

When connecting to an existing repo, BearBone fetches `bearbone.json` from the repo root and verifies:
1. The file exists (404 → rejected)
2. It parses as valid JSON
3. The `type` field equals `"presets"`

Repos that fail validation are rejected with an error message.

## Example: Minimal Repo

```
bearbone.json
python/
  gain.py
  gain_metadata.json
```

`bearbone.json`:
```json
{"version": 1, "type": "presets"}
```

`python/gain_metadata.json`:
```json
{
  "name": "Simple Gain",
  "category": "Utility",
  "description": "Applies a fixed gain to the signal."
}
```

`python/gain.py`:
```python
import numpy as np

# Parameters:
GAIN = 0

def process(inputs, outputs, frame_count, sample_rate, params):
    gain = params[GAIN] * 2.0
    for ch in range(len(inputs)):
        np.multiply(inputs[ch][:frame_count], gain, out=outputs[ch][:frame_count])
```
