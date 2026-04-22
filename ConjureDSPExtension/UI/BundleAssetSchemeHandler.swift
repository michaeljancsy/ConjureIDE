import Foundation
import os.log
import WebKit

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP.ConjureDSPExtension", category: "BundleAssetSchemeHandler")

/// Serves files from a preset bundle's `ui/` directory into a WKWebView's
/// WebContent process via a custom URL scheme.
///
/// WebContent is a separate process with its own sandbox that does NOT
/// inherit the appex's App Group entitlement. Loading files directly from
/// `~/Library/Group Containers/...` via `loadFileURL` triggers
/// `kTCCServiceSystemPolicyAppData` prompts ("ConjureDSP would like to
/// access data from other apps"). By routing requests through
/// `WKURLSchemeHandler` — which runs in the appex process — we read the
/// files with the appex's entitlements and stream bytes to WebContent,
/// avoiding the TCC gate entirely.
///
/// URL format: `conjuredsp-preset://preset/<relative-path-inside-bundle>`
/// e.g. `conjuredsp-preset://preset/ui/index.html`.
final class BundleAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    /// The bundle root (e.g. `.../RepoPresets/MyBundle.cdp`). All served
    /// paths are resolved relative to and constrained to this directory.
    let rootURL: URL

    /// Resolved output of a single scheme-handler request.
    struct Asset {
        let fileURL: URL
        let data: Data
        let mimeType: String
    }

    enum ResolveError: Error, Equatable {
        /// The resolved path escapes the bundle root (e.g. `../../../secrets`).
        case outsideBundle
        /// File does not exist or isn't readable.
        case notFound
        /// `Data(contentsOf:)` threw.
        case ioError(String)
    }

    init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    // MARK: - Testable core

    /// Resolve a request URL to an asset without touching WKURLSchemeTask or
    /// WKWebView. Pure function; exists so unit tests can verify sandboxing
    /// and MIME-type selection without spinning up a webview.
    func resolve(requestURL: URL) throws -> Asset {
        // Strip leading `/` from the URL path so we resolve relative to rootURL.
        let relativePath = requestURL.path.hasPrefix("/")
            ? String(requestURL.path.dropFirst())
            : requestURL.path
        let candidate = rootURL.appendingPathComponent(relativePath).standardizedFileURL

        // Sandbox: candidate must stay inside rootURL. `standardizedFileURL`
        // resolves `..` segments so a path like `../../../etc/passwd` no
        // longer starts with rootURL's path and gets rejected.
        //
        // Require either exact match OR prefix with trailing "/" — a bare
        // hasPrefix check would match sibling paths like `/MyBundle.cdpEvil`
        // when the root is `/MyBundle.cdp`.
        let rootPath = rootURL.standardizedFileURL.path
        guard candidate.path == rootPath || candidate.path.hasPrefix(rootPath + "/") else {
            throw ResolveError.outsideBundle
        }

        // Must exist as a regular readable file. Directories and missing
        // paths both get the same "not found" error — a caller requesting
        // a directory path (e.g. `ui/assets`) isn't a valid use case and
        // would otherwise fail later in `Data(contentsOf:)` with an IO
        // error that's less descriptive.
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir)
        guard exists, !isDir.boolValue,
              FileManager.default.isReadableFile(atPath: candidate.path) else {
            throw ResolveError.notFound
        }

        let data: Data
        do {
            data = try Data(contentsOf: candidate)
        } catch {
            throw ResolveError.ioError(error.localizedDescription)
        }

        let mime = Self.mimeType(for: candidate.pathExtension.lowercased())
        return Asset(fileURL: candidate, data: data, mimeType: mime)
    }

    /// Look up a MIME type for the given lowercased file extension. Returns
    /// `application/octet-stream` when unknown. Exposed for tests.
    static func mimeType(for fileExtension: String) -> String {
        mimeTypes[fileExtension] ?? "application/octet-stream"
    }

    // MARK: - WKURLSchemeHandler

    /// Tasks WebKit has told us to stop. Calling `didReceive()` or
    /// `didFinish()` on a stopped task raises
    /// `NSInternalInconsistencyException`. `start:` reads from disk
    /// synchronously on its worker thread, and WebKit may call `stop:`
    /// on a different thread at any point during that window (window
    /// close, navigation away, webview teardown). Track stopped task
    /// identities so the tail of `start:` can bail cleanly instead of
    /// crashing. Keyed by `ObjectIdentifier` on the task; entries are
    /// removed by `start:` when it's done with a task and by `stop:`
    /// unconditionally.
    private let stoppedTasksLock = NSLock()
    private var stoppedTasks: Set<ObjectIdentifier> = []

    private func isStopped(_ task: WKURLSchemeTask) -> Bool {
        stoppedTasksLock.lock()
        defer { stoppedTasksLock.unlock() }
        return stoppedTasks.contains(ObjectIdentifier(task))
    }

    private func markStopped(_ task: WKURLSchemeTask) {
        stoppedTasksLock.lock()
        stoppedTasks.insert(ObjectIdentifier(task))
        stoppedTasksLock.unlock()
    }

    private func clearStopped(_ task: WKURLSchemeTask) {
        stoppedTasksLock.lock()
        stoppedTasks.remove(ObjectIdentifier(task))
        stoppedTasksLock.unlock()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        // Wrap every didReceive/didFail/didFinish call to skip it when
        // WebKit has already told us to stop the task. Without this the
        // appex crashes on window-close-during-load races.
        func fail(_ error: Error) {
            if isStopped(urlSchemeTask) { clearStopped(urlSchemeTask); return }
            urlSchemeTask.didFailWithError(error)
        }

        guard let requestURL = urlSchemeTask.request.url else {
            fail(Self.nsError(.badURL, "missing request URL"))
            return
        }

        let asset: Asset
        do {
            asset = try resolve(requestURL: requestURL)
        } catch ResolveError.outsideBundle {
            log.error("Scheme handler rejected out-of-bundle request: \(requestURL.path, privacy: .public)")
            fail(Self.nsError(.unsupportedURL, "outside bundle"))
            return
        } catch ResolveError.notFound {
            fail(Self.nsError(.fileDoesNotExist, requestURL.path))
            return
        } catch ResolveError.ioError(let detail) {
            fail(Self.nsError(.cannotOpenFile, detail))
            return
        } catch {
            fail(error)
            return
        }

        let headers: [String: String] = [
            "Content-Type": asset.mimeType,
            "Content-Length": String(asset.data.count),
            // Tighten what custom UIs can do. Authors may override with their
            // own <meta http-equiv="Content-Security-Policy"> tag if needed.
            "Content-Security-Policy": "default-src 'self' 'unsafe-inline' data:; connect-src 'none';",
        ]
        let response = HTTPURLResponse(url: requestURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)
            ?? URLResponse(url: requestURL, mimeType: asset.mimeType, expectedContentLength: asset.data.count, textEncodingName: nil) as URLResponse

        if isStopped(urlSchemeTask) { clearStopped(urlSchemeTask); return }
        urlSchemeTask.didReceive(response)
        if isStopped(urlSchemeTask) { clearStopped(urlSchemeTask); return }
        urlSchemeTask.didReceive(asset.data)
        if isStopped(urlSchemeTask) { clearStopped(urlSchemeTask); return }
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Reads are synchronous, but WebKit can still call `stop` from
        // another thread while `start` is in flight (e.g. window close
        // during load). Mark the task so the tail of `start` bails
        // instead of raising NSInternalInconsistencyException.
        markStopped(urlSchemeTask)
    }

    // MARK: - Internals

    private static func nsError(_ code: URLError.Code, _ description: String) -> NSError {
        NSError(domain: NSURLErrorDomain, code: code.rawValue, userInfo: [NSLocalizedDescriptionKey: description])
    }

    private static let mimeTypes: [String: String] = [
        "html": "text/html; charset=utf-8",
        "htm": "text/html; charset=utf-8",
        "js": "application/javascript; charset=utf-8",
        "mjs": "application/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "json": "application/json; charset=utf-8",
        "svg": "image/svg+xml",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
        "ico": "image/x-icon",
        "woff": "font/woff",
        "woff2": "font/woff2",
        "ttf": "font/ttf",
        "otf": "font/otf",
        "wasm": "application/wasm",
        "map": "application/json",
        "txt": "text/plain; charset=utf-8",
    ]
}
