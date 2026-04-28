//
//  CustomUIBridgeOnChangeTests.swift
//  ConjureDSPLogicTests
//
//  Pins the bridge contract that `parameters.set(i, v)` fires
//  onChange/onAnyChange handlers synchronously, plus the dedupe-on-
//  equal guard that breaks recursion when a handler re-sets the same
//  value it was called with.
//
//  Concrete bug this exists to prevent: the VCA Compressor preset
//  hand-rolled SVG knobs against `ConjureDSP.ui.control(i)` and wired
//  visual updates through `ctrl.onChange(refresh)`. The original
//  bridge fired onChange ONLY from `_paramUpdate` callbacks (external
//  changes — DAW automation, MIDI, MCP, preset load). Self-writes via
//  `set()` were silent. Result: the user dragged a knob, the parameter
//  changed under the hood (DSP got the new value, audio responded),
//  but the knob's visual indicator and value text never updated. The
//  preset looked dead while actually working.
//
//  Fix: fire onChange/onAnyChange synchronously inside `set()`. Safe
//  because Swift's `param.setValue(_:originator:)` excludes our own
//  observer token from the AU callback (pinned by
//  ParameterStateEchoTests.swift), so self-writes never echo back via
//  `_paramUpdate`. The synchronous fire from `set()` is the ONLY
//  notification path for self-writes; the async `_paramUpdate` is the
//  ONLY one for external changes. No double-fire.
//
//  These tests exercise the bridge directly via JSContext — no host
//  app, no webview — so they run in the fast logic-test target.
//

import Foundation
import JavaScriptCore
import Testing

struct CustomUIBridgeOnChangeTests {
    /// Load `customui-bridge.js` into a JSContext with a minimal WebKit
    /// stub. The bridge's IIFE installs `window.ConjureDSP`, then we
    /// drive `_init` to populate metadata + values.
    private static func makeContext() throws -> JSContext {
        let ctx = JSContext()!
        // The bridge expects `window`, `window.webkit.messageHandlers`,
        // and `window.addEventListener`. Stub the absolute minimum so
        // the IIFE installs cleanly. `messageHandlers` stays empty so
        // `postTo()` calls are no-ops (no real Swift to talk to).
        ctx.evaluateScript("""
            var window = this;
            window.webkit = { messageHandlers: {} };
            window.addEventListener = function () {};
            window.dispatchEvent = function () { return true; };
            window.CustomEvent = function () {};
        """)
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent()
        let bridgeURL = repoRoot
            .appendingPathComponent("ConjureDSPExtension/Resources/customui-bridge.js")
        let source = try String(contentsOf: bridgeURL, encoding: .utf8)
        ctx.evaluateScript(source)
        // Initialize with two params so tests can exercise cross-
        // parameter writes alongside same-parameter recursion.
        ctx.evaluateScript("""
            ConjureDSP._init({
                metadata: [
                    { name: 'A', min: 0, max: 100, default: 0 },
                    { name: 'B', min: 0, max: 100, default: 0 }
                ],
                values: [0, 0],
                theme: 'light'
            });
        """)
        if let exception = ctx.exception {
            throw NSError(
                domain: "CustomUIBridgeOnChangeTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "JS bootstrap threw: \(exception)"]
            )
        }
        return ctx
    }

    // MARK: - Self-write fires handlers

