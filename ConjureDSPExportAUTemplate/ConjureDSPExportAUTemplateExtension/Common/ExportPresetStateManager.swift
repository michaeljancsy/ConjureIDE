import Combine
import Foundation
import os

private let log = Logger(
    subsystem: "com.MichaelJancsy.ConjureDSP.ExportAU",
    category: "PresetState"
)

/// Coordinator for the bundle-private STATE channel in the exported AU.
///
/// Mirror of `ConjureDSPExtension/State/PresetStateManager.swift` — same
/// API surface, same semantics, different name so the export template's
/// separate Swift module doesn't fight a name collision when both files
/// happen to compile in the same project.
///
/// State lives in three places:
///   1. The Rust kernel's atomically-swapped JSON byte buffer (audio
///      thread reads), bumped via `dsp_kernel_set_state_json`.
///   2. This Swift mirror — a `[String: Any]` dictionary kept in sync
///      with the kernel's bytes so `_init` payloads and JS bridge writes
///      can operate on a structured view without parsing JSON every time.
///   3. The DAW project — restored via the AU's `fullState` /
///      `fullStateForDocument` setters at load time.
///
/// **No filesystem.** State is per-instance, per-DAW-project user data;
/// it never lives in the bundle directory. New instances start from the
/// script's `STATE = {…}` defaults; user edits diverge into the DAW's
/// per-instance state; reopening a project restores those edits.
///
/// `@MainActor` because every consumer (custom UI WKWebView, AU's
/// fullState getter/setter) runs on main. The kernel FFI is itself
/// thread-safe by atomic-swap; the actor isolation is purely to keep the
/// Swift mirror coherent.
@MainActor
final class ExportPresetStateManager {
    /// Subject fired whenever state changes via any path (set, reset,
    /// restore from fullState). Used by `ExportCustomUIWebView` to
    /// forward `_stateUpdate` to JS.
    let stateChanges = PassthroughSubject<StateChange, Never>()

    /// One declarative description of a state mutation. `key == nil`
    /// means a full reset (e.g. preset switch). The bridge consumes
    /// these to fire `_stateUpdate` per affected key.
    struct StateChange {
        let key: String?
        let value: Any?
        /// Originator token. `paramSet`-style: writes from the JS
        /// bridge are tagged so that the WebView coordinator can
        /// suppress its own `_stateUpdate` echo (the bridge already
        /// fired `onChange` synchronously inside `state.set`). Other
        /// origins (DAW load, preset load) propagate through.
        let origin: Origin
    }

    enum Origin: Equatable {
        case ui          // JS bridge `state.set` — suppress echo to that webview.
        case daw         // `fullState` / `fullStateForDocument` setter.
        case presetLoad  // Re-applying script defaults on script load.
    }

    /// Live mirror of the kernel's state. Values are JSON-decoded
    /// Foundation types (NSNumber / String / NSArray / NSDictionary /
    /// NSNull). Read-only from outside — mutations route through `set`
    /// / `reset` / `restore` so the kernel and stateChanges subject
    /// stay synchronized.
    private(set) var mirror: [String: Any] = [:]

    /// Names of every key the script declared in its STATE dict. Used
    /// by the validator to resolve `ConjureDSP.state.get/set` references.
    private(set) var declaredKeys: [String] = []

    /// Per-script byte cap, mirrored from the kernel for sync size
    /// checks in the JS bridge `_init` payload.
    private(set) var maxBytes: Int = 65_536

    private let kernel: OpaquePointer?

    init(kernel: OpaquePointer?) {
        self.kernel = kernel
    }

    // MARK: - Script load

    /// Apply the script's declared STATE defaults at script load.
    ///
    /// `defaultsJSON` is the Python `STATE = {…}` dict serialized to
    /// JSON; pass `"{}"` for WASM presets (their defaults flow
    /// through the deserializer's `T::default()` impl). `declaredKeys`
    /// is the set of top-level keys the script declared.
    ///
    /// Resets the kernel's state buffer, the Swift mirror, and bumps
    /// the generation counter so backends re-deserialize on the next
    /// callback.
    func applyDefaults(
        defaultsJSON: String,
        declaredKeys: [String],
        maxBytes: Int
    ) {
        self.declaredKeys = declaredKeys
        self.maxBytes = maxBytes
        // Push cap into the kernel first — set_state_json checks against
        // the cap, so applying a fresh defaults blob with a stale cap
        // could spuriously reject.
        if let kernel {
            dsp_kernel_set_state_cap(kernel, UInt(maxBytes))
        }
        // Decode the defaults into our mirror via JSONSerialization (no
        // type checking — we trust the Python backend's serialization).
        if let data = defaultsJSON.data(using: .utf8),
           let dict = (try? JSONSerialization.jsonObject(with: data, options: []))
            as? [String: Any] {
            mirror = dict
        } else {
            mirror = [:]
        }
        // Push to kernel so the audio thread's snapshot_state observes
        // the defaults on its very first callback.
        pushMirrorToKernel()
        stateChanges.send(StateChange(key: nil, value: nil, origin: .presetLoad))
    }

    // MARK: - UI write path

