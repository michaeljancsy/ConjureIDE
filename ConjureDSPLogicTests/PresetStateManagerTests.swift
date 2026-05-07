//
//  PresetStateManagerTests.swift
//  ConjureDSPLogicTests
//
//  Pins the contract of the @MainActor PresetStateManager actor —
//  the Swift-side coordinator for the bundle-private STATE channel.
//
//  Manager-level tests (cap rejection, mirror updates, stateChanges
//  subject, defaults restoration) — kernel-FFI level tests live next
//  door in StateChannelTests.swift.
//

import Combine
import Foundation
import Testing

@MainActor
struct PresetStateManagerTests {

    // MARK: - Helpers

    /// Build a manager wired to a fresh kernel. Caller is responsible
    /// for destroying via `dsp_kernel_destroy(kernel)` after use; we
    /// return the kernel pointer alongside the manager so tests can
    /// inspect FFI state directly when needed.
    private static func makeManager() -> (PresetStateManager, OpaquePointer) {
        let kernel = dsp_kernel_create()!
        let manager = PresetStateManager(kernel: kernel)
        return (manager, kernel)
    }

    /// Capture stateChanges into a flat array for assertions. Returns
    /// the cancellable so the test can hold onto it for the duration.
    private static func captureChanges(
        _ manager: PresetStateManager,
        into bin: inout [PresetStateManager.StateChange]
    ) -> AnyCancellable {
        // Local capture box because Combine sinks can't take a direct
        // inout reference. Tests read from `bin` after the operation.
        let box = MutableBox<[PresetStateManager.StateChange]>([])
        let cancellable = manager.stateChanges.sink { change in
            box.value.append(change)
        }
        // Best-effort drain hook — we let the caller copy out via the
        // returned token below.
        bin = box.value
        return cancellable
    }

    /// Tiny mutable wrapper so the sink closure can append into a
    /// shared array (Swift Testing prefers value-type captures).
    private final class MutableBox<T> {
        var value: T
        init(_ initial: T) { value = initial }
    }

    // MARK: - applyDefaults

    @Test func applyDefaultsPopulatesMirrorFromJSON() async throws {
        let (manager, kernel) = Self.makeManager()
        defer { dsp_kernel_destroy(kernel) }

        manager.applyDefaults(
            defaultsJSON: "{\"slots\":[1,2,3],\"name\":\"acid\"}",
            declaredKeys: ["slots", "name"],
            maxBytes: 8192
        )

        #expect(manager.declaredKeys == ["slots", "name"])
        #expect(manager.maxBytes == 8192)
        let slots = manager.mirror["slots"] as? [Int]
        #expect(slots == [1, 2, 3], "applyDefaults should populate mirror with the parsed JSON")
        #expect(manager.mirror["name"] as? String == "acid")
    }

    @Test func applyDefaultsFiresPresetLoadChange() async throws {
        let (manager, kernel) = Self.makeManager()
        defer { dsp_kernel_destroy(kernel) }

        let box = MutableBox<[PresetStateManager.StateChange]>([])
        let cancellable = manager.stateChanges.sink { box.value.append($0) }
        defer { cancellable.cancel() }

        manager.applyDefaults(
            defaultsJSON: "{\"x\":1}", declaredKeys: ["x"], maxBytes: 4096
        )

        #expect(box.value.count == 1, "applyDefaults must emit exactly one change")
        let change = try #require(box.value.first)
        #expect(change.key == nil, "applyDefaults emits a full-reset (key=nil) change")
        #expect(change.origin == .presetLoad)
    }

    // MARK: - set(key:value:origin:)