    @Test func setFiresOnChangeSynchronously() throws {
        let ctx = try Self.makeContext()
        let result = ctx.evaluateScript("""
            var fires = [];
            ConjureDSP.parameters.onChange(0, function(v) { fires.push(v); });
            ConjureDSP.parameters.set(0, 42);
            JSON.stringify(fires);
        """)!.toString()!
        #expect(result == "[42]",
                "set(0, 42) must fire the registered onChange handler with v=42; got \(result)")
    }

    @Test func setFiresOnAnyChangeSynchronously() throws {
        let ctx = try Self.makeContext()
        let result = ctx.evaluateScript("""
            var fires = [];
            ConjureDSP.parameters.onAnyChange(function(i, v) { fires.push([i, v]); });
            ConjureDSP.parameters.set(0, 42);
            ConjureDSP.parameters.set(1, 7);
            JSON.stringify(fires);
        """)!.toString()!
        #expect(result == "[[0,42],[1,7]]",
                "onAnyChange must fire on every set; got \(result)")
    }

    /// Multiple handlers on the same parameter all fire on a self-write.
    @Test func setFiresAllRegisteredOnChangeHandlers() throws {
        let ctx = try Self.makeContext()
        let result = ctx.evaluateScript("""
            var a = 0, b = 0;
            ConjureDSP.parameters.onChange(0, function(v) { a = v; });
            ConjureDSP.parameters.onChange(0, function(v) { b = v * 2; });
            ConjureDSP.parameters.set(0, 5);
            JSON.stringify({ a: a, b: b });
        """)!.toString()!
        #expect(result == "{\"a\":5,\"b\":10}")
    }

    // MARK: - Dedupe + recursion termination

    @Test func setDedupesEqualValues() throws {
        let ctx = try Self.makeContext()
        let result = ctx.evaluateScript("""
            var fires = 0;
            ConjureDSP.parameters.onChange(0, function() { fires++; });
            ConjureDSP.parameters.set(0, 5);
            ConjureDSP.parameters.set(0, 5);
            ConjureDSP.parameters.set(0, 5);
            fires;
        """)!.toInt32()
        #expect(result == 1,
                "Three set() calls with the same value should fire onChange exactly once (got \(result))")
    }

    /// A handler that re-sets the same value MUST terminate. Without
    /// the dedupe-on-equal guard inside `set()`, this would infinite-
    /// loop and overflow the JS stack.
    @Test func recursiveSameValueHandlerTerminates() throws {
        let ctx = try Self.makeContext()
        let result = ctx.evaluateScript("""
            var fires = 0;
            ConjureDSP.parameters.onChange(0, function(v) {
                fires++;
                // Hard cap as a safety net — but the test expects the
                // dedupe guard to break the loop after one fire, so
                // this branch shouldn't be reached.
                if (fires < 1000) ConjureDSP.parameters.set(0, v);
            });
            ConjureDSP.parameters.set(0, 5);
            fires;
        """)!.toInt32()
        #expect(result == 1,
                "Same-value recursion must terminate via dedupe (got \(result) fires; >1 means the dedupe guard regressed)")
    }

    /// Quantize-style pattern: handler maps a fractional input to its
    /// rounded integer, re-setting if the rounded value differs. Must
    /// converge in two iterations — the second fire passes the round-
    /// trip and the dedupe stops further hops.
    @Test func quantizingHandlerConverges() throws {
        let ctx = try Self.makeContext()
        let result = ctx.evaluateScript("""
            var fires = 0;
            ConjureDSP.parameters.onChange(0, function(v) {
                fires++;
                if (fires > 10) return;
                var r = Math.round(v);
                if (r !== v) ConjureDSP.parameters.set(0, r);
            });
            ConjureDSP.parameters.set(0, 1.7);
            JSON.stringify({ fires: fires, value: ConjureDSP.parameters.get(0) });
        """)!.toString()!
        #expect(result == "{\"fires\":2,\"value\":2}",
                "Quantize handler should converge in 2 fires (got \(result))")
    }

    /// Cross-parameter writes from inside a handler are intentionally
    /// allowed — a UI may legitimately want changing param A to drive
    /// param B (a "linked stereo" toggle, a dependent gain trim, etc.).
    /// Each parameter has its own dedupe; no protection against the
    /// author writing a literal A↔B ping-pong.
    @Test func crossParameterWriteFromHandlerPasses() throws {
        let ctx = try Self.makeContext()
        let result = ctx.evaluateScript("""
            var bFires = [];
            ConjureDSP.parameters.onChange(0, function(v) {
                ConjureDSP.parameters.set(1, v + 10);
            });
            ConjureDSP.parameters.onChange(1, function(v) { bFires.push(v); });
            ConjureDSP.parameters.set(0, 5);
            JSON.stringify({ aValue: ConjureDSP.parameters.get(0),
                             bValue: ConjureDSP.parameters.get(1),
                             bFires: bFires });
        """)!.toString()!
        #expect(result == "{\"aValue\":5,\"bValue\":15,\"bFires\":[15]}")
    }

    // MARK: - External path still works

    /// Regression check: the `_paramUpdate` callback (the path Swift
    /// uses to push DAW automation, MIDI, MCP writes, preset load
    /// changes back to JS) MUST still fire onChange. This is the path
    /// every preset has always relied on for external automation.
    @Test func paramUpdateStillFiresOnChange() throws {
        let ctx = try Self.makeContext()
        let result = ctx.evaluateScript("""
            var fires = [];
            ConjureDSP.parameters.onChange(0, function(v) { fires.push(v); });
            ConjureDSP._paramUpdate(0, 99);
            JSON.stringify(fires);
        """)!.toString()!
        #expect(result == "[99]")
    }

    /// `_paramUpdate` is NOT subject to the dedupe-on-equal guard —
    /// the dedupe lives only in `set()`. External pushes always fire,
    /// even if the new value equals what's already cached. This
    /// matches DAW automation contracts where a tick must be observable
    /// even when the value happens to repeat.
    @Test func paramUpdateDoesNotDedupe() throws {
        let ctx = try Self.makeContext()
        let result = ctx.evaluateScript("""
            var fires = 0;
            ConjureDSP.parameters.onChange(0, function() { fires++; });
            ConjureDSP._paramUpdate(0, 7);
            ConjureDSP._paramUpdate(0, 7);
            ConjureDSP._paramUpdate(0, 7);
            fires;
        """)!.toInt32()
        #expect(result == 3,
                "External _paramUpdate should fire on every push, even at the same value (got \(result))")
    }

    // MARK: - Edge cases preserved from the original behavior

    @Test func nonFiniteValueIsSkipped() throws {
        let ctx = try Self.makeContext()
        let result = ctx.evaluateScript("""
            var fires = 0;
            ConjureDSP.parameters.onChange(0, function() { fires++; });
            ConjureDSP.parameters.set(0, NaN);
            ConjureDSP.parameters.set(0, Infinity);
            ConjureDSP.parameters.set(0, -Infinity);
            fires;
        """)!.toInt32()
        #expect(result == 0,
                "Non-finite values must be silently dropped (got \(result) fires)")
    }

    /// A handler that throws must not block subsequent handlers or
    /// crash the bridge. The bridge wraps each invocation in
    /// `safeInvoke`, which forwards the error to `postTo('log', ...)`
    /// rather than letting it propagate.
    @Test func throwingHandlerDoesNotBlockOthers() throws {
        let ctx = try Self.makeContext()
        let result = ctx.evaluateScript("""
            var laterFired = false;
            ConjureDSP.parameters.onChange(0, function() { throw new Error('intentional'); });
            ConjureDSP.parameters.onChange(0, function() { laterFired = true; });
            ConjureDSP.parameters.set(0, 42);
            laterFired;
        """)!.toBool()
        #expect(result == true,
                "A throwing onChange handler must not prevent later handlers from running")
    }
}
