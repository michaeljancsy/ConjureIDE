//
//  TerminalBridgeFocusTests.swift
//  ConjureDSPLogicTests
//
//  Regression tests for the terminal keyboard-input pathway.
//
//  The AU ViewBridge only forwards keyboard input to the extension through
//  NSTextInputClient sessions, which WebKit establishes for contentEditable
//  elements but NOT for xterm.js's hidden textarea (see commit 588f7d6).
//  terminal-bridge.js therefore routes focus to a contentEditable
//  `#input-proxy` div. If focus lands on xterm's textarea instead, typing
//  is silently dropped until the user clicks inside the terminal.
//
//  These tests load terminal-bridge.js into a JSContext with stub DOM /
//  WebSocket / xterm objects and assert that both the socket-open handler
//  and the `terminalBridge.focus()` bridge method focus `#input-proxy`,
//  never the xterm textarea.
//

import Foundation
import JavaScriptCore
import Testing

@Suite("Terminal bridge focus (regression for silent keyboard drop)")
struct TerminalBridgeFocusTests {

    @Test("socket.onopen focuses #input-proxy, not xterm's textarea")
    func socketOpenFocusesInputProxy() throws {
        let harness = try BridgeHarness()

        harness.evaluate("terminalBridge.connect(12345);")
        harness.evaluate("_harness.sockets[_harness.sockets.length - 1]._triggerOpen();")

        #expect(harness.focusCount(elementId: "input-proxy") >= 1,
                "socket.onopen must focus #input-proxy so the AU ViewBridge forwards keystrokes")
        #expect(harness.xtermFocusCount == 0,
                "socket.onopen must NOT focus xterm's textarea — AU ViewBridge won't forward keyDown to it")
    }

    @Test("terminalBridge.focus() (called by Swift `connected` handler) targets #input-proxy")
    func bridgeFocusMethodTargetsInputProxy() throws {
        let harness = try BridgeHarness()

        harness.evaluate("terminalBridge.focus();")

        #expect(harness.focusCount(elementId: "input-proxy") >= 1,
                "terminalBridge.focus() must route to #input-proxy")
        #expect(harness.xtermFocusCount == 0,
                "terminalBridge.focus() must NOT focus xterm's textarea")
    }

    @Test("Clicking the terminal container still focuses #input-proxy")
    func mousedownOnContainerFocusesInputProxy() throws {
        let harness = try BridgeHarness()

        // Simulate a mousedown on the terminal container — the existing fallback
        // that made the bug recoverable for users who clicked inside the terminal.
        harness.evaluate("_harness.elements['terminal-container']._fire('mousedown');")

        #expect(harness.focusCount(elementId: "input-proxy") >= 1)
    }
}

/// Regression tests for the `firstInput` Swift-event attribution rule.
///
/// `firstInput` exists so `TerminalKeyboardInputUITests` can assert that real
/// user keystrokes reach the WebSocket. The signal must NOT fire from the
/// `terminal.onData` callback xterm.js uses for its own auto-replies to shell
/// terminal-capability queries (DA1 / DSR / etc.) — otherwise the UI test
/// races shell startup and the marker may flip before the test types,
/// hiding a genuine focus-routing regression.
@Suite("Terminal bridge firstInput attribution")
struct TerminalBridgeFirstInputTests {

