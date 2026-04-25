An AI has found the following issue. Please review and assess whether action is needed.

# Swift: PTYManager's strdup calls aren't null-checked

## Context
`ConjureDSPTerminal/PTYManager.swift` uses `forkpty` + `execve` to launch the Claude Code CLI inside a PTY. To build the `argv` and `envp` arrays for `execve`, it calls `strdup` on each Swift string and stores the resulting C pointers.

## Issue
The reviewer flagged (around lines 168–171 and 242–245) that the code calls `strdup()` without checking for NULL returns. `strdup` allocates and can fail if the system is out of memory. If any call returns NULL, downstream code dereferences it — in the parent during cleanup, or in the forked child during `execve` (where crash recovery options are zero, since stdio may already be redirected).

## Location
- `ConjureDSPTerminal/PTYManager.swift` — argv/envp construction sites at ~lines 168–171 and 242–245

## Why it matters
OOM is rare on macOS but possible (especially under sandboxed memory pressure). More importantly, the codebase's general posture seems to be "trust system calls" — but `strdup` is one of the few calls that returns NULL on failure rather than throwing. A NULL deref in the forked child is a silent crash with no parent-visible error.

This is a low-frequency, low-impact issue (the user sees "terminal didn't start" and tries again), but it's the kind of thing a human reviewer would always flag.

## What to verify
- Read `PTYManager.swift` and find all `strdup` calls.
- Look for any other unchecked C allocation calls (`malloc`, `calloc`, `posix_memalign`).
- Check whether the surrounding `forkpty` / `execve` error paths actually surface anything to the UI, or just log.

## Suggested approach
- Wrap `strdup` in a Swift helper: `func cstrdup(_ s: String) throws -> UnsafeMutablePointer<CChar>` that throws on NULL.
- In the child process post-fork, NULL just before `execve` means the only safe action is `_exit(127)` (don't run any cleanup that might allocate further).
- Consider using `withCString` and copying into a pre-allocated arena instead, eliminating per-string allocation failure surface.
