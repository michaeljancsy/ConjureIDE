//
//  RuntimeErrorParserTests.swift
//  ConjureDSPLogicTests
//
//  PR #4: tests the Python-traceback line-number extractor used by the
//  runtime-error poller to place a Monaco gutter marker at the offending
//  line. The logic is duplicated here (matching the codebase's pattern
//  for tests that can't import the extension target — see MCPProtocolTests
//  for precedent) so the test doesn't pull in the AU.
//

import Foundation
import Testing

// MARK: - Copy of the production extractor

private enum RuntimeErrorParser {
    static func extractLineNumber(traceback: String, scriptPath: String?) -> Int? {
        guard let scriptPath, !scriptPath.isEmpty else { return nil }
        let pattern = #"File\s+"([^"]+)",\s+line\s+(\d+)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(traceback.startIndex..., in: traceback)
        var bestLine: Int? = nil
        re.enumerateMatches(in: traceback, range: range) { match, _, _ in
            guard let match,
                  let pathRange = Range(match.range(at: 1), in: traceback),
                  let lineRange = Range(match.range(at: 2), in: traceback) else { return }
            let path = String(traceback[pathRange])
            if path == scriptPath, let line = Int(traceback[lineRange]) {
                bestLine = line
            }
        }
        return bestLine
    }
}

// MARK: - Tests

@Suite("Runtime error traceback parser")
struct RuntimeErrorParserTests {
    @Test("Single-frame raise: line number extracted from matching path")
    func topFrameSingleMatch() {
        let traceback = """
        Traceback (most recent call last):
          File "/var/folders/xy/abc/T/process_123.py", line 5, in process
            raise ValueError('boom')
        ValueError: boom
        """
        let line = RuntimeErrorParser.extractLineNumber(
            traceback: traceback,
            scriptPath: "/var/folders/xy/abc/T/process_123.py"
        )
        #expect(line == 5)
    }

    @Test("Helper-raised: innermost matching frame wins")
    func helperRaisedInnerWins() {
        // process.py calls a helper, which calls process_inner. Tracebacks
        // walk outermost → innermost; we want the LAST frame whose path
        // matches the active script. Here both frames in /path/preset.py
        // appear; the innermost (line 42) should win.
        let traceback = """
        Traceback (most recent call last):
          File "/path/preset.py", line 12, in process
            do_work(ctx)
          File "/path/preset.py", line 42, in do_work
            raise RuntimeError('inner')
        RuntimeError: inner
        """
        let line = RuntimeErrorParser.extractLineNumber(
            traceback: traceback,
            scriptPath: "/path/preset.py"
        )
        #expect(line == 42)
    }

    @Test("Non-matching path returns nil")
    func noMatchingFrameReturnsNil() {
        let traceback = """
        Traceback (most recent call last):
          File "/path/helper.py", line 7, in helper
            raise ValueError('from helper')
        ValueError: from helper
        """
        let line = RuntimeErrorParser.extractLineNumber(
            traceback: traceback,
            scriptPath: "/path/preset.py"
        )
        #expect(line == nil)
    }

    @Test("nil scriptPath returns nil")
    func nilScriptPathReturnsNil() {
        let traceback = """
        Traceback (most recent call last):
          File "/path/preset.py", line 5, in process
            raise ValueError('boom')
        """
        let line = RuntimeErrorParser.extractLineNumber(
            traceback: traceback,
            scriptPath: nil
        )
        #expect(line == nil)
    }

    @Test("Empty traceback returns nil")
    func emptyTracebackReturnsNil() {
        let line = RuntimeErrorParser.extractLineNumber(
            traceback: "",
            scriptPath: "/path/preset.py"
        )
        #expect(line == nil)
    }

    @Test("Path with quotes and special chars matches literally")
    func specialCharsInPath() {
        let path = "/var/folders/xy/n5qmh4g57k128b71zmstk4440000gn/T/process_abc.py"
        let traceback = """
        Traceback (most recent call last):
          File "\(path)", line 23, in process
            x = 1 / 0
        ZeroDivisionError: division by zero
        """
        let line = RuntimeErrorParser.extractLineNumber(
            traceback: traceback,
            scriptPath: path
        )
        #expect(line == 23)
    }

    @Test("Multiple frames in different files, only matching one is used")
    func multipleFilesInTraceback() {
        // Outer frame is the test runner; innermost is the user script.
        let traceback = """
        Traceback (most recent call last):
          File "/some/other/file.py", line 100, in __call__
            ret = self.fn(ctx)
          File "/path/preset.py", line 8, in process
            raise IndexError('out of range')
        IndexError: out of range
        """
        let line = RuntimeErrorParser.extractLineNumber(
            traceback: traceback,
            scriptPath: "/path/preset.py"
        )
        #expect(line == 8)
    }
}
