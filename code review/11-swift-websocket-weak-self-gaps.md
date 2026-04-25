An AI has found the following issue. Please review and assess whether action is needed.

# Swift: WebSocketServer error-cleanup paths missing weak self guards

## Context
`ConjureDSPTerminal/WebSocketServer.swift` is a small Network.framework-based WebSocket server that relays PTY output from the Claude Code CLI process to xterm.js running in the AU extension's WebView. Each connected client is tracked in a dictionary keyed by an ID; when a send fails, the server is supposed to remove the client.

## Issue
The reviewer flagged that several `connection.send(content:..., completion: .contentProcessed { ... })` completion handlers around lines 91–140 do not consistently use `[weak self]` and a `guard let self else { return }`. In some paths (specifically ~lines 114–119) when the completion fires after the server is being torn down, `self` is nil and the cleanup branch silently doesn't run — leaving the client ID in the dictionary with a dangling NWConnection reference.

## Location
- `ConjureDSPTerminal/WebSocketServer.swift` — lines ~91–140, the `.contentProcessed { ... }` handlers across the broadcast / unicast / control-frame send paths

## Why it matters
- Memory leak: per-client state accumulates across connect/disconnect cycles when the server is being shut down or restarted.
- Inconsistency: some handlers do the cleanup, others don't — a future maintainer can't tell which is the intended pattern.
- Potential retain cycle: if any handler captures `self` strongly and the connection holds the handler, the server can outlive its owner.

## What to verify
- Read `ConjureDSPTerminal/WebSocketServer.swift` end to end.
- For each `.contentProcessed { ... }` and any other closure stored on a connection, confirm the capture list and what happens when self is nil mid-close.
- Trace the lifecycle: who owns `WebSocketServer`, when is it deinited, what happens to in-flight sends?

## Suggested approach
- Standardize on `[weak self] error in guard let self else { return }` for every send completion.
- Add a single `removeClient(id:)` that's idempotent and safe to call even after the server is torn down (e.g., it nil-checks the dictionary).
- Consider replacing the manual dictionary with an actor or a dedicated serial queue so client lifecycle isn't subject to the audio/main thread interleaving.
