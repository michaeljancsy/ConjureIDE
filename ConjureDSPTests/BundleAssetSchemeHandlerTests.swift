import Foundation
import Testing

struct BundleAssetSchemeHandlerTests {

    // MARK: - Helpers

    /// Build a temp directory that looks like a preset bundle's root so the
    /// handler has real files to serve.
    private static func makeBundle() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleAssetSchemeHandlerTests_\(UUID().uuidString)", isDirectory: true)
        let ui = root.appendingPathComponent("ui", isDirectory: true)
        let assets = ui.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try "<!doctype html><title>test</title>".write(to: ui.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "body { color: red; }".write(to: ui.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
        try "console.log('ok');".write(to: assets.appendingPathComponent("app.js"), atomically: true, encoding: .utf8)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: assets.appendingPathComponent("logo.png"))
        return root
    }

    private static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func url(for path: String) -> URL {
        URL(string: "conjuredsp-preset://preset/\(path)")!
    }

    // MARK: - MIME type table

    @Test func mimeTypeForKnownExtensions() {
        #expect(BundleAssetSchemeHandler.mimeType(for: "html") == "text/html; charset=utf-8")
        #expect(BundleAssetSchemeHandler.mimeType(for: "js") == "application/javascript; charset=utf-8")
        #expect(BundleAssetSchemeHandler.mimeType(for: "css") == "text/css; charset=utf-8")
        #expect(BundleAssetSchemeHandler.mimeType(for: "json") == "application/json; charset=utf-8")
        #expect(BundleAssetSchemeHandler.mimeType(for: "png") == "image/png")
        #expect(BundleAssetSchemeHandler.mimeType(for: "svg") == "image/svg+xml")
        #expect(BundleAssetSchemeHandler.mimeType(for: "wasm") == "application/wasm")
        #expect(BundleAssetSchemeHandler.mimeType(for: "woff2") == "font/woff2")
    }

    @Test func mimeTypeFallsBackToOctetStream() {
        #expect(BundleAssetSchemeHandler.mimeType(for: "xyz") == "application/octet-stream")
        #expect(BundleAssetSchemeHandler.mimeType(for: "") == "application/octet-stream")
    }

    // MARK: - Resolve: happy path

    @Test func resolveServesIndexHTML() throws {
        let root = try Self.makeBundle()
        defer { Self.cleanup(root) }
        let handler = BundleAssetSchemeHandler(rootURL: root)

        let asset = try handler.resolve(requestURL: Self.url(for: "ui/index.html"))

        #expect(asset.mimeType == "text/html; charset=utf-8")
        #expect(String(data: asset.data, encoding: .utf8)?.contains("<title>test</title>") == true)
        #expect(asset.fileURL.lastPathComponent == "index.html")
    }

    @Test func resolveServesNestedAsset() throws {
        let root = try Self.makeBundle()
        defer { Self.cleanup(root) }
        let handler = BundleAssetSchemeHandler(rootURL: root)

        let asset = try handler.resolve(requestURL: Self.url(for: "ui/assets/app.js"))

        #expect(asset.mimeType == "application/javascript; charset=utf-8")
        #expect(String(data: asset.data, encoding: .utf8) == "console.log('ok');")
    }

    @Test func resolveServesBinaryFileWithCorrectMIME() throws {
        let root = try Self.makeBundle()
        defer { Self.cleanup(root) }
        let handler = BundleAssetSchemeHandler(rootURL: root)

        let asset = try handler.resolve(requestURL: Self.url(for: "ui/assets/logo.png"))

        #expect(asset.mimeType == "image/png")
        #expect(asset.data.count == 4)
        #expect(asset.data.first == 0x89)
    }

    // MARK: - Resolve: sandbox enforcement

    @Test func resolveRejectsDotDotEscape() throws {
        let root = try Self.makeBundle()
        defer { Self.cleanup(root) }
        let handler = BundleAssetSchemeHandler(rootURL: root)

        let url = URL(string: "conjuredsp-preset://preset/ui/../../../../etc/passwd")!
        #expect(throws: BundleAssetSchemeHandler.ResolveError.outsideBundle) {
            try handler.resolve(requestURL: url)
        }
    }

    @Test func resolveRejectsAbsolutePathInUrlPath() throws {
        // `URL(string:)` with "conjuredsp-preset://preset//Users/..." keeps the
        // absolute-looking path segment. After we strip the leading slash it
        // becomes relative to rootURL, but if that hits an existing file on
        // disk outside rootURL we want the sandbox check to reject it.
        let root = try Self.makeBundle()
        defer { Self.cleanup(root) }
        let handler = BundleAssetSchemeHandler(rootURL: root)

        // Construct a URL whose path segment, relative to rootURL, escapes.
        let url = URL(string: "conjuredsp-preset://preset/../../../../bin/sh")!
        #expect(throws: BundleAssetSchemeHandler.ResolveError.outsideBundle) {
            try handler.resolve(requestURL: url)
        }
    }

    // MARK: - Resolve: missing / unreadable

    @Test func resolveReportsNotFoundForMissingFile() throws {
        let root = try Self.makeBundle()
        defer { Self.cleanup(root) }
        let handler = BundleAssetSchemeHandler(rootURL: root)

        #expect(throws: BundleAssetSchemeHandler.ResolveError.notFound) {
            try handler.resolve(requestURL: Self.url(for: "ui/does-not-exist.html"))
        }
    }

    @Test func resolveReportsNotFoundForDirectoryPath() throws {
        // Asking for a directory (no file) is treated as "not found" rather
        // than attempting to serve its inode.
        let root = try Self.makeBundle()
        defer { Self.cleanup(root) }
        let handler = BundleAssetSchemeHandler(rootURL: root)

        #expect(throws: BundleAssetSchemeHandler.ResolveError.notFound) {
            try handler.resolve(requestURL: Self.url(for: "ui/assets"))
        }
    }

    // MARK: - Root URL normalization

    @Test func rootURLIsStandardized() throws {
        let temp = FileManager.default.temporaryDirectory
        // Construct a non-standard URL (unresolved /private prefix on macOS).
        let root = temp.appendingPathComponent("handler_root_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { Self.cleanup(root) }
        try "hi".write(to: root.appendingPathComponent("greeting.txt"), atomically: true, encoding: .utf8)

        let handler = BundleAssetSchemeHandler(rootURL: root)
        let asset = try handler.resolve(requestURL: Self.url(for: "greeting.txt"))
        #expect(String(data: asset.data, encoding: .utf8) == "hi")
        // Resolved file URL sits under the standardized root.
        #expect(asset.fileURL.path.hasPrefix(handler.rootURL.path))
    }
}
