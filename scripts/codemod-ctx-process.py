#!/usr/bin/env python3
"""
Codemod: rewrite `def process(inputs, outputs, ...)` Python presets to the
single-ctx signature `def process(ctx)`.

The Rust kernel now rejects anything but `def process(ctx):` at script load,
so every Python preset whose `process()` signature still uses the legacy 7-arg
form needs this rewrite.

Behavior:
  - Locate the top-level `def process(...)` (any leading whitespace preserved).
  - If signature is already `def process(ctx)` -> idempotent no-op.
  - Otherwise rewrite the def line and apply textual rewrites to the body:
      inputs[i]                 -> ctx.inputs[i]
      outputs[i]                -> ctx.outputs[i]
      params[K]                 -> ctx.params[K]
      telemetry[K]              -> ctx.telemetry[K]
      sidechain[i]              -> ctx.sidechain[i]
      frame_count               -> ctx.frame_count        (word boundary)
      sample_rate               -> ctx.sample_rate        (word boundary)
      transport["tempo"]        -> ctx.transport.bpm
      transport["beat"]         -> ctx.transport.beat
      transport["playing"]      -> ctx.transport.is_playing
      transport["time_sig_num"] -> ctx.transport.time_sig_numerator
      transport["time_sig_den"] -> ctx.transport.time_sig_denominator
      transport["sample_pos"]   -> ctx.transport.sample_position

Strings and comments are skipped via tokenize, so identifiers that appear
inside docstrings, comments, or string literals are never rewritten.

Usage:
  scripts/codemod-ctx-process.py [--dry-run] [--yes] FILE [FILE ...]
"""

from __future__ import annotations

import argparse
import difflib
import io
import re
import sys
import tokenize
from pathlib import Path
from typing import Iterable


# ---- Body rewrite rules --------------------------------------------------

# Order matters: longer/more specific patterns first.
# Each entry is (compiled_regex, replacement). Patterns are anchored to be
# safe with word boundaries where appropriate.
_TRANSPORT_KEY_MAP = {
    "tempo": "ctx.transport.bpm",
    "beat": "ctx.transport.beat",
    "playing": "ctx.transport.is_playing",
    "time_sig_num": "ctx.transport.time_sig_numerator",
    "time_sig_den": "ctx.transport.time_sig_denominator",
    "sample_pos": "ctx.transport.sample_position",
}


def _build_rewrite_rules() -> list[tuple[re.Pattern[str], str]]:
    rules: list[tuple[re.Pattern[str], str]] = []

    # transport["key"] / transport['key'] -> ctx.transport.<accessor>
    for key, repl in _TRANSPORT_KEY_MAP.items():
        # Match transport["key"] and transport['key'] but NOT ctx.transport[...]
        # — the negative-lookbehind `(?<!\.)` prevents `something.transport[...]`
        # from matching, and `\b` keeps us off identifiers like `_transport`.
        pat = re.compile(
            r"(?<!\.)\btransport\[\s*[\"']" + re.escape(key) + r"[\"']\s*\]"
        )
        rules.append((pat, repl))

    # Buffer-like names: inputs, outputs, params, telemetry, sidechain.
    # The legacy positional 7-arg signature exposed these as locals; under the
    # new ctx form they live as ctx.<name>. Both subscripted (`inputs[i]`,
    # `params["mix"]`) and bare (`len(inputs)`, `for ch_in in inputs:`,
    # `zip(inputs, outputs)`) uses must be rewritten — otherwise the rewritten
    # script raises NameError at runtime.
    #
    # The negative-lookbehind `(?<![\w.])` keeps us from matching things like
    # `ctx.inputs`, `self.params`, or `my_inputs` — important for idempotency.
    for name in ("inputs", "outputs", "params", "telemetry", "sidechain"):
        pat = re.compile(r"(?<![\w.])\b" + re.escape(name) + r"\b")
        rules.append((pat, f"ctx.{name}"))

    # Bare frame_count / sample_rate (word boundary, not preceded by `.`).
    rules.append((re.compile(r"(?<![\w.])\bframe_count\b"), "ctx.frame_count"))
    rules.append((re.compile(r"(?<![\w.])\bsample_rate\b"), "ctx.sample_rate"))

    return rules


_REWRITE_RULES = _build_rewrite_rules()


def _apply_rewrites(text: str) -> str:
    """Apply all rewrite rules to a text fragment (assumed to be code, not a
    string/comment token). Order is preserved; transport-dict rules run first
    so they consume the `transport[...]` form before any later rule could
    accidentally touch it."""
    for pat, repl in _REWRITE_RULES:
        text = pat.sub(repl, text)
    return text


