import Foundation
import Testing

/// Regression net: run `BundleUIValidator` over every factory preset shipped
/// in `ConjureDSPExtension/Resources/presets/` and fail the test target if
/// any of them comes back with `status == .fail`.
///
/// This catches the case where someone edits a factory `.cdp` bundle (new
/// preset, UI tweak, manifest change) and accidentally ships it with a
/// validator-flagged bug. The tighter the validator's rules get over time,
/// the more value this sweep accrues — each new rule fans out across the
/// entire factory library without anyone having to write per-preset tests.
///
/// Resolved via `#filePath` rather than the appex's runtime Resources so
/// the test runs even when the extension hasn't been fully assembled (and
/// so it tests the source-of-truth bundle on disk, not a stale shipped
/// copy).
struct FactoryPresetValidationTests {

    /// Walk up from this source file to the repo root and return the
    /// factory-preset directory.
    private static var factoryPresetsURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ConjureDSPTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("ConjureDSPExtension")
            .appendingPathComponent("Resources")
            .appendingPathComponent("presets")
    }

    /// Enumerate every `*.cdp` directory directly inside the factory
    /// presets folder. Returns URLs sorted by bundle name so failure
    /// output is stable.
    private static func factoryBundleURLs() throws -> [URL] {
        let fm = FileManager.default
        let root = factoryPresetsURL
        let entries = try fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return entries
            .filter { $0.pathExtension == "cdp" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @Test("Every factory preset loads as a bundle")
    func everyFactoryPresetLoads() throws {
        let urls = try Self.factoryBundleURLs()
        #expect(!urls.isEmpty, "No factory presets found at \(Self.factoryPresetsURL.path) — test setup broken")

        var failures: [String] = []
        for url in urls {
            guard PresetBundle.load(from: url) != nil else {
                failures.append(url.lastPathComponent)
                continue
            }
        }
        #expect(failures.isEmpty, "Failed to load factory preset bundle(s): \(failures.joined(separator: ", "))")
    }

    @Test("No factory preset trips a validator fail")
    func noFactoryPresetFailsValidator() throws {
        let urls = try Self.factoryBundleURLs()
        #expect(!urls.isEmpty, "test setup broken: no factory presets found")

        var offenders: [(String, [BundleUIValidator.Issue])] = []
        for url in urls {
            guard let bundle = PresetBundle.load(from: url) else { continue }
            let report = BundleUIValidator.validate(bundle)
            if report.status == .fail {
                let failIssues = report.issues.filter { $0.severity == .fail }
                offenders.append((bundle.name, failIssues))
            }
        }

        if !offenders.isEmpty {
            let detail = offenders.map { name, issues in
                let lines = issues.map { "    - [\($0.check)] \($0.message)" }.joined(separator: "\n")
                return "  \(name):\n\(lines)"
            }.joined(separator: "\n")
            Issue.record("\(offenders.count) factory preset(s) trip a validator fail:\n\(detail)")
        }
    }

    @Test("Factory preset warning count stays under control")
    func factoryPresetWarningsDocumented() throws {
        // Not a hard failure — warnings are acceptable — but we pin the
        // count so a sudden spike (e.g. a new rule suddenly firing on
        // every preset) surfaces in CI before shipping. Adjust the cap
        // deliberately when the rule surface changes.
        let urls = try Self.factoryBundleURLs()
        var warnTotal = 0
        var byCheck: [String: Int] = [:]
        for url in urls {
            guard let bundle = PresetBundle.load(from: url) else { continue }
            let report = BundleUIValidator.validate(bundle)
            for issue in report.issues where issue.severity == .warn {
                warnTotal += 1
                byCheck[issue.check, default: 0] += 1
            }
        }

        // Loose upper bound. Most factory presets have no UI and no
        // warnings; the ones that do are a handful of v1-schema + UI
        // combinations at worst. Any number significantly above this
        // means a new rule is firing broadly and should be reviewed.
        let cap = 50
        #expect(warnTotal <= cap,
                "factory preset warn count \(warnTotal) exceeds cap \(cap); breakdown: \(byCheck)")
    }
}
