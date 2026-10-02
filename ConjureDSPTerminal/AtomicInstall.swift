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
        let staging = stagingURL(for: destination)

        // Clear a copy left by an install that was interrupted (Terminal quit
        // mid-copy). Usually nothing is there, so the error is ignored; if
        // something is there and can't be removed, the copy below fails.
        try? fm.removeItem(at: staging)
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
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
            NSLocalizedDescriptionKey: "Couldn't move \(staging.path) into place at \(destination.path): \(String(cString: strerror(code)))"
        ])
    }

    /// Hidden sibling the new copy is written to before it's moved into place.
    nonisolated static func stagingURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).staging")
    }
}