    @Test("xterm.onData (e.g. auto-response to shell capability query) does NOT fire firstInput")
    func xtermAutoResponseDoesNotFireFirstInput() throws {
        let harness = try BridgeHarness()
        harness.openSocket()

        // Shell sends ESC[c (DA1); xterm.js synthesizes a reply through its
        // onData callback. The reply still needs to reach the PTY, but the
        // bridge must NOT treat it as the first user keystroke.
        harness.evaluate("_harness.terminals[0]._onData('\\x1b[?6c');")

        #expect(harness.messageCount(event: "firstInput") == 0,
                "xterm.onData reentering the bridge must not be treated as user input")
    }

    @Test("inputProxy 'input' event fires firstInput")
    func inputProxyInputFiresFirstInput() throws {
        let harness = try BridgeHarness()
        harness.openSocket()

        harness.evaluate("""
        _harness.elements['input-proxy'].textContent = 'a';
        _harness.elements['input-proxy']._fire('input');
        """)

        #expect(harness.messageCount(event: "firstInput") == 1)
    }

    @Test("inputProxy keydown for a key that sends data fires firstInput")
    func inputProxyKeydownFiresFirstInput() throws {
        let harness = try BridgeHarness()
        harness.openSocket()

        harness.evaluate("""
        _harness.elements['input-proxy']._fire('keydown', {
            key: 'Enter', preventDefault: function(){}
        });
        """)

        #expect(harness.messageCount(event: "firstInput") == 1)
    }

    @Test("Cmd+C (clipboard, no PTY send) does NOT fire firstInput")
    func cmdCDoesNotFireFirstInput() throws {
        let harness = try BridgeHarness()
        harness.openSocket()

        harness.evaluate("""
        _harness.elements['input-proxy']._fire('keydown', {
            metaKey: true, key: 'c', preventDefault: function(){}
        });
        """)

        #expect(harness.messageCount(event: "firstInput") == 0,
                "Cmd+C handles clipboard locally; it must not poison the firstInput marker")
    }

    @Test("firstInput fires only once per socket connection")
    func firstInputFiresOncePerConnection() throws {
        let harness = try BridgeHarness()
        harness.openSocket()

        for _ in 0..<3 {
            harness.evaluate("""
            _harness.elements['input-proxy'].textContent = 'a';
            _harness.elements['input-proxy']._fire('input');
            """)
        }

        #expect(harness.messageCount(event: "firstInput") == 1)
    }
}

// MARK: - Harness

/// Loads terminal-bridge.js into a JSContext with stubbed DOM / xterm / WebSocket
/// objects. All `focus()` calls are counted per-element (keyed by element id, or
/// `"__xterm"` for the xterm.js Terminal instance).
private final class BridgeHarness {
    let context: JSContext

    init() throws {
        guard let ctx = JSContext() else {
            throw BridgeError.contextCreationFailed
        }
        self.context = ctx

        ctx.exceptionHandler = { _, exception in
            Issue.record("JS exception: \(exception?.toString() ?? "nil")")
        }

        ctx.evaluateScript(Self.stubsSource)
        if let ex = ctx.exception {
            throw BridgeError.stubEvaluationFailed(ex.toString() ?? "unknown")
        }

        let bridgeJS = try Self.loadTerminalBridgeSource()
        ctx.evaluateScript(bridgeJS)
        if let ex = ctx.exception {
            throw BridgeError.bridgeEvaluationFailed(ex.toString() ?? "unknown")
        }
    }

    func evaluate(_ script: String) {
        context.evaluateScript(script)
        if let ex = context.exception {
            Issue.record("JS evaluate error: \(ex.toString() ?? "nil") — script: \(script)")
            context.exception = nil
        }
    }

    func focusCount(elementId: String) -> Int {
        let value = context.evaluateScript("_harness.focusCount('\(elementId)')")
        return Int(value?.toInt32() ?? 0)
    }

    var xtermFocusCount: Int {
        let value = context.evaluateScript("_harness.xtermFocusCount()")
        return Int(value?.toInt32() ?? 0)
    }

    /// Convenience: drive the bridge through `connect` + `socket.onopen` so the
    /// WebSocket-readyState gate in `sendUserInput` is satisfied. Tests that
    /// fire keystrokes after this can assume the socket is OPEN.
    func openSocket() {
        evaluate("terminalBridge.connect(12345);")
        evaluate("_harness.sockets[_harness.sockets.length - 1]._triggerOpen();")
    }

    /// Number of `postToSwift` calls recorded with the given `event` name.
    func messageCount(event: String) -> Int {
        let value = context.evaluateScript("_harness.countMessages('\(event)')")
        return Int(value?.toInt32() ?? 0)
    }

    // MARK: - Source loading

