//
//  CustomUIBridgeTransportTests.swift
//  ConjureDSPLogicTests
//
//  Pins the bridge contract for `ConjureDSP.transport.*`: getters return
//  the latest snapshot, `_transportUpdate` fires `onChange` handlers
//  synchronously, subscribe/unsubscribe posts the right messages to
//  Swift, and the channel is independent of `audio.onFrame`.
//
//  Driven via JSContext + a stubbed messageHandlers map (so postTo()
//  calls record into a JS-side array rather than reaching real Swift).
//  Same fast-tier pattern as CustomUIBridgeOnChangeTests — no host app,
//  no WKWebView.
//

import Foundation
import JavaScriptCore
import Testing

struct CustomUIBridgeTransportTests {

    /// Loads the bridge into a JSContext and stubs WebKit's
    /// `messageHandlers` so every `postTo(name, payload)` call records
    /// `{name, payload}` into `window.__posts`. Tests can then assert
    /// which subscribe / unsubscribe messages went to Swift.
    private static func makeContext() throws -> JSContext {
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
        ctx.evaluateScript("""
            ConjureDSP._init({
                metadata: [{ name: 'A', min: 0, max: 1, default: 0 }],
                values: [0],
                theme: 'light'
            });
        """)
        if let exception = ctx.exception {
            throw NSError(
                domain: "CustomUIBridgeTransportTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "JS bootstrap threw: \(exception)"]
            )
        }
        return ctx
    }

    // MARK: - Initial state + getters

