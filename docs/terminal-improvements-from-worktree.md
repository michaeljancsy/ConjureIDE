# Terminal Integration: Improvements from the `hardcore-torvalds` Worktree

A parallel implementation of the Claude Code terminal integration was developed in the `claude/hardcore-torvalds` branch. That branch's implementation is **not** being merged (main's version is more battle-tested and production-ready), but several design decisions and patterns from it are strictly better and should be adopted into the main branch. This document describes each improvement with enough specificity to implement without referencing the worktree.

The worktree branch diverged from main at commit `fd5806e` (before the terminal feature existed on main). The main branch implementation landed via PR #89 (`claude/charming-grothendieck`).

---

## 1. Typed WebSocket Protocol

**Current main**: The WebSocket between the companion app (`ConjureDSPTerminal`) and the AU extension's xterm.js uses a mixed protocol — PTY output is sent as raw binary WebSocket frames, while resize messages are sent as JSON text frames (`{type: "resize", cols, rows}`). The receiver must inspect the WebSocket opcode to determine the format.

**Improvement**: Define a single typed message envelope for all WebSocket messages. The worktree used a Codable struct:

```swift
enum WSMessageType: String, Codable {
    case hello
    case ptyOutput = "pty_output"
    case ptyInput = "pty_input"
    case ptyResize = "pty_resize"
    case ptyExited = "pty_exited"
    case status
}

struct WSMessage: Codable {
    let type: WSMessageType
    var role: String?       // hello
    var data: String?       // pty_output / pty_input (base64)
    var cols: Int?           // pty_resize
    var rows: Int?           // pty_resize
    var exitCode: Int?       // pty_exited
    var state: String?       // status
}
```

Every message is JSON text with a `type` discriminator. PTY data is base64-encoded within the JSON. This adds ~33% overhead for binary data but provides:
- A single code path for parsing all messages (no opcode inspection)
- Easy extensibility (add new message types without protocol ambiguity)
- Easier debugging (all messages are human-readable JSON)
- The companion app can send structured status messages (e.g., `{type: "status", state: "connected"}`) that the AU can use to confirm the handshake succeeded, rather than assuming connection on WebSocket open

The `status` message type is particularly useful: the AU's `TerminalService` only transitions to `.connected` state when it receives `{type: "status", state: "connected"}` from the companion app, rather than assuming connection succeeded when the WebSocket opens. This avoids premature sends before the companion app is ready.

**Where to apply**: `ConjureDSPTerminal/WebSocketServer.swift` (sending), `ConjureDSPExtension/Resources/terminal/terminal-bridge.js` (receiving), and a new shared `WSMessage` type.

---

## 2. Reuse Existing Tool Definitions via `ChatTools.definitions`

**Current main**: Tool definitions are hardcoded in `MCPProtocol.swift` as 9 `ToolDefinition` structs with manually written names, descriptions, and input schemas. These duplicate the same definitions that already exist in `ChatTools.swift` (used by the AI chat sidebar before it was removed). If tools are added or modified, both places must be updated.

**Improvement**: `ChatTools.definitions` (a `static let` array of `[String: Any]` dictionaries in Anthropic API format) already contains all 9 tool definitions with complete input schemas. The only difference between Anthropic format and MCP format is the key name `input_schema` vs `inputSchema`. A thin adapter can convert at runtime:

```swift
enum MCPToolProvider {
    static func mcpToolDefinitions() -> [[String: Any]] {
        ChatTools.definitions.map { tool in
            var mcpTool: [String: Any] = [
                "name": tool["name"] as? String ?? "",
            ]
            if let desc = tool["description"] as? String {
                mcpTool["description"] = desc
            }
            if let inputSchema = tool["input_schema"] as? [String: Any] {
                mcpTool["inputSchema"] = inputSchema
            }
            return mcpTool
        }
    }
}
```

This eliminates the duplicated definitions in `MCPProtocol.swift` (the 9 `ToolDefinition` structs and the `static let tools` array, ~100 lines). `ChatTools.swift` becomes the single source of truth for tool schemas.

**Caveat**: `ChatTools.swift` is currently kept in `ConjureDSPExtension/AI/`. If it's ever removed during cleanup of the old AI chat code, the definitions would need to live somewhere. The key point is: don't maintain two copies.