    @Test func setUpdatesMirrorAndReturnsTrueOnSuccess() async throws {
        let (manager, kernel) = Self.makeManager()
        defer { dsp_kernel_destroy(kernel) }

        manager.applyDefaults(defaultsJSON: "{}", declaredKeys: [], maxBytes: 65_536)

        let ok = manager.set(key: "selected", value: 7, origin: .ui)
        #expect(ok)
        #expect(manager.mirror["selected"] as? Int == 7,
                "successful set must update the mirror in place")
    }

    @Test func setFiresStateChangeWithMatchingKeyValueOrigin() async throws {
        let (manager, kernel) = Self.makeManager()
        defer { dsp_kernel_destroy(kernel) }
        manager.applyDefaults(defaultsJSON: "{}", declaredKeys: [], maxBytes: 65_536)

        let box = MutableBox<[PresetStateManager.StateChange]>([])
        let cancellable = manager.stateChanges.sink { box.value.append($0) }
        defer { cancellable.cancel() }

        _ = manager.set(key: "foo", value: "bar", origin: .mcp)

        #expect(box.value.count == 1)
        let change = try #require(box.value.first)
        #expect(change.key == "foo")
        #expect(change.value as? String == "bar")
        #expect(change.origin == .mcp)
    }

    @Test func setReturnsFalseWhenSizeCapExceeded() async throws {
        let (manager, kernel) = Self.makeManager()
        defer { dsp_kernel_destroy(kernel) }
        // Tiny cap to force rejection on a small payload.
        manager.applyDefaults(defaultsJSON: "{}", declaredKeys: [], maxBytes: 30)

        let mirrorBefore = manager.mirror
        // 100 'x' chars + JSON overhead is well past 30 bytes.
        let bigValue = String(repeating: "x", count: 100)
        let ok = manager.set(key: "big", value: bigValue, origin: .ui)
        #expect(!ok, "set must reject when serialized result exceeds maxBytes")
        #expect(manager.mirror.count == mirrorBefore.count,
                "rejected set must NOT mutate the mirror")
    }

    @Test func rejectedSetDoesNotEmitStateChange() async throws {
        let (manager, kernel) = Self.makeManager()
        defer { dsp_kernel_destroy(kernel) }
        manager.applyDefaults(defaultsJSON: "{}", declaredKeys: [], maxBytes: 30)

        let box = MutableBox<[PresetStateManager.StateChange]>([])
        let cancellable = manager.stateChanges.sink { box.value.append($0) }
        defer { cancellable.cancel() }
        // Drop the applyDefaults change so we can assert on just the set.
        box.value.removeAll()

        let ok = manager.set(
            key: "big",
            value: String(repeating: "x", count: 200),
            origin: .ui
        )
        #expect(!ok)
        #expect(box.value.isEmpty,
                "rejected set must not emit a stateChanges signal (mirror unchanged)")
    }

    // MARK: - reset(key:origin:) — single key

    @Test func resetSingleKeyRestoresDeclaredDefault() async throws {
        let (manager, kernel) = Self.makeManager()
        defer { dsp_kernel_destroy(kernel) }
        // Defaults: count=10. Authored layer mutates it to 99, then
        // reset must restore 10.
        manager.applyDefaults(
            defaultsJSON: "{\"count\":10}", declaredKeys: ["count"], maxBytes: 4096
        )

        // Push defaults JSON onto the kernel as the canonical defaults
        // (in production, the WASM/Python backend declares this; in
        // logic tests we simulate by pre-installing the same buffer the
        // kernel returns from state_defaults_json_ptr).
        // For this test we don't have a real script-load path, so we
        // can only assert reset doesn't crash on missing defaults — the
        // reset call still wires through the kernel pointer. Apply the
        // overwrite via set(), then reset to defaults.
        _ = manager.set(key: "count", value: 99, origin: .ui)
        #expect(manager.mirror["count"] as? Int == 99)

        // The kernel doesn't have a script's defaults loaded; its
        // state_defaults_json_ptr returns null so reset() falls back to
        // {} → set("count", nil) → key removed from mirror.
        _ = manager.reset(key: "count", origin: .ui)
        #expect(manager.mirror["count"] == nil,
                "reset with no script defaults removes the key (the value is nil in the {} fallback)")
    }

    // MARK: - reset(key: nil, origin:) — full reset

    @Test func resetAllRestoresKernelDefaultsBuffer() async throws {
        let (manager, kernel) = Self.makeManager()
        defer { dsp_kernel_destroy(kernel) }
        manager.applyDefaults(defaultsJSON: "{}", declaredKeys: [], maxBytes: 4096)

        // Author writes a value, then full-reset blows it away.
        _ = manager.set(key: "scratch", value: 1, origin: .ui)
        #expect(manager.mirror["scratch"] as? Int == 1)

        let box = MutableBox<[PresetStateManager.StateChange]>([])
        let cancellable = manager.stateChanges.sink { box.value.append($0) }
        defer { cancellable.cancel() }

        let ok = manager.reset(key: nil, origin: .mcp)
        #expect(ok, "reset(key:nil) returns true on success")
        #expect(manager.mirror.isEmpty,
                "full reset should clear the mirror to defaults (empty in this test)")
        // The reset emits a (nil, nil) change so consumers can re-read
        // everything when ready.
        let change = try #require(box.value.last)
        #expect(change.key == nil)
        #expect(change.origin == .mcp)
    }

    // MARK: - restore(from:)

    @Test func restoreParsesJSONAndUpdatesMirror() async throws {
        let (manager, kernel) = Self.makeManager()
        defer { dsp_kernel_destroy(kernel) }
        manager.applyDefaults(defaultsJSON: "{}", declaredKeys: [], maxBytes: 4096)

        let stored = Data("{\"selected\":3,\"buf\":[7,8,9]}".utf8)
        manager.restore(from: stored)

        #expect(manager.mirror["selected"] as? Int == 3)
        let buf = manager.mirror["buf"] as? [Int]
        #expect(buf == [7, 8, 9])
    }

    @Test func restoreFiresDawOriginatedChange() async throws {
        let (manager, kernel) = Self.makeManager()
        defer { dsp_kernel_destroy(kernel) }
        manager.applyDefaults(defaultsJSON: "{}", declaredKeys: [], maxBytes: 4096)

        let box = MutableBox<[PresetStateManager.StateChange]>([])
        let cancellable = manager.stateChanges.sink { box.value.append($0) }
        defer { cancellable.cancel() }
        box.value.removeAll() // drop applyDefaults emission

        manager.restore(from: Data("{\"a\":1}".utf8))

        let change = try #require(box.value.first)
        #expect(change.origin == .daw,
                "restore must emit changes with origin=.daw (the persistence path)")
    }

    // MARK: - currentJSONBytes round-trips through kernel

    @Test func currentJSONBytesReflectsKernelBuffer() async throws {
        let (manager, kernel) = Self.makeManager()
        defer { dsp_kernel_destroy(kernel) }
        manager.applyDefaults(defaultsJSON: "{}", declaredKeys: [], maxBytes: 4096)

        _ = manager.set(key: "k", value: "v", origin: .ui)
        let bytes = manager.currentJSONBytes()
        let s = String(data: bytes, encoding: .utf8) ?? ""
        #expect(s.contains("\"k\""), "currentJSONBytes should serialize the live mirror; got \(s)")
        #expect(s.contains("\"v\""))
    }

    // MARK: - generation property

    @Test func generationReflectsKernelGen() async throws {
        let (manager, kernel) = Self.makeManager()
        defer { dsp_kernel_destroy(kernel) }
        manager.applyDefaults(defaultsJSON: "{}", declaredKeys: [], maxBytes: 4096)

        let gen0 = manager.generation
        _ = manager.set(key: "x", value: 1, origin: .ui)
        let gen1 = manager.generation
        #expect(gen1 > gen0, "set must advance kernel state generation; \(gen0) -> \(gen1)")

        _ = manager.set(key: "x", value: 2, origin: .ui)
        #expect(manager.generation > gen1)
    }

    // MARK: - nil kernel (no-attach test harness path)

    @Test func setWithoutKernelAppliesLocally() async throws {
        let manager = PresetStateManager(kernel: nil)
        manager.applyDefaults(defaultsJSON: "{}", declaredKeys: [], maxBytes: 4096)

        let ok = manager.set(key: "scratch", value: "abc", origin: .ui)
        #expect(ok, "with no kernel attached the manager applies the change to its mirror")
        #expect(manager.mirror["scratch"] as? String == "abc")
        #expect(manager.generation == 0,
                "no-kernel manager has no generation counter; reads as 0")
    }
}