    @Test func transportGettersDefaultToZero() throws {
        let ctx = try Self.makeContext()
        let result = ctx.evaluateScript("""
            JSON.stringify({
                tempo: ConjureDSP.transport.tempo,
                isPlaying: ConjureDSP.transport.isPlaying,
                beatPosition: ConjureDSP.transport.beatPosition,
                num: ConjureDSP.transport.timeSigNumerator,
                den: ConjureDSP.transport.timeSigDenominator,
            });
        """)!.toString()!
        #expect(result == "{\"tempo\":0,\"isPlaying\":false,\"beatPosition\":0,\"num\":4,\"den\":4}",
                "default snapshot before any push must be zero / 4-over-4; got \(result)")
    }

    @Test func transportUpdateUpdatesGetters() throws {
        let ctx = try Self.makeContext()
        let result = ctx.evaluateScript("""
            ConjureDSP._transportUpdate({
                tempo: 120, isPlaying: true, beatPosition: 1.5,
                samplePosition: 66150,
                timeSigNumerator: 6, timeSigDenominator: 8
            });
            JSON.stringify({
                tempo: ConjureDSP.transport.tempo,
                isPlaying: ConjureDSP.transport.isPlaying,
                beatPosition: ConjureDSP.transport.beatPosition,
                num: ConjureDSP.transport.timeSigNumerator,
                den: ConjureDSP.transport.timeSigDenominator,
            });
        """)!.toString()!
        #expect(result == "{\"tempo\":120,\"isPlaying\":true,\"beatPosition\":1.5,\"num\":6,\"den\":8}",
                "_transportUpdate must update the live snapshot; got \(result)")
    }

    // MARK: - onChange dispatch

    @Test func onChangeFiresSynchronouslyOnUpdate() throws {
        let ctx = try Self.makeContext()
        let result = ctx.evaluateScript("""
            var fires = [];
            ConjureDSP.transport.onChange(function(s) { fires.push(s.tempo); });
            ConjureDSP._transportUpdate({ tempo: 140, isPlaying: false, beatPosition: 0,
                                          samplePosition: 0, timeSigNumerator: 4, timeSigDenominator: 4 });
            ConjureDSP._transportUpdate({ tempo: 141, isPlaying: false, beatPosition: 0,
                                          samplePosition: 0, timeSigNumerator: 4, timeSigDenominator: 4 });
            JSON.stringify(fires);
        """)!.toString()!
        #expect(result == "[140,141]",
                "onChange must fire once per _transportUpdate; got \(result)")
    }

    @Test func multipleOnChangeHandlersAllFire() throws {
        let ctx = try Self.makeContext()
        let result = ctx.evaluateScript("""
            var a = 0, b = 0;
            ConjureDSP.transport.onChange(function(s) { a = s.tempo; });
            ConjureDSP.transport.onChange(function(s) { b = s.tempo * 2; });
            ConjureDSP._transportUpdate({ tempo: 100, isPlaying: false, beatPosition: 0,
                                          samplePosition: 0, timeSigNumerator: 4, timeSigDenominator: 4 });
            JSON.stringify({ a: a, b: b });
        """)!.toString()!
        #expect(result == "{\"a\":100,\"b\":200}")
    }

    // MARK: - Subscribe / unsubscribe wire to Swift

    @Test func subscribeIsNotPostedUntilOnChangeCalled() throws {
        let ctx = try Self.makeContext()
        let result = ctx.evaluateScript("""
            var subscribePosts = window.__posts.filter(function(p) { return p.name === 'subscribeTransport'; });
            JSON.stringify(subscribePosts);
        """)!.toString()!
        #expect(result == "[]",
                "fresh bridge must not post subscribeTransport before any onChange handler registers; got \(result)")
    }

    @Test func firstOnChangePostsSubscribe() throws {
        let ctx = try Self.makeContext()
        let result = ctx.evaluateScript("""
            ConjureDSP.transport.onChange(function() {});
            var subs = window.__posts.filter(function(p) { return p.name === 'subscribeTransport'; });
            subs.length;
        """)!.toNumber()!.intValue
        #expect(result == 1, "first onChange must post exactly one subscribeTransport; got \(result)")
    }

    @Test func secondOnChangeDoesNotRepost() throws {
        let ctx = try Self.makeContext()
        let result = ctx.evaluateScript("""
            ConjureDSP.transport.onChange(function() {});
            ConjureDSP.transport.onChange(function() {});
            var subs = window.__posts.filter(function(p) { return p.name === 'subscribeTransport'; });
            subs.length;
        """)!.toNumber()!.intValue
        #expect(result == 1, "subsequent onChange registrations must not re-post subscribe; got \(result)")
    }

    @Test func lastOffChangePostsUnsubscribe() throws {
        let ctx = try Self.makeContext()
        let result = ctx.evaluateScript("""
            var cb1 = function() {};
            var cb2 = function() {};
            ConjureDSP.transport.onChange(cb1);
            ConjureDSP.transport.onChange(cb2);
            ConjureDSP.transport.offChange(cb1);
            var unsubsAfterFirstOff = window.__posts.filter(function(p) { return p.name === 'unsubscribeTransport'; }).length;
            ConjureDSP.transport.offChange(cb2);
            var unsubsAfterLastOff = window.__posts.filter(function(p) { return p.name === 'unsubscribeTransport'; }).length;
            JSON.stringify({ first: unsubsAfterFirstOff, last: unsubsAfterLastOff });
        """)!.toString()!
        #expect(result == "{\"first\":0,\"last\":1}",
                "unsubscribe should only fire when handler list goes empty; got \(result)")
    }

    // MARK: - Independence from audio frames

    @Test func transportSubscribeDoesNotTriggerAudioSubscribe() throws {
        let ctx = try Self.makeContext()
        let result = ctx.evaluateScript("""
            ConjureDSP.transport.onChange(function() {});
            var audioSubs = window.__posts.filter(function(p) { return p.name === 'subscribeAudioFrames'; });
            audioSubs.length;
        """)!.toNumber()!.intValue
        #expect(result == 0,
                "subscribing transport must NOT activate the audio capture pipeline; got \(result)")
    }

    @Test func audioSubscribeDoesNotTriggerTransportSubscribe() throws {
        let ctx = try Self.makeContext()
        let result = ctx.evaluateScript("""
            ConjureDSP.audio.onFrame(function() {});
            var tSubs = window.__posts.filter(function(p) { return p.name === 'subscribeTransport'; });
            tSubs.length;
        """)!.toNumber()!.intValue
        #expect(result == 0,
                "subscribing audio frames must NOT subscribe the transport channel; got \(result)")
    }
}