    private static func loadTerminalBridgeSource() throws -> String {
        // `#filePath` points at this test file; terminal-bridge.js lives in
        // ../ConjureDSPExtension/Resources/terminal/terminal-bridge.js.
        let thisFile = URL(fileURLWithPath: #filePath)
        let url = thisFile
            .deletingLastPathComponent()     // ConjureDSPLogicTests/
            .deletingLastPathComponent()     // repo root
            .appendingPathComponent("ConjureDSPExtension/Resources/terminal/terminal-bridge.js")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Stubs
    //
    // Minimal DOM / xterm / WebSocket shims that let terminal-bridge.js run in
    // a plain JSContext. Focus calls are recorded in `_harness.focusCounts`
    // keyed by element id (or `"__xterm"` for the xterm Terminal instance).

    private static let stubsSource: String = """
    (function() {
        'use strict';

        var focusCounts = Object.create(null);
        var elements = Object.create(null);
        var sockets = [];
        var terminals = [];
        var messages = [];

        function makeElement(id) {
            var handlers = Object.create(null);
            var el = {
                id: id,
                textContent: '',
                innerText: '',
                style: {},
                classList: {
                    add: function() {},
                    remove: function() {},
                    contains: function() { return false; }
                },
                options: {},
                focus: function() {
                    focusCounts[id] = (focusCounts[id] || 0) + 1;
                },
                addEventListener: function(name, fn) { handlers[name] = fn; },
                removeEventListener: function(name) { delete handlers[name]; },
                _fire: function(name, ev) { if (handlers[name]) handlers[name](ev || {}); }
            };
            return el;
        }

        function getOrMake(id) {
            if (!elements[id]) elements[id] = makeElement(id);
            return elements[id];
        }

        globalThis.window = globalThis;

        globalThis.document = {
            readyState: 'complete',
            getElementById: function(id) { return getOrMake(id); },
            addEventListener: function() {}
        };

        globalThis.webkit = {
            messageHandlers: {
                terminalBridge: {
                    postMessage: function(msg) { messages.push(msg); }
                }
            }
        };

        // xterm.js Terminal stub — `focus()` increments a distinct counter
        // so the tests can distinguish xterm-textarea focus from DOM-element
        // focus on #input-proxy.
        globalThis.Terminal = function(opts) {
            var inst = {
                options: opts || {},
                loadAddon: function() {},
                open: function() {},
                onData: function(fn) { this._onData = fn; },
                onResize: function(fn) { this._onResize = fn; },
                focus: function() {
                    focusCounts['__xterm'] = (focusCounts['__xterm'] || 0) + 1;
                },
                write: function() {},
                clear: function() {},
                selectAll: function() {},
                getSelection: function() { return ''; },
                cols: 80,
                rows: 24
            };
            terminals.push(inst);
            return inst;
        };

        globalThis.FitAddon = {
            FitAddon: function() { return { fit: function() {} }; }
        };

        // WebLinksAddon intentionally left undefined — bridge checks for it.

        globalThis.ResizeObserver = function() {
            return { observe: function() {}, unobserve: function() {}, disconnect: function() {} };
        };

        globalThis.setTimeout = function() { return 0; };
        globalThis.clearTimeout = function() {};
        globalThis.setInterval = function() { return 0; };
        globalThis.clearInterval = function() {};

        function FakeWebSocket(url) {
            this.url = url;
            this.readyState = 0; // CONNECTING
            this.binaryType = '';
            this.onopen = null;
            this.onmessage = null;
            this.onclose = null;
            this.onerror = null;
            var self = this;
            this.send = function() {};
            this.close = function() { self.readyState = 3; };
            this._triggerOpen = function() {
                self.readyState = 1;
                if (self.onopen) self.onopen({});
            };
            sockets.push(this);
        }
        FakeWebSocket.CONNECTING = 0;
        FakeWebSocket.OPEN = 1;
        FakeWebSocket.CLOSING = 2;
        FakeWebSocket.CLOSED = 3;
        globalThis.WebSocket = FakeWebSocket;

        globalThis._harness = {
            focusCount: function(id) { return focusCounts[id] || 0; },
            xtermFocusCount: function() { return focusCounts['__xterm'] || 0; },
            sockets: sockets,
            elements: elements,
            terminals: terminals,
            messages: messages,
            countMessages: function(event) {
                var n = 0;
                for (var i = 0; i < messages.length; i++) {
                    if (messages[i] && messages[i].event === event) n++;
                }
                return n;
            }
        };
    })();
    """

    enum BridgeError: Error {
        case contextCreationFailed
        case stubEvaluationFailed(String)
        case bridgeEvaluationFailed(String)
    }
}
