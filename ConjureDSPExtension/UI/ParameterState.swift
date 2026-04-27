//
//  ParameterState.swift
//  ConjureDSPExtension
//
//  Created by Michael Jancsy on 3/4/26.
//

import AudioToolbox
import Combine
import Foundation
import os
import SwiftUI

/// See CustomUIWebView.swift for the same `ParamFlow` category. Dedicated
/// logger so the parameter-flow trace can be filtered cleanly in Console.
private let paramFlow = Logger(
    subsystem: "com.MichaelJancsy.ConjureDSP.ConjureDSPExtension",
    category: "ParamFlow"
)

/// Bridges AUParameterTree ↔ SwiftUI with bidirectional sync.
///
/// All UI-originating parameter changes go through `AUParameter.value` setter,
/// which triggers the existing `implementorValueObserver` → `dsp_kernel_set_parameter()`
/// codepath — the same path DAW automation uses.
@MainActor
final class ParameterState: ObservableObject {
    @Published var values: [Float]
    /// Script-declared parameter names, keyed by address (0–15).
    /// nil = no names declared (show all params with default labels).
    @Published var paramNames: [Int: String]? = nil
    /// Rich parameter metadata from `PARAMS` dict. When present, sliders
    /// use actual ranges and values are displayed with units.
    @Published var paramMetadata: [ConjureDSPExtensionAudioUnit.ParamMetadata]? = nil

    /// Fires ONLY when a parameter changes from an external source —
    /// DAW automation, MIDI learn, preset load, MCP write, etc. Does
    /// NOT fire for UI-originated writes through `binding(for:)`.
    ///
    /// This is the subscription surface for clients that need to react
    /// to external changes without getting flooded by their own UI
    /// writes echoing back. The custom-UI WKWebView uses this so
    /// slider drags from HTML don't fight themselves: the user's own
    /// `CDP.parameters.set()` calls never come back as
    /// `_paramUpdate` callbacks, so `rng.value = v` never yanks the
    /// thumb mid-drag.
    ///
    /// Subscribing to `$values` instead would see BOTH UI and external
    /// changes, which is correct for SwiftUI bindings (they need to
    /// re-render on any change) but wrong for the HTML bridge.
    let externalValueChange = PassthroughSubject<(index: Int, value: Float), Never>()

    private var parameterTree: AUParameterTree?
    /// Observer token used both as the callback handle for external
    /// changes AND as the originator for UI-initiated writes. AU's
    /// `setValue(_:originator:)` excludes the originator from its own
    /// observer callback, so UI writes don't re-enter this observer.
    /// The binding setter reads this to tag its writes correctly.
    internal private(set) var observerToken: AUParameterObserverToken?

    init() {
        self.values = Array(repeating: 0.0, count: ConjureDSPExtensionAudioUnit.paramCount)
    }

    func attach(to parameterTree: AUParameterTree) {
        detach()

        self.parameterTree = parameterTree
        let paramCount = ConjureDSPExtensionAudioUnit.paramCount

        // Resize values array to match current param count
        if values.count != paramCount {
            values = Array(repeating: 0.0, count: paramCount)
        }

        // Read current values from the tree
        for i in 0..<paramCount {
            if let param = parameterTree.parameter(withAddress: AUParameterAddress(i)) {
                values[i] = param.value
            }
        }

        // Observe parameter changes. Because `binding(for:)` writes with
        // this same token as originator, this observer ONLY fires for
        // EXTERNAL changes — DAW automation, MIDI, MCP writes, etc. UI
        // writes are excluded by AU's originator contract.
        //
        // Callback may fire on an arbitrary thread, so dispatch to main
        // both to update `values` (for SwiftUI) and to fire
        // `externalValueChange` (for the HTML bridge).
        observerToken = parameterTree.token(byAddingParameterObserver: { [weak self] address, value in
            guard Int(address) < paramCount else { return }
            // Observer fires on an arbitrary thread; log BEFORE hopping
            // to main so we capture the raw event even if main is busy.
            // paramFlow.notice("[7a.swift.observer] idx=\(Int(address), privacy: .public) v=\(value, privacy: .public)")
            DispatchQueue.main.async {
                guard let self else { return }
                self.values[Int(address)] = value
                self.externalValueChange.send((index: Int(address), value: value))
            }
        })
    }

    func detach() {
        if let token = observerToken, let tree = parameterTree {
            tree.removeParameterObserver(token)
        }
        observerToken = nil
        parameterTree = nil
    }

    /// Creates a binding for a specific parameter index.
    /// The setter writes through `AUParameter.setValue(_:originator:)`
    /// with our own `observerToken` as originator. That triggers
    /// `implementorValueObserver` → `dsp_kernel_set_parameter()` as
    /// usual, but AU's contract excludes the originator token from
    /// receiving the parameter-observer callback — so our observer
    /// (registered via `token(byAddingParameterObserver:)`) does NOT
    /// fire for UI-originated writes.
    ///
    /// Why this matters: the observer's callback does
    /// `self.values[idx] = value` on main.async. For rapid UI drags,
    /// each `param.value = X` would queue one such async write per set.
    /// Those stale writes re-publish `$values` after the user has
    /// already moved on, causing Swift to echo old values back to the
    /// custom UI webview, which then writes `rng.value = staleValue`
    /// and jerks the slider thumb mid-drag. Excluding ourselves via
    /// the originator kills that feedback loop at the source.
    func binding(for index: Int) -> Binding<Float> {
        Binding<Float>(
            get: {
                // Bounds-check on read too — custom-UI JS can call
                // `parameters.get(i)` with any integer and we shouldn't
                // crash the appex on a misbehaving UI. Returning 0 is a
                // safe neutral value across every unit we ship.
                guard index >= 0, index < self.values.count else { return 0 }
                return self.values[index]
            },
            set: { newValue in
                // Custom-UI JS (and MCP set_parameter) route through
                // this setter with indices we don't fully control, so
                // guard before the array write. `paramCount` is 16 but
                // `values.count` is authoritative.
                guard index >= 0, index < self.values.count else { return }
                self.values[index] = newValue
                if let param = self.parameterTree?.parameter(
                    withAddress: AUParameterAddress(index)
                ) {
                    if let token = self.observerToken {
                        param.setValue(newValue, originator: token)
                    } else {
                        // No observer installed yet — fall back to the
                        // direct setter. Kernel still gets the write via
                        // implementorValueObserver regardless.
                        param.value = newValue
                    }
                }
            }
        )
    }
}