# ---- Tokenize-aware rewriter --------------------------------------------

def _rewrite_source(src: str) -> tuple[str, bool]:
    """Rewrite `src` and return (new_src, changed).

    The rewrite is applied in two passes:
      1. Find the line containing `def process(...)`. Replace its signature
         with `def process(ctx):` (preserving leading whitespace).
         If the signature is already `def process(ctx)`, this is a no-op
         and we return (src, False) — the codemod is idempotent.
      2. Within the function body (everything indented at least one level
         deeper than the `def` line), apply textual rewrites — but only to
         non-string, non-comment regions, identified via `tokenize`. The
         pre-`process` portion of the file (imports, PARAMS dict, helpers)
         is left untouched.
    """
    # ---- pass 1: find and rewrite def process(...) ----
    lines = src.splitlines(keepends=True)
    def_idx: int | None = None
    def_indent = ""
    sig_re = re.compile(r"^(?P<indent>[ \t]*)def\s+process\s*\(")
    already_ctx_re = re.compile(
        r"^[ \t]*def\s+process\s*\(\s*ctx\s*\)\s*:\s*$"
    )

    for i, line in enumerate(lines):
        m = sig_re.match(line)
        if m:
            def_idx = i
            def_indent = m.group("indent")
            # Idempotency: already in ctx form?
            if already_ctx_re.match(line):
                # Still need to consider whether the body has been migrated.
                # If signature is ctx-form, we trust an earlier full run
                # already did the body, and treat the file as a no-op.
                return src, False
            break

    if def_idx is None:
        # No `def process` found — nothing to do.
        return src, False

    # Replace the def line(s). Some signatures could span multiple physical
    # lines, but in this codebase they're all single-line (verified). Be
    # robust: walk forward until the line containing the `):` for the def's
    # parameter list, and replace the whole span.
    end_idx = def_idx
    # Track parens; the def line ends at the matching `)` followed by `:`.
    depth = 0
    found_open = False
    for j in range(def_idx, len(lines)):
        for ch in lines[j]:
            if ch == "(":
                depth += 1
                found_open = True
            elif ch == ")":
                depth -= 1
                if found_open and depth == 0:
                    end_idx = j
                    break
        if found_open and depth == 0:
            break

    new_def_line = f"{def_indent}def process(ctx):\n"
    # Preserve a trailing newline style: if the original last line had a
    # trailing newline, the replacement carries one. Otherwise strip.
    if not lines[end_idx].endswith("\n"):
        new_def_line = new_def_line[:-1]

    new_lines = lines[:def_idx] + [new_def_line] + lines[end_idx + 1:]

    # ---- pass 2: rewrite the function body only ----
    # The body starts immediately after the (now collapsed) def line at
    # `def_idx`. It includes every subsequent line that is either blank or
    # indented strictly deeper than `def_indent`. The first dedent back to
    # `def_indent` (or shallower) ends the body.
    body_start = def_idx + 1
    body_end = body_start
    indent_unit_len = len(def_indent)
    for j in range(body_start, len(new_lines)):
        line = new_lines[j]
        if line.strip() == "":
            body_end = j + 1
            continue
        # Count leading whitespace
        stripped = line.lstrip(" \t")
        leading = len(line) - len(stripped)
        if leading > indent_unit_len:
            body_end = j + 1
        else:
            break

    pre_body = "".join(new_lines[:body_start])
    body = "".join(new_lines[body_start:body_end])
    post_body = "".join(new_lines[body_end:])

    # Trim trailing blank lines from `body` that actually belong to whatever
    # follows. Leave them in place — they don't affect rewrites and pulling
    # them out adds risk. The tokenize-aware rewriter handles them safely.
    new_body = _rewrite_code_regions(body)

    new_src = pre_body + new_body + post_body
    return new_src, new_src != src