**Where to apply**: Replace `MCPProtocol.tools` usage in `MCPServer.handleToolsList()` with `MCPToolProvider.mcpToolDefinitions()`. Delete the `ToolDefinition`, `InputSchema`, `PropertySchema` structs and `static let tools` from `MCPProtocol.swift`.

---

## 3. Reuse Existing `ToolExecutor` for MCP Tool Execution

**Current main**: Tool execution goes through a new `MCPToolProvider` protocol (defined in `Shared/MCPToolProvider.swift`) that the AU conforms to via `ConjureDSPExtensionAudioUnit+MCP.swift`. This extension adds ~276 lines implementing `executeMCPTool(_:inputJSON:completion:)` and `mcpStateSummary()` directly on the AU class.

**Improvement**: The existing `ToolExecutor` class (`ConjureDSPExtension/AI/ToolExecutor.swift`) already implements all 9 tool executions with the same logic. It holds weak references to the AU and PresetManager and has an `execute(name:input:)` async method. The MCPServer can use it directly:

```swift
// In MCPServer's tools/call handler:
let result = await self.toolExecutor.execute(name: toolName, input: arguments)
let mcpResult: [String: Any] = [
    "content": [["type": "text", "text": result.content]],
    "isError": result.isError,
]
```

This avoids duplicating tool implementations across two classes and keeps tool logic in one place. The `ToolExecutor` also has an `onScriptChanged` callback that updates the Monaco editor when `compile_and_run` succeeds — this is already wired up and would be lost if tool execution is reimplemented separately on the AU.

**Where to apply**: `MCPServer` should hold a `ToolExecutor` reference (passed during init) instead of a `MCPToolProvider` protocol reference. Remove `ConjureDSPExtensionAudioUnit+MCP.swift` and `Shared/MCPToolProvider.swift`. Keep `ToolExecutor.swift`.

**Note**: The `mcpStateSummary()` function from main's approach (which provides Claude Code with current AU state in the MCP `initialize` response) is a good idea and could be added as a method on `ToolExecutor` or passed as a closure to `MCPServer`.

---

## 4. Separate TerminalView (Rendering) from Network Logic

**Current main**: The WebSocket connection to the companion app lives **inside the JavaScript bridge** (`terminal-bridge.js`). The JS code has `connect(port)`, `doConnect()`, `disconnect()`, `scheduleReconnect()`, and reconnection logic with exponential backoff. The `TerminalView` coordinator reads the WebSocket port from the App Group container and tells the JS bridge to connect.

**Improvement**: Separate terminal rendering from network communication into two distinct layers:

1. **`TerminalView`** — Pure xterm.js rendering. Communicates with Swift via `WKScriptMessageHandler` callbacks (`onInput`, `onResize`, `onReady`) and an `OutputWriter` that forwards data to the terminal. No network logic.

2. **`TerminalService`** — `@MainActor ObservableObject` that manages the `URLSessionWebSocketTask` connection to the companion app. Publishes `connectionState` for UI. Calls `outputWriter.write(data)` when PTY output arrives. Receives input from `TerminalView` via `sendInput(data)`.

