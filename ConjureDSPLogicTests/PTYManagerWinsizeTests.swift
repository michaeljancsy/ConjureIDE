//
//  PTYManagerWinsizeTests.swift
//  ConjureDSPLogicTests
//
//  Regression test for the "smear on relaunch" bug.
//
//  When `pty.restart()` re-forks the agent process, the WebSocket stays
//  open — JS's `socket.onopen` does NOT fire — so xterm.js never re-sends
//  the current cols/rows. If the new PTY uses the hardcoded 24x80 default,
//  Claude's status redraws smear across the visible grid until the user
//  nudges the splitter to force a new resize event.
//
//  Fix: `PTYManager.initialWinsize(cached:)` reuses the most recent applied
//  winsize when one is available, falling back to 24x80 only on first launch.
//  Zero values are rejected on both the cache-write side (`resize`) and the
//  cache-read side (`initialWinsize`) so that a transient 0x0 measurement
//  from FitAddon during a layout pass can't brick the next forkpty.
//

import Darwin
import Foundation
import Testing

@MainActor
struct PTYManagerWinsizeTests {

    @Test("Nil cache falls back to the 24x80 default")
    func defaultWhenCacheIsNil() {
        let ws = PTYManager.initialWinsize(cached: nil)
        #expect(ws.ws_col == 80)
        #expect(ws.ws_row == 24)
    }

    @Test("Cached size is used verbatim on the next forkpty")
    func usesCachedWhenSet() {
        let cached = winsize(ws_row: 40, ws_col: 100, ws_xpixel: 0, ws_ypixel: 0)
        let ws = PTYManager.initialWinsize(cached: cached)
        #expect(ws.ws_col == 100)
        #expect(ws.ws_row == 40)
    }

    @Test("Cache with zero cols is rejected — fall back to default")
    func rejectsZeroCols() {
        let cached = winsize(ws_row: 40, ws_col: 0, ws_xpixel: 0, ws_ypixel: 0)
        let ws = PTYManager.initialWinsize(cached: cached)
        #expect(ws.ws_col == 80)
        #expect(ws.ws_row == 24)
    }

    @Test("Cache with zero rows is rejected — fall back to default")
    func rejectsZeroRows() {
        let cached = winsize(ws_row: 0, ws_col: 100, ws_xpixel: 0, ws_ypixel: 0)
        let ws = PTYManager.initialWinsize(cached: cached)
        #expect(ws.ws_col == 80)
        #expect(ws.ws_row == 24)
    }

    @Test("Cache with both zero is rejected")
    func rejectsZeroBoth() {
        let cached = winsize(ws_row: 0, ws_col: 0, ws_xpixel: 0, ws_ypixel: 0)
        let ws = PTYManager.initialWinsize(cached: cached)
        #expect(ws.ws_col == 80)
        #expect(ws.ws_row == 24)
    }
}
