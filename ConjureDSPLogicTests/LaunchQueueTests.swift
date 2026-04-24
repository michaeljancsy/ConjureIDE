//
//  LaunchQueueTests.swift
//  ConjureDSPLogicTests
//
//  Tests for the queue-until-xterm-verifies logic that solves the "picker
//  menu printed before anyone's listening" bug.
//

import Testing

struct LaunchQueueTests {

    /// Harness: captures `deliver` calls into an array so tests can assert
    /// what was actually written and in what order. `connected` defaults to
    /// false so tests exercise the queue path unless they flip it on.
    final class Harness {
        var connected: Bool = false
        var delivered: [String] = []

        func makeQueue() -> LaunchQueue {
            return LaunchQueue(
                isConnected: { [weak self] in self?.connected ?? false },
                deliver: { [weak self] cmd in self?.delivered.append(cmd) }
            )
        }
    }

    // MARK: - Immediate delivery

    @Test("Connected at enqueue time → delivered immediately, nothing pending")
    func connectedDeliversImmediately() {
        let h = Harness()
        h.connected = true
        var q = h.makeQueue()

        q.enqueue("claude\n")

        #expect(h.delivered == ["claude\n"])
        #expect(q.hasPending == false)
    }

    @Test("Multiple enqueues while connected all deliver, none queue")
    func connectedDeliversEveryEnqueue() {
        let h = Harness()
        h.connected = true
        var q = h.makeQueue()

        q.enqueue("a\n")
        q.enqueue("b\n")
        q.enqueue("c\n")

        #expect(h.delivered == ["a\n", "b\n", "c\n"])
        #expect(q.hasPending == false)
    }

    // MARK: - Queued delivery

    @Test("Disconnected at enqueue → nothing delivered, hasPending true")
    func disconnectedParksCommand() {
        let h = Harness()
        var q = h.makeQueue()

        q.enqueue("__conjuredsp_pick_agent\n")

        #expect(h.delivered.isEmpty)
        #expect(q.hasPending)
    }

    @Test("flush() while disconnected is still OK — delivers to the sink regardless")
    func flushDeliversRegardlessOfConnection() {
        let h = Harness()
        var q = h.makeQueue()
        q.enqueue("claude\n")

        // flush does NOT re-check isConnected — caller invokes it BECAUSE a
        // client just verified. Delivering to the sink is correct at that point.
        q.flush()

        #expect(h.delivered == ["claude\n"])
        #expect(q.hasPending == false)
    }

    @Test("flush() with nothing queued is a no-op")
    func flushEmptyIsNoop() {
        let h = Harness()
        var q = h.makeQueue()

        q.flush()

        #expect(h.delivered.isEmpty)
        #expect(q.hasPending == false)
    }

    @Test("flush() is idempotent — a second flush after delivery does nothing")
    func flushIdempotent() {
        let h = Harness()
        var q = h.makeQueue()
        q.enqueue("x\n")
        q.flush()
        h.delivered.removeAll()  // watch for any spurious re-delivery

        q.flush()
        q.flush()

        #expect(h.delivered.isEmpty)
        #expect(q.hasPending == false)
    }

    // MARK: - Transition behaviours

    @Test("enqueue → connect → flush is the picker path")
    func pickerHappyPath() {
        let h = Harness()
        var q = h.makeQueue()

        q.enqueue("__conjuredsp_pick_agent\n")
        #expect(h.delivered.isEmpty)         // not yet — no client
        #expect(q.hasPending)

        h.connected = true                   // xterm verified
        q.flush()                            // TerminalApp calls this on verify

        #expect(h.delivered == ["__conjuredsp_pick_agent\n"])
        #expect(q.hasPending == false)
    }

    @Test("Second enqueue while a command is already pending replaces the first")
    func secondEnqueueReplacesPending() {
        let h = Harness()
        var q = h.makeQueue()
        q.enqueue("stale\n")

        q.enqueue("fresh\n")                  // replaces `stale`
        h.connected = true
        q.flush()

        #expect(h.delivered == ["fresh\n"])
        // `stale` is intentionally dropped — the "latest" launch is the one
        // the caller means to run. Callers are expected not to rely on prior
        // enqueued commands having been delivered.
    }

    @Test("clear() discards without delivering")
    func clearDropsPending() {
        let h = Harness()
        var q = h.makeQueue()
        q.enqueue("anything\n")
        #expect(q.hasPending)

        q.clear()

        #expect(q.hasPending == false)
        #expect(h.delivered.isEmpty)

        // Subsequent flush is a no-op.
        q.flush()
        #expect(h.delivered.isEmpty)
    }

    @Test("After flush, a new enqueue while still-connected delivers immediately")
    func reuseAfterFlush() {
        let h = Harness()
        var q = h.makeQueue()

        // First round: queued then flushed.
        q.enqueue("first\n")
        h.connected = true
        q.flush()

        // Second round: connected → should deliver immediately.
        q.enqueue("second\n")

        #expect(h.delivered == ["first\n", "second\n"])
        #expect(q.hasPending == false)
    }

    @Test("isConnected is re-evaluated on every enqueue (not cached at init)")
    func isConnectedReEvaluatedPerEnqueue() {
        let h = Harness()
        var q = h.makeQueue()

        // Not connected — queues.
        q.enqueue("a\n")
        #expect(q.hasPending)
        q.clear()

        // Flip on — next enqueue delivers.
        h.connected = true
        q.enqueue("b\n")
        #expect(h.delivered == ["b\n"])

        // Flip off — queues again.
        h.connected = false
        q.enqueue("c\n")
        #expect(h.delivered == ["b\n"])
        #expect(q.hasPending)
    }
}
