//
//  CustomUIBridgeStateTests.swift
//  ConjureDSPLogicTests
//
//  Pins the bridge contract for `ConjureDSP.state.*`: synchronous
//  onChange/onAnyChange dispatch on `set`, MAX_STATE_BYTES rejection,
//  external `_stateUpdate` push path (DAW load / MCP write / preset
//  switch), reset / resetAll posting to Swift, and the once-per-key
//  undeclared-key warning.
//
//  Same JSContext + stubbed messageHandlers pattern as
//  CustomUIBridgeOnChangeTests / CustomUIBridgeTransportTests — no
//  WKWebView, no host app, runs in the fast logic-test target.
//

import Foundation
import JavaScriptCore
import Testing

struct CustomUIBridgeStateTests {

    /// Loads the bridge into a JSContext and stubs every message
    /// handler the bridge posts to — so `state.set` / `state.reset` /
    /// `state.resetAll` etc. all record into `window.__posts` and
    /// tests can assert on them without bringing up Swift.
    private static func makeContext(
        declaredStateKeys: [String] = [],
        initialState: [String: Any] = [:],
        maxStateBytes: Int = 65_536
    ) throws -> JSContext {
        let ctx = JSContext()!
        ctx.evaluateScript("""
            var window = this;
            window.__posts = [];
            function makeHandler(name) {
                return { postMessage: function (payload) {
                    window.__posts.push({ name: name, payload: payload });
                }};
            }
            window.webkit = {
                messageHandlers: {
                    paramSet: makeHandler('paramSet'),
                    log: makeHandler('log'),
                    ready: makeHandler('ready'),
                    subscribeAudioFrames: makeHandler('subscribeAudioFrames'),
                    unsubscribeAudioFrames: makeHandler('unsubscribeAudioFrames'),
                    subscribeTransport: makeHandler('subscribeTransport'),
                    unsubscribeTransport: makeHandler('unsubscribeTransport'),
                    stateSet: makeHandler('stateSet'),
                    stateReset: makeHandler('stateReset'),
                    stateResetAll: makeHandler('stateResetAll'),
                }
            };
            window.addEventListener = function () {};
            window.dispatchEvent = function () { return true; };
            window.CustomEvent = function () {};
            window.requestAnimationFrame = function () { return 0; };
            window.cancelAnimationFrame = function () {};
        """)
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent()
        let bridgeURL = repoRoot
            .appendingPathComponent("ConjureDSPExtension/Resources/customui-bridge.js")
        let source = try String(contentsOf: bridgeURL, encoding: .utf8)
        ctx.evaluateScript(source)

        // Build the _init payload in JS so we can pass arbitrary state
        // shapes without serializing through ObjC bridging quirks.
        let declaredKeysJSON = (try? JSONSerialization.data(
            withJSONObject: declaredStateKeys, options: []
        )).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let stateJSON = (try? JSONSerialization.data(
            withJSONObject: initialState, options: []
        )).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        ctx.evaluateScript("""
            ConjureDSP._init({
                metadata: [{ name: 'A', min: 0, max: 1, default: 0 }],
                values: [0],
                theme: 'light',
                state: \(stateJSON),
                declaredStateKeys: \(declaredKeysJSON),
                maxStateBytes: \(maxStateBytes),
            });
        """)

        if let exception = ctx.exception {
            throw NSError(
                domain: "CustomUIBridgeStateTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "JS bootstrap threw: \(exception)"]
            )
        }
        return ctx
    }

    // MARK: - Get / set round-trip