Benefits:
- `TerminalView` can be tested or reused independently of the WebSocket transport
- Connection state management lives in Swift (observable, testable) rather than JavaScript
- The JS bridge is simpler — just xterm.js initialization, theme switching, and data writing
- `TerminalService` can use `URLSessionWebSocketTask` (Foundation's WebSocket client) rather than implementing WebSocket in JS, getting automatic TLS, proxy, and authentication support if ever needed

**Where to apply**: Refactor `terminal-bridge.js` to remove `connect()`, `doConnect()`, `disconnect()`, `scheduleReconnect()`, and the `ws` WebSocket object. Add Swift-side `TerminalService` class. Wire them together in `ConjureDSPExtensionMainView`.

---

## 5. Proper xterm.js `dispose()` Cleanup in `dismantleNSView`

**Current main**: `TerminalView` does not call `terminal.dispose()` when the WKWebView is torn down. The WKWebView deallocation implicitly tears down the JS context, but xterm.js may have ResizeObservers, DOM mutation observers, and other resources that should be explicitly cleaned up.

**Improvement**: Add a `dispose()` method to the JS bridge and call it during `dismantleNSView`:

In `terminal-bridge.js`:
```javascript
dispose() {
    if (this._resizeObserver) {
        this._resizeObserver.disconnect();
        this._resizeObserver = null;
    }
    if (this.terminal) {
        this.terminal.dispose();
        this.terminal = null;
    }
    this.fitAddon = null;
    this.webLinksAddon = null;
}
```

In `TerminalView.swift`:
```swift
static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
    // Remove message handlers first to stop receiving new callbacks
    let controller = webView.configuration.userContentController
    controller.removeScriptMessageHandler(forName: "terminalReady")
    controller.removeScriptMessageHandler(forName: "terminalInput")
    controller.removeScriptMessageHandler(forName: "terminalResize")
    // Best-effort cleanup of xterm.js resources
    if coordinator.isTerminalReady {
        webView.evaluateJavaScript("bridge.dispose()") { _, _ in }
    }
    coordinator.webView = nil
}
```

The ordering matters: remove message handlers **before** calling dispose, so that any callbacks fired during disposal don't reach a partially-torn-down coordinator.

**Where to apply**: `ConjureDSPExtension/Resources/terminal/terminal-bridge.js` and `ConjureDSPExtension/UI/TerminalView.swift`.

---

## 6. Pending Output Buffer for Pre-Ready Data

**Current main**: If the companion app sends PTY output before xterm.js has initialized (the WKWebView hasn't loaded yet, or `bridge.init()` hasn't completed), that data is lost.

**Improvement**: Queue output data in the Swift coordinator until the terminal signals ready:

```swift
// In Coordinator:
private var pendingOutput: [Data] = []

func writeToTerminal(_ data: Data) {
    guard isTerminalReady, let webView else {
        pendingOutput.append(data)
        return
    }
    let base64 = data.base64EncodedString()
    webView.evaluateJavaScript("bridge.write('\(base64)')") { _, _ in }
}

// Called when "terminalReady" message handler fires:
private func flushPendingOutput() {
    guard isTerminalReady, let webView else { return }
    for data in pendingOutput {
        let base64 = data.base64EncodedString()
        webView.evaluateJavaScript("bridge.write('\(base64)')") { _, _ in }
    }
    pendingOutput.removeAll()
}
```

This ensures no output is lost during the WKWebView initialization window, which can take several hundred milliseconds.

**Where to apply**: `ConjureDSPExtension/UI/TerminalView.swift`, in the `Coordinator` class.

---

## 7. WKWebView Content Process Crash Recovery

**Current main**: If the WKWebView content process terminates (memory pressure, WebKit crash), the terminal goes blank with no recovery.

**Improvement**: Implement `webViewWebContentProcessDidTerminate` and retry initialization:

```swift
// In Coordinator:
private var initRetryCount = 0
private static let maxInitRetries = 2

func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    log.error("WKWebView content process terminated")
    retryInitIfNeeded(webView)
}

private func retryInitIfNeeded(_ webView: WKWebView) {
    isTerminalReady = false
    guard initRetryCount < Self.maxInitRetries else {
        log.error("Terminal init failed after \(Self.maxInitRetries) retries")
        return
    }
    initRetryCount += 1
    webView.reload()
}
```

Also handle `bridge.init()` failures (JS exceptions) in `webView(_:didFinish:)` by catching errors from `evaluateJavaScript` and retrying.

**Where to apply**: `ConjureDSPExtension/UI/TerminalView.swift`, in the `Coordinator` class (which conforms to `WKNavigationDelegate`).

---

## 8. Thread-Safe WebSocket Server with Queue Serialization

**Current main** (`ConjureDSPTerminal/WebSocketServer.swift`): The `broadcast()` and `broadcastText()` methods access the `clients` dictionary directly. While main dispatches NWListener and NWConnection callbacks to `.main`, the `broadcast()` method could theoretically be called from a non-main context (e.g., the PTY read callback on a global queue). The `stop()` method also accesses `clients` and `listener` without explicit queue protection.

**Improvement**: Use a dedicated serial queue for all WebSocket server state, and dispatch public methods onto it:

```swift
private let queue = DispatchQueue(label: "com.conjuredsp.terminal.ws")

func sendToAU(_ message: WSMessage) {
    queue.async {
        self.auConnection?.send(message)
    }
}

func stop() {
    queue.sync {
        listener?.cancel()
        listener = nil
        auConnection?.close()
        auConnection = nil
    }
    // Port file cleanup can happen outside the queue
    try? FileManager.default.removeItem(atPath: portFilePath)
}
```

In main's case, since it uses `.main` for everything, the practical risk is low. But if `onOutput` from PTYManager is ever called on a background queue (which it currently is — the `DispatchSource.makeReadSource` fires on `.global(qos: .userInteractive)`), `broadcast()` is called from that background queue while `clients` is mutated on `.main`. The `DispatchQueue.main.async` in `readFromPTY()` saves this today, but the protection is indirect and fragile.

**Where to apply**: `ConjureDSPTerminal/WebSocketServer.swift`. Either (a) add explicit queue serialization, or (b) add a comment/assertion documenting that all access must happen on the main queue.

---

## 9. Port Range Fallback for WebSocket Server

**Current main**: The companion app's WebSocket server binds to a fixed port (19836). If another process is using that port, the listener fails and the terminal doesn't work.

**Improvement**: Try a range of ports:

```swift
func start(preferredPort: UInt16 = 19836, portRange: Int = 10) throws {
    for offset in 0..<portRange {
        let tryPort = preferredPort + UInt16(offset)
        do {
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: tryPort)!)
            // ... start listener, write port file ...
            return
        } catch {
            continue
        }
    }
    throw ServerError.noAvailablePort
}
```

The AU discovers the actual port via the App Group port file, so the specific port number doesn't matter as long as it's written correctly.

**Where to apply**: `ConjureDSPTerminal/WebSocketServer.swift` and the `ConjureDSPTerminalApp.swift` startup code. The App Group port file already handles discovery, so no changes needed on the AU side.

---

## 10. Binary-Safe Base64 Encoding in JS Bridge

**Current main**: The `terminal-bridge.js` uses `btoa(data)` for encoding terminal input before sending over WebSocket. `btoa()` throws on strings containing characters with code points > 255, which can occur with certain terminal escape sequences or binary data from mouse events.

**Improvement**: Use a byte-aware encoding function:

```javascript
_toBase64(data) {
    var bytes = new Uint8Array(data.length);
    for (var i = 0; i < data.length; i++) {
        bytes[i] = data.charCodeAt(i) & 0xFF;
    }
    var binary = '';
    for (var i = 0; i < bytes.length; i++) {
        binary += String.fromCharCode(bytes[i]);
    }
    return btoa(binary);
}
```

And for writing PTY output to the terminal, decode base64 into a `Uint8Array` for proper byte-level handling:

```javascript
write(base64) {
    if (!this.terminal) return;
    var decoded = atob(base64);
    var bytes = new Uint8Array(decoded.length);
    for (var i = 0; i < decoded.length; i++) {
        bytes[i] = decoded.charCodeAt(i);
    }
    this.terminal.write(bytes);
}
```

This is only relevant if the WebSocket protocol is changed to use base64-encoded JSON (improvement #1). If raw binary WebSocket frames are kept, this doesn't apply.

**Where to apply**: `ConjureDSPExtension/Resources/terminal/terminal-bridge.js`.

---

## Summary

| # | Improvement | Impact | Effort |
|---|---|---|---|
| 1 | Typed WebSocket protocol | Maintainability, debuggability | Medium |
| 2 | Reuse `ChatTools.definitions` | Eliminate ~100 lines of duplication | Low |
| 3 | Reuse `ToolExecutor` for MCP | Eliminate ~276 lines of duplication | Medium |
| 4 | Separate TerminalView from network | Architecture, testability | Medium |
| 5 | xterm.js `dispose()` cleanup | Resource leak prevention | Low |
| 6 | Pending output buffer | Prevents lost output during init | Low |
| 7 | WKWebView crash recovery | Resilience | Low |
| 8 | Thread-safe WebSocket server | Correctness | Low |
| 9 | Port range fallback | Robustness | Low |
| 10 | Binary-safe base64 in JS | Correctness for edge cases | Low |
