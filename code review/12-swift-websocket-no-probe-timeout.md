An AI has found the following issue. Please review and assess whether action is needed.

# Swift: WebSocketServer accepts un-upgraded TCP probes that never time out

## Context
`ConjureDSPTerminal/WebSocketServer.swift` listens on a local port and accepts incoming connections. Real clients send an HTTP Upgrade request and become WebSocket clients; anything else (port scanners, accidental TCP probes, browsers hitting the wrong URL) connects but never upgrades.

## Issue
The reviewer flagged (around lines 185–195) that there's no timeout for clients that connect but never complete the WebSocket handshake. They sit in the `clients` dictionary indefinitely, holding an NWConnection.

## Location
- `ConjureDSPTerminal/WebSocketServer.swift` — connection-accept path, ~lines 185–195

## Why it matters
- Slow resource leak: each un-upgraded connection consumes a file descriptor, an NWConnection, and a dictionary entry until the process dies.
- DoS surface: anything (or anyone) on localhost can hold connections open. macOS's per-process file descriptor limit is generous but not infinite, and the terminal companion app stays running across many sessions.
- Diagnosability: the connection count grows monotonically with no obvious cause when something on the machine probes localhost ports (Spotlight, security scanners, etc.).

## What to verify
- Read `WebSocketServer.swift` and confirm there's no per-connection idle timer.
- Check whether the bound port is restricted to loopback (127.0.0.1) — if it accepts connections from anywhere, severity is higher.
- Look for any global limit on concurrent client count.

## Suggested approach
- Schedule a 5–10 second timer per accepted connection. If the WebSocket handshake hasn't completed by then, cancel the connection and remove the entry.
- Alternatively, reject the connection at TCP-accept time if the source isn't 127.0.0.1.
- Add a hard cap on concurrent un-upgraded connections (e.g., 16) — beyond the cap, refuse new accepts.
