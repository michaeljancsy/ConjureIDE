An AI has found the following issue. Please review and assess whether action is needed.

# Swift: PTYManager dispatch sources replaced without verifying prior state

## Context
`ConjureDSPTerminal/PTYManager.swift` uses `DispatchSource.makeReadSource(...)` and similar to watch the PTY master fd for output and for the child process's exit. These dispatch sources are stored on the manager and reused across start/stop cycles.

## Issue
The reviewer flagged (around lines 210, 227–236) that `start()` creates new dispatch sources and stores them, but if `start()` is called while previous sources still exist, the old sources are cancelled without first verifying they're not actively running. This can race: a fired event handler on the old source may execute concurrently with the new source's setup, observing inconsistent state (e.g., new fd in `pty_master` but handler still holding stale assumptions).

## Location
- `ConjureDSPTerminal/PTYManager.swift` — `start()` dispatch source creation, ~lines 210 and 227–236

## Why it matters
- Mostly latent: in normal use, `start()` isn't re-entered. But on terminal restart (TerminalServer detecting the AU MCP port changed and restarting), it can race.
- Symptoms when it goes wrong: stale PTY output appears in the new terminal session, or input keystrokes get written to a closed fd (EBADF, dropped silently).
- These bugs are essentially unreproducible in dev but show up as "the terminal stopped working until I quit and reopened the host."

## What to verify
- Read `PTYManager.swift` end to end. Find all dispatch source creation/cancellation sites.
- Check whether `cancel()` synchronously waits for handler completion (it does not — it's asynchronous; you need a cancel handler).
- Look at the TerminalServer restart path to see whether `stop()` is awaited before `start()` runs again.

## Suggested approach
- Use a cancel handler on each dispatch source: `source.setCancelHandler { ... }` that signals a `DispatchSemaphore` or sets a flag. `stop()` should wait for the handler to fire before returning.
- Alternatively: tear down all sources in `stop()`, set them to nil, and refuse to `start()` until they are nil. Use a state machine (see the related `stop()` re-entry issue) to enforce ordering.
- Ensure event handlers themselves capture `[weak self]` and bail out if the manager has been reset.
