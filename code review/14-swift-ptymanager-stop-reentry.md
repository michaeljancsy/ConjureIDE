An AI has found the following issue. Please review and assess whether action is needed.

# Swift: PTYManager.stop() can call waitpid() twice on the same PID

## Context
`ConjureDSPTerminal/PTYManager.swift` manages the lifecycle of the Claude Code CLI subprocess. `stop()` shuts the process down, and a wait loop calls `waitpid` to reap it.

## Issue
The reviewer flagged (around lines 349, 353) that `stop()` has no re-entry guard. If the user (or some restart logic) calls `stop()` twice in quick succession, `waitpid` may be called twice on the same PID. After the first successful reap, the PID can be reused by the kernel for a different process — the second `waitpid` either returns ECHILD or, worse, races and reaps an unrelated PID owned by the same UID.

## Location
- `ConjureDSPTerminal/PTYManager.swift` — `stop()` and the wait loop, ~lines 349 and 353

## Why it matters
- PID reuse on macOS is fast and within-process — a second `waitpid` racing PID reuse can silently affect another process that the OS just spawned (rare but possible in a development environment with many short-lived processes).
- More commonly: ECHILD makes `stop()` log "child already exited" noise that obscures real shutdown bugs.
- The existing TerminalServer health-check + restart logic could plausibly call `stop()` while a previous `stop()` is still in flight.

## What to verify
- Read `PTYManager.swift` end to end. Find the `pid` storage and all callers of `waitpid`.
- Check the call sites in `TerminalServer` / `ConjureDSPTerminalApp` that invoke `stop()`. Is there any shared state ensuring single-flight?
- Look at `start()` — does it nil-check `pid` before launching, or could a double-start race?

## Suggested approach
- Add a state machine: `idle → starting → running → stopping → stopped`. `stop()` is a no-op unless state is `running` or `starting`.
- After the first successful `waitpid`, set the stored `pid` to `-1` (or nil) and exit cleanly. All subsequent `stop()` calls become no-ops.
- Wrap the state transition in an actor or a serial DispatchQueue so concurrent callers serialize.
