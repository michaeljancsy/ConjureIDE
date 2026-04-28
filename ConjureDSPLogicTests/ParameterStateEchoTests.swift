//
//  ParameterStateEchoTests.swift
//  ConjureDSPLogicTests
//
//  Regression coverage for the "slider drags fight the user" bug. The
//  visible symptom was: dragging an HTML slider in a custom UI made the
//  thumb jump backward or stick, especially when the drag paused with
//  the mouse down or ran past the edge of the slider track.
//
//  Root cause: ParameterState.binding(for:) wrote through
//  `AUParameter.value = newValue`. That fires AU's
//  `token(byAddingParameterObserver:)` callback with every change,
//  including writes originated by the UI itself. The observer callback
//  dispatched `values[i] = value` to `DispatchQueue.main.async` —
//  queuing a second, DELAYED write of the same value.
//
//  For rapid drags, the second-wave writes published `$values` after
//  the user had moved on to later values. Those publishes went out as
//  echoes to the custom-UI webview, landed in the preset's onChange
//  handler as `rng.value = staleValue`, and ripped the slider thumb
//  backward mid-drag.
//
//  Fix: the binding setter uses
//  `AUParameter.setValue(_:originator:)` with our observer token as
//  the originator. AU's contract excludes the originator from its own
//  observer callback — so UI-originated writes don't echo back through
//  our observer. External writes (DAW automation, MIDI learn) still
//  fire the observer normally.
//
//  This test pins the AU contract we rely on. If a future macOS/AU
//  change ever breaks "originator is excluded from its own callback",
//  this test will fail loudly before the slider feedback loop returns
//  in production.
//

import AudioToolbox
import Foundation
import Testing

/// Thread-safe counter for observer-fire counts. AU fires the observer
/// callback on arbitrary threads, so a plain `var` shared with the test
/// thread would be a data race and read stale values.
private final class CallbackCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func increment() {
        lock.lock(); defer { lock.unlock() }
        _value += 1
    }
}

struct ParameterStateEchoTests {
    /// Build a single-parameter tree. Sufficient to exercise the
    /// observer-originator contract.
    private static func makeParameterTree() -> (AUParameterTree, AUParameter) {
        let param = AUParameterTree.createParameter(
            withIdentifier: "testParam",
            name: "Test Param",
            address: 0,
            min: 0,
            max: 1,
            unit: .generic,
            unitName: nil,
            flags: [.flag_IsReadable, .flag_IsWritable],
            valueStrings: nil,
            dependentParameters: nil
        )
        param.value = 0
        let tree = AUParameterTree.createTree(withChildren: [param])
        return (tree, param)
    }

    /// Wait until `counter.value >= expected`, up to `timeout` seconds.
    /// Returns whether the condition was met. Polling-based so we don't
    /// rely on a fixed sleep that's flaky under CI load.
    private static func waitForCount(
        _ counter: CallbackCounter,
        atLeast expected: Int,
        timeout: TimeInterval = 1.0
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if counter.value >= expected { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)  // 5ms poll
        }
        return counter.value >= expected
    }

    /// Brief pause to flush any straggler async callbacks. Used for
    /// the NEGATIVE assertions (observer should NOT fire) — we can't
    /// poll for "never fires," so we give it a generous window then
    /// assert the count is still zero.
    private static func drainCallbacks() async {
        try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms
    }

    /// A plain write via `AUParameter.value = X` fires the observer.
    /// This establishes the baseline — the observer IS wired up and
    /// CAN receive callbacks — so the originator-exclusion test below
    /// is meaningful (not a trivial "observer just never fires").
    @Test func plainWriteFiresObserver() async {
        let (tree, param) = Self.makeParameterTree()

        let counter = CallbackCounter()
        let token = tree.token(byAddingParameterObserver: { _, _ in
            counter.increment()
        })
        defer { tree.removeParameterObserver(token) }

        param.value = 0.7
        let fired = await Self.waitForCount(counter, atLeast: 1)

        #expect(fired,
               "Baseline broken: observer didn't fire for a plain write (count=\(counter.value))")
    }

    /// THE contract we depend on: a write via `setValue(_:originator:)`
    /// with token T as originator must NOT fire the observer registered
    /// under token T. This is what keeps UI-originated writes from
    /// echoing back through ParameterState's observer and kicking off
    /// the stale-dispatch feedback loop into the custom-UI webview.
    @Test func setValueWithOriginatorExcludesOwnObserver() async {
        let (tree, param) = Self.makeParameterTree()

        let counter = CallbackCounter()
        let token = tree.token(byAddingParameterObserver: { _, _ in
            counter.increment()
        })
        defer { tree.removeParameterObserver(token) }

        param.setValue(0.5, originator: token)
        await Self.drainCallbacks()

        #expect(counter.value == 0,
               "AU violated its originator-exclusion contract (count=\(counter.value)) — if this fails, ParameterState's binding setter will feed echoes back through its own observer and the slider-drag feedback bug returns")
    }

    /// A DIFFERENT observer (registered under a separate token) must
    /// still fire even when the write's originator is another token.
    /// Proves exclusion is per-token, not a global suppression. Also
    /// covers the case where a DAW or plugin host has its own observer
    /// on the tree — UI writes still propagate to DAW-side listeners
    /// for automation recording.
    @Test func setValueWithOriginatorStillFiresOtherObservers() async {
        let (tree, param) = Self.makeParameterTree()

        let uiCounter = CallbackCounter()
        let uiToken = tree.token(byAddingParameterObserver: { _, _ in
            uiCounter.increment()
        })
        defer { tree.removeParameterObserver(uiToken) }

        let otherCounter = CallbackCounter()
        let otherToken = tree.token(byAddingParameterObserver: { _, _ in
            otherCounter.increment()
        })
        defer { tree.removeParameterObserver(otherToken) }

        // UI write: uses uiToken as originator.
        param.setValue(0.25, originator: uiToken)
        let otherFired = await Self.waitForCount(otherCounter, atLeast: 1)
        await Self.drainCallbacks()  // also give uiCounter a chance to wrongly fire

        #expect(uiCounter.value == 0,
               "UI token should be excluded from its own callback (count=\(uiCounter.value))")
        #expect(otherFired,
               "Other observers must still receive UI-originated writes (DAW automation recording depends on this)")
    }

    /// ParameterState.binding's setter must actually USE the originator
    /// API. Easy to accidentally regress to `param.value = x` during a
    /// refactor — a grep-style check keeps the fix honest even when
    /// the behavioral tests above pass (AU contract holds whether or
    /// not WE use it correctly).
    @Test func parameterStateUsesOriginatorAPI() throws {
        // #filePath points at this file at build time; walk up to the
        // source file we're testing.
        let thisFile = URL(fileURLWithPath: #filePath)
        let projectRoot = thisFile
            .deletingLastPathComponent()  // ConjureDSPLogicTests/
            .deletingLastPathComponent()  // project root
        let paramStateURL = projectRoot
            .appendingPathComponent("ConjureDSPExtension/UI/ParameterState.swift")
        let source = try String(contentsOf: paramStateURL, encoding: .utf8)

        #expect(source.contains("setValue(newValue, originator:"),
               "ParameterState's binding setter must use setValue(_:originator:) with the observer token — reverting to `param.value = newValue` brings back the slider feedback-loop bug")
    }
}
