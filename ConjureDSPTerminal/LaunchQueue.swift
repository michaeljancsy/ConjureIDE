//
//  LaunchQueue.swift
//  ConjureDSP
//
//  Tiny queue for the PTY launch command. PTYManager writes the mode-setup
//  line (aliases + shell functions) immediately — it's silent — but the
//  actual launch command (picker / claude / gemini / banner-restore-echo)
//  has to wait for a verified xterm client to be connected. Otherwise the
//  shell can print its menu before any client is ready to receive it, and
//  the output vanishes into `broadcast`'s iteration over an empty
//  `verifiedClients` set.
//
//  This struct holds that queueing logic so we can unit-test it without a
//  real PTY/shell/WebSocket stack.
//

import Foundation

/// A single-slot queue for the launch command. Holds at most one pending
/// command; a second `enqueue` before `flush` overwrites the first (the
/// caller's intent is always "this is the latest thing to run").
struct LaunchQueue {

    /// Returns true when there is at least one verified xterm client listening.
    /// Injected so tests can flip the answer without a real socket.
    private let isConnected: () -> Bool

    /// Called to actually deliver a command to the PTY (or a capture array in tests).
    private let deliver: (String) -> Void

    private var pending: String?

    init(isConnected: @escaping () -> Bool, deliver: @escaping (String) -> Void) {
        self.isConnected = isConnected
        self.deliver = deliver
    }

    /// True when a command is waiting for a verified client.
    var hasPending: Bool { pending != nil }

    /// Submit a launch command. Delivers immediately if a verified client is
    /// connected, otherwise parks it until `flush()` is called.
    mutating func enqueue(_ cmd: String) {
        if isConnected() {
            deliver(cmd)
        } else {
            pending = cmd
        }
    }

    /// Deliver any pending command and clear the slot. No-op when empty.
    /// Idempotent: repeated flushes after delivery do nothing.
    mutating func flush() {
        guard let cmd = pending else { return }
        pending = nil
        deliver(cmd)
    }

    /// Discard any pending command without delivering. Used when the session
    /// is torn down before a client ever verified.
    mutating func clear() {
        pending = nil
    }
}