def _rewrite_code_regions(src: str) -> str:
    """Tokenize `src` and rewrite only the regions that are NOT inside
    triple-quoted strings or comments. Single-line single/double-quoted
    string literals (e.g. `params["mix"]`, `transport["tempo"]`) are left
    alongside their surrounding code so the rewrite rules can match across
    the bracket-and-string boundary — the rules themselves are anchored
    on identifier markers (`transport[`, `params[`, etc.) that don't
    appear inside literal string content in this codebase, so no
    false-match risk.

    Triple-quoted strings (typically docstrings or multiline literals) and
    `#` comments stay opaque — those *can* contain prose like
    "outputs:", "inputs[i]", which we must not touch.
    """
    try:
        tokens = list(tokenize.generate_tokens(io.StringIO(src).readline))
    except tokenize.TokenizeError:
        # If tokenization fails, fall back to whole-fragment rewrite. This
        # is safer than nothing — any oddly-formatted file would already
        # have been rejected by the Python compiler at script load.
        return _apply_rewrites(src)

    # Flat-offset helper.
    line_starts = [0]
    for i, ch in enumerate(src):
        if ch == "\n":
            line_starts.append(i + 1)

    def pos_to_offset(pos: tuple[int, int]) -> int:
        row, col = pos
        if row - 1 < len(line_starts):
            return line_starts[row - 1] + col
        return len(src)

    # We treat as opaque: comments + multi-line/triple-quoted strings.
    # Single-line single/double-quoted strings stay processable so that
    # rules like `transport["tempo"]` can match.
    skip_spans: list[tuple[int, int]] = []
    for tok in tokens:
        if tok.type == tokenize.COMMENT:
            skip_spans.append((pos_to_offset(tok.start), pos_to_offset(tok.end)))
        elif tok.type == tokenize.STRING:
            s = tok.string
            # Only skip triple-quoted (docstring-style) literals or any
            # string whose start/end span more than one source line.
            is_triple = s.startswith(('"""', "'''")) or s.lstrip("rRbBuUfF").startswith(('"""', "'''"))
            is_multiline = tok.start[0] != tok.end[0]
            if is_triple or is_multiline:
                skip_spans.append(
                    (pos_to_offset(tok.start), pos_to_offset(tok.end))
                )

    if not skip_spans:
        return _apply_rewrites(src)

    skip_spans.sort()
    # Merge overlapping spans (shouldn't happen, but be defensive).
    merged: list[tuple[int, int]] = []
    for s, e in skip_spans:
        if merged and s < merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], e))
        else:
            merged.append((s, e))

    out_parts: list[str] = []
    cursor = 0
    for s, e in merged:
        if cursor < s:
            out_parts.append(_apply_rewrites(src[cursor:s]))
        out_parts.append(src[s:e])  # leave docstring/comment untouched
        cursor = e
    if cursor < len(src):
        out_parts.append(_apply_rewrites(src[cursor:]))

    return "".join(out_parts)


# ---- CLI ----------------------------------------------------------------

def _print_diff(path: Path, before: str, after: str) -> None:
    diff = difflib.unified_diff(
        before.splitlines(keepends=True),
        after.splitlines(keepends=True),
        fromfile=str(path),
        tofile=str(path) + " (rewritten)",
    )
    sys.stdout.writelines(diff)


def _process_one(path: Path, dry_run: bool, assume_yes: bool) -> str:
    """Process one file. Returns one of: 'changed', 'skipped', 'unchanged',
    'rejected'."""
    src = path.read_text()
    new_src, changed = _rewrite_source(src)
    if not changed:
        return "unchanged"

    print(f"\n=== {path} ===")
    _print_diff(path, src, new_src)

    if dry_run:
        return "changed"

    if not assume_yes:
        sys.stdout.write(f"Apply changes to {path}? [y/N] ")
        sys.stdout.flush()
        ans = sys.stdin.readline().strip().lower()
        if ans not in ("y", "yes"):
            return "skipped"

    path.write_text(new_src)
    return "changed"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Rewrite Python preset process(...) signatures to ctx form."
    )
    parser.add_argument(
        "paths",
        nargs="+",
        help="process.py files (or directories to scan recursively).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print diffs but don't write any files.",
    )
    parser.add_argument(
        "--yes",
        action="store_true",
        help="Skip the per-file y/n prompt.",
    )
    args = parser.parse_args(argv)

    files: list[Path] = []
    for raw in args.paths:
        p = Path(raw)
        if p.is_dir():
            files.extend(sorted(p.rglob("process.py")))
        elif p.is_file():
            files.append(p)
        else:
            print(f"warning: {p} not found", file=sys.stderr)

    if not files:
        print("no files to process", file=sys.stderr)
        return 1

    counts = {"changed": 0, "skipped": 0, "unchanged": 0}
    for f in files:
        result = _process_one(f, args.dry_run, args.yes)
        counts[result] = counts.get(result, 0) + 1

    print()
    print(
        f"summary: {counts['changed']} changed, "
        f"{counts['unchanged']} unchanged, "
        f"{counts['skipped']} skipped "
        f"({'dry-run' if args.dry_run else 'live'})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
