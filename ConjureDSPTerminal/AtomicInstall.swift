//
//  AtomicInstall.swift
//  ConjureDSPTerminal
//
//  Copies bundled runtime files (the Python stdlib, libpython, the
//  `conjuredsp` package, rustc-dist) into the App Group container so that
//  other processes never see a half-written copy.
//
//  The plugin starts Python as soon as PythonRuntime/lib/python3.14t
//  exists. Deleting that folder and copying a fresh one in its place left a
//  window of a few seconds where the folder existed but was partly deleted
//  or partly copied. A plugin that started Python inside that window got
//  "Fatal Python error", and CPython's response is exit(1) — the plugin
//  process vanished and the host showed a blank view. Here the new copy is
//  written to a hidden sibling and moved into place with a single rename,
//  so the path always holds either the old complete copy or the new one.
//

import Darwin
import Foundation

enum AtomicInstall {

    /// Replace whatever is at `destination` with a copy of `source`, without
    /// `destination` ever being visible half-written.
    ///
    /// `copy` is the copy step, injectable so tests can look at
    /// `destination` while a copy is in progress.
    nonisolated static func replaceItem(
        at destination: URL,
        withCopyOf source: URL,
        copy: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }
    ) throws {
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent()
        let prefix = stagingPrefix(for: destination)

        // More than one Terminal can be installing at once (a Debug and a
        // Release build share this container). Hold an exclusive lock for the
        // whole install so one never clears another's in-progress copy. The
        // lock file is never deleted: that would let a waiting installer and
        // a new one each lock a different file. The OS drops the lock if the
        // process dies.
        let lockPath = parent.appendingPathComponent(".\(destination.lastPathComponent).lock").path
        let lockFD = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard lockFD >= 0 else {
            throw posixError(errno, "Couldn't open \(lockPath)")
        }
        defer { close(lockFD) }
        while flock(lockFD, LOCK_EX) != 0 {
            guard errno == EINTR else { throw posixError(errno, "Couldn't lock \(lockPath)") }
        }

        // Clear copies left by installs that were interrupted (Terminal quit
        // mid-copy). Best effort: each attempt stages under a fresh name, so
        // a leftover that can't be removed never blocks a later install.
        for name in (try? fm.contentsOfDirectory(atPath: parent.path)) ?? [] where name.hasPrefix(prefix) {
            try? fm.removeItem(at: parent.appendingPathComponent(name))
        }

        let staging = parent.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        do {
            try copy(source, staging)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }

        // RENAME_SWAP exchanges the two paths in one step. The old copy ends
        // up at the staging path; if deleting it fails, the next install
        // clears it.
        if renamex_np(staging.path, destination.path, UInt32(RENAME_SWAP)) == 0 {
            try? fm.removeItem(at: staging)
            return
        }
        var code = errno
        // ENOENT: nothing installed yet, and a plain rename is just as atomic.
        if code == ENOENT {
            if rename(staging.path, destination.path) == 0 { return }
            code = errno
        }
        try? fm.removeItem(at: staging)
        throw posixError(code, "Couldn't move \(staging.path) into place at \(destination.path)")
    }

    private nonisolated static func posixError(_ code: Int32, _ message: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
            NSLocalizedDescriptionKey: "\(message): \(String(cString: strerror(code)))"
        ])
    }

    /// Name prefix of the hidden siblings new copies are written to before
    /// they're moved into place.
    nonisolated static func stagingPrefix(for destination: URL) -> String {
        ".\(destination.lastPathComponent).staging"
    }
}