    @Test func setReturnsTrueAndGetReturnsValue() throws {
        let ctx = try Self.makeContext(declaredStateKeys: ["foo"])
        let result = ctx.evaluateScript("""
            var ok = ConjureDSP.state.set('foo', 'bar');
            JSON.stringify({ ok: ok, val: ConjureDSP.state.get('foo') });
        """)!.toString()!
        #expect(result == "{\"ok\":true,\"val\":\"bar\"}",
                "set('foo','bar') must succeed and get must return 'bar'; got \(result)")
    }

    @Test func setWithUndefinedValueIsRetrievable() throws {
        let ctx = try Self.makeContext(declaredStateKeys: ["k"])
        let result = ctx.evaluateScript("""
            ConjureDSP.state.set('k', { count: 7, items: ['a','b'] });
            var v = ConjureDSP.state.get('k');
            JSON.stringify(v);
        """)!.toString()!
        #expect(result == "{\"count\":7,\"items\":[\"a\",\"b\"]}",
                "object values must round-trip through state get/set; got \(result)")
    }

    // MARK: - onChange / onAnyChange synchronous dispatch

    @Test func onChangeFiresSynchronouslyOnSet() throws {
        let ctx = try Self.makeContext(declaredStateKeys: ["k"])
        let result = ctx.evaluateScript("""
            var fires = [];
            ConjureDSP.state.onChange('k', function(v) { fires.push(v); });
            ConjureDSP.state.set('k', 1);
            ConjureDSP.state.set('k', 2);
            JSON.stringify(fires);
        """)!.toString()!
        #expect(result == "[1,2]",
                "onChange must fire on every set, including consecutive distinct values; got \(result)")
    }

    @Test func multipleOnChangeHandlersAllFire() throws {
        let ctx = try Self.makeContext(declaredStateKeys: ["k"])
        let result = ctx.evaluateScript("""
            var a = null, b = null;
            ConjureDSP.state.onChange('k', function(v) { a = v; });
            ConjureDSP.state.onChange('k', function(v) { b = '!' + v; });
            ConjureDSP.state.set('k', 'x');
            JSON.stringify({ a: a, b: b });
        """)!.toString()!
        #expect(result == "{\"a\":\"x\",\"b\":\"!x\"}")
    }

    @Test func onAnyChangeFiresWithKeyAndValue() throws {
        let ctx = try Self.makeContext(declaredStateKeys: ["a", "b"])
        let result = ctx.evaluateScript("""
            var fires = [];
            ConjureDSP.state.onAnyChange(function(k, v) { fires.push([k, v]); });
            ConjureDSP.state.set('a', 1);
            ConjureDSP.state.set('b', 2);
            JSON.stringify(fires);
        """)!.toString()!
        #expect(result == "[[\"a\",1],[\"b\",2]]",
                "onAnyChange must fire with (key, value) on every set; got \(result)")
    }

    // MARK: - MAX_STATE_BYTES rejection

    @Test func setReturnsFalseWhenSerializedExceedsMaxStateBytes() throws {
        // Tiny cap so a 200-char value comfortably blows past it.
        let ctx = try Self.makeContext(
            declaredStateKeys: ["big"],
            maxStateBytes: 64
        )
        let result = ctx.evaluateScript("""
            var huge = '';
            for (var i = 0; i < 200; i++) huge += 'x';
            var ok = ConjureDSP.state.set('big', huge);
            // After rejection the existing buffer must be unchanged.
            JSON.stringify({ ok: ok, has: ConjureDSP.state.get('big') === undefined });
        """)!.toString()!
        #expect(result == "{\"ok\":false,\"has\":true}",
                "over-cap set must return false AND leave state unchanged; got \(result)")
    }

    @Test func overCapSetDoesNotFireHandlersOrPostToSwift() throws {
        let ctx = try Self.makeContext(
            declaredStateKeys: ["big"],
            maxStateBytes: 64
        )
        let result = ctx.evaluateScript("""
            var fires = 0;
            ConjureDSP.state.onChange('big', function() { fires++; });
            window.__posts = [];   // reset post log after _init noise
            var huge = '';
            for (var i = 0; i < 200; i++) huge += 'x';
            ConjureDSP.state.set('big', huge);
            var stateSetPosts = window.__posts.filter(function(p) { return p.name === 'stateSet'; });
            JSON.stringify({ fires: fires, posts: stateSetPosts.length });
        """)!.toString()!
        #expect(result == "{\"fires\":0,\"posts\":0}",
                "over-cap rejection must skip handlers AND skip the postTo('stateSet') call; got \(result)")
    }

    // MARK: - External _stateUpdate path (DAW load / MCP / preset switch)

    @Test func externalStateUpdateFiresOnChange() throws {
        let ctx = try Self.makeContext(declaredStateKeys: ["foo"])
        let result = ctx.evaluateScript("""
            var fires = [];
            ConjureDSP.state.onChange('foo', function(v) { fires.push(v); });
            ConjureDSP._stateUpdate('foo', 42);
            JSON.stringify({ fires: fires, val: ConjureDSP.state.get('foo') });
        """)!.toString()!
        #expect(result == "{\"fires\":[42],\"val\":42}",
                "_stateUpdate must update the local cache AND fire onChange handlers; got \(result)")
    }

    @Test func externalStateUpdateNullKeyAndValueFiresFullResetSignal() throws {
        let ctx = try Self.makeContext(declaredStateKeys: ["foo"])
        let result = ctx.evaluateScript("""
            var anyFires = [];
            ConjureDSP.state.onAnyChange(function(k, v) { anyFires.push([k, v]); });
            ConjureDSP._stateUpdate(null, null);
            JSON.stringify(anyFires);
        """)!.toString()!
        // (null, null) is the documented "full reset incoming" signal —
        // consumers re-read everything once defaults arrive via _init.
        #expect(result == "[[null,null]]",
                "_stateUpdate(null, null) must fire onAnyChange with (null, null); got \(result)")
    }

    // MARK: - reset / resetAll post to Swift

    @Test func resetPostsStateResetToSwift() throws {
        let ctx = try Self.makeContext(declaredStateKeys: ["foo"])
        let result = ctx.evaluateScript("""
            window.__posts = [];
            ConjureDSP.state.reset('foo');
            var resets = window.__posts.filter(function(p) { return p.name === 'stateReset'; });
            JSON.stringify(resets);
        """)!.toString()!
        #expect(result == "[{\"name\":\"stateReset\",\"payload\":{\"key\":\"foo\"}}]",
                "state.reset(key) must post a single 'stateReset' message with the key; got \(result)")
    }

    @Test func resetAllPostsStateResetAllToSwift() throws {
        let ctx = try Self.makeContext(declaredStateKeys: ["foo"])
        let result = ctx.evaluateScript("""
            window.__posts = [];
            ConjureDSP.state.resetAll();
            var resetAlls = window.__posts.filter(function(p) { return p.name === 'stateResetAll'; });
            resetAlls.length;
        """)!.toNumber()!.intValue
        #expect(result == 1,
                "state.resetAll() must post exactly one 'stateResetAll' message; got \(result)")
    }

    // MARK: - Undeclared-key warning

    @Test func undeclaredKeyWarningFiresOncePerKey() throws {
        // Declare nothing — every set is undeclared, but the bridge must
        // only warn on the first write per key per session.
        let ctx = try Self.makeContext(declaredStateKeys: [])
        let result = ctx.evaluateScript("""
            window.__posts = [];
            ConjureDSP.state.set('typo', 1);
            ConjureDSP.state.set('typo', 2);
            ConjureDSP.state.set('typo', 3);
            ConjureDSP.state.set('other_typo', 99);
            var logs = window.__posts.filter(function(p) {
                return p.name === 'log' &&
                       typeof p.payload === 'string' &&
                       p.payload.indexOf('not declared') !== -1;
            });
            // Expect 2 warnings: one for "typo", one for "other_typo".
            JSON.stringify({ count: logs.length });
        """)!.toString()!
        #expect(result == "{\"count\":2}",
                "undeclared-key warning must fire exactly once per (key × session); got \(result)")
    }

    @Test func declaredKeysDoNotEmitUndeclaredWarning() throws {
        let ctx = try Self.makeContext(declaredStateKeys: ["count"])
        let result = ctx.evaluateScript("""
            window.__posts = [];
            ConjureDSP.state.set('count', 1);
            ConjureDSP.state.set('count', 2);
            var logs = window.__posts.filter(function(p) {
                return p.name === 'log' &&
                       typeof p.payload === 'string' &&
                       p.payload.indexOf('not declared') !== -1;
            });
            logs.length;
        """)!.toNumber()!.intValue
        #expect(result == 0,
                "writing a declared key must never emit the undeclared-key warning; got \(result)")
    }
}
