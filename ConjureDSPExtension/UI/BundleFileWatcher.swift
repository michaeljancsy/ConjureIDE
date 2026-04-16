import CoreServices
import Foundation
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP.ConjureDSPExtension", category: "BundleFileWatcher")

/// Watches a directory for any filesystem change under it and fires a
/// debounced callback. Used to hot-reload a preset bundle's `ui/` directory
/// while the author edits `ui/index.html` in an external editor.
///
/// Backed by `FSEventStream` (CoreServices). Unlike `DispatchSource`
/// file-system object sources, which only see events on a single file
/// descriptor, `FSEventStream` notifies on any change under the path —
/// covering both atomic-rename editors (VS Code) and in-place writes (nano,
/// simple scripts), without having to juggle multiple FDs.
///
/// Callbacks arrive on the queue supplied to `start(on:)`. The watcher
/// coalesces bursts using a `latency` value; bursts that fall within the
/// latency window are merged into a single `onChange` callback.
final class BundleFileWatcher {
    /// Absolute path to watch recursively.
    let path: String

    /// Called on the supplied queue when the watched subtree changes. The
    /// watcher applies its own latency-based coalescing before invoking.
    var onChange: (() -> Void)?

    private var stream: FSEventStreamRef?

    init(path: String) {
        self.path = path
    }

    /// Start watching. No-op if already started. The callback runs on
    /// `queue` with a minimum gap of `latency` seconds between events.
    func start(on queue: DispatchQueue = .main, latency: CFTimeInterval = 0.2) {
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            // `passUnretained` above; fromOpaque without retain.
            let watcher = Unmanaged<BundleFileWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.onChange?()
        }

        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            log.error("FSEventStreamCreate failed for \(self.path, privacy: .public)")
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
        log.info("Watching \(self.path, privacy: .public)")
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