    /// Update a single state key. Returns `true` on success, `false`
    /// when the resulting buffer would exceed the per-script cap (in
    /// which case the mirror + kernel are unchanged).
    @discardableResult
    func set(key: String, value: Any?, origin: Origin) -> Bool {
        var newMirror = mirror
        if value == nil || value is NSNull {
            newMirror.removeValue(forKey: key)
        } else {
            newMirror[key] = value
        }
        guard let bytes = jsonBytes(newMirror) else {
            log.error("ExportPresetStateManager: failed to serialize state mirror")
            return false
        }
        guard bytes.count <= maxBytes else {
            log.error(
                "ExportPresetStateManager: state size \(bytes.count) exceeds cap \(self.maxBytes, privacy: .public)"
            )
            return false
        }
        guard let kernel else {
            // No kernel attached (test harness). Apply locally.
            mirror = newMirror
            stateChanges.send(StateChange(key: key, value: value, origin: origin))
            return true
        }
        let ok = bytes.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return dsp_kernel_set_state_json(kernel, base.assumingMemoryBound(to: UInt8.self), UInt(bytes.count))
        }
        if !ok {
            log.error("ExportPresetStateManager: kernel rejected state write (cap or JSON)")
            return false
        }
        mirror = newMirror
        stateChanges.send(StateChange(key: key, value: value, origin: origin))
        return true
    }

    /// Reset a single key (or the whole mirror when `key == nil`) back
    /// to the script's declared defaults. The defaults dict is
    /// re-fetched from the kernel each call so this is robust against
    /// preset switches.
    @discardableResult
    func reset(key: String?, origin: Origin) -> Bool {
        guard let kernel else { return false }
        let defaultsJSON = readDefaultsJSON(kernel: kernel) ?? "{}"
        let defaultsDict = (try? JSONSerialization.jsonObject(
            with: Data(defaultsJSON.utf8),
            options: []
        )) as? [String: Any] ?? [:]
        if let key {
            return set(key: key, value: defaultsDict[key], origin: origin)
        }
        // Full reset — push defaults to kernel + mirror.
        var bytes = Data(defaultsJSON.utf8)
        if bytes.count > maxBytes {
            // Should never happen — defaults are authored by us — but
            // guard anyway so a misconfigured script can't wedge state.
            bytes = Data("{}".utf8)
        }
        let ok = bytes.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return dsp_kernel_set_state_json(kernel, base.assumingMemoryBound(to: UInt8.self), UInt(bytes.count))
        }
        if !ok { return false }
        mirror = defaultsDict
        stateChanges.send(StateChange(key: nil, value: nil, origin: origin))
        return true
    }

    // MARK: - DAW persistence

    /// Returns the current state buffer as raw bytes. Used by the AU's
    /// `fullState` / `fullStateForDocument` getters to embed
    /// `conjuredsp_state` in the host-saved dict.
    func currentJSONBytes() -> Data {
        guard let kernel else { return jsonBytes(mirror) ?? Data("{}".utf8) }
        // Query the kernel for the canonical bytes (the Swift mirror is
        // a parsed view that may diverge if a JSON write took a path we
        // didn't observe — defensive).
        let needed = Int(dsp_kernel_get_state_json(kernel, nil, 0))
        guard needed > 0 else { return Data("{}".utf8) }
        var buffer = Data(count: needed)
        let written = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return Int(dsp_kernel_get_state_json(kernel, base.assumingMemoryBound(to: UInt8.self), UInt(needed)))
        }
        if written < buffer.count {
            buffer = buffer.prefix(written)
        }
        return buffer
    }

    /// Restore state from raw bytes pulled out of `fullState` /
    /// `fullStateForDocument`. On parse failure the mirror falls back
    /// to the script's defaults (don't abort the load — better partial
    /// state than no preset).
    func restore(from bytes: Data) {
        guard let kernel else { return }
        let ok = bytes.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return dsp_kernel_set_state_json(kernel, base.assumingMemoryBound(to: UInt8.self), UInt(bytes.count))
        }
        if !ok {
            log.warning(
                "ExportPresetStateManager.restore: kernel rejected stored state (\(bytes.count) bytes); falling back to script defaults"
            )
            // Reset to script defaults so the audio thread doesn't keep
            // reading whatever stale buffer was there before.
            _ = reset(key: nil, origin: .daw)
            return
        }
        // Re-parse into the mirror.
        if let dict = (try? JSONSerialization.jsonObject(with: bytes, options: []))
            as? [String: Any] {
            mirror = dict
        }
        stateChanges.send(StateChange(key: nil, value: nil, origin: .daw))
    }

    // MARK: - Read accessors

    /// Snapshot of the current state for inclusion in the JS bridge's
    /// `_init` payload.
    func snapshotForInit() -> [String: Any] {
        mirror
    }

    /// Current state generation. Used by tests to verify a write
    /// actually advanced the kernel.
    var generation: UInt64 {
        guard let kernel else { return 0 }
        return dsp_kernel_state_generation(kernel)
    }

    // MARK: - Private

    private func pushMirrorToKernel() {
        guard let kernel else { return }
        guard let bytes = jsonBytes(mirror) else { return }
        let _ = bytes.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return dsp_kernel_set_state_json(kernel, base.assumingMemoryBound(to: UInt8.self), UInt(bytes.count))
        }
    }

    private func jsonBytes(_ dict: [String: Any]) -> Data? {
        // sortedKeys for stable ordering — makes snapshot diffs
        // deterministic and avoids spurious generation bumps when an
        // identical mutation re-serializes in a different order.
        try? JSONSerialization.data(
            withJSONObject: dict,
            options: [.sortedKeys]
        )
    }

    private func readDefaultsJSON(kernel: OpaquePointer) -> String? {
        guard let cstr = dsp_kernel_state_defaults_json(kernel) else { return nil }
        return String(cString: cstr)
    }
}
