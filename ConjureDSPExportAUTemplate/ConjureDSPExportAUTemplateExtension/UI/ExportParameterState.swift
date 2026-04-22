//
//  ExportParameterState.swift
//  ConjureDSPExportAUTemplateExtension
//

import AudioToolbox
import Combine
import Foundation
import SwiftUI

/// Bridges AUParameterTree ↔ SwiftUI with bidirectional sync.
///
/// All UI-originating parameter changes go through `AUParameter.value` setter,
/// which triggers the existing `implementorValueObserver` → `dsp_kernel_set_parameter()`
/// codepath — the same path DAW automation uses.
@MainActor
final class ExportParameterState: ObservableObject {
    @Published var values: [Float]
    @Published var runtimeError: String?
    /// Latest render-stats snapshot, refreshed by the 1 Hz poll timer in
    /// ExportAUViewController.
    @Published var statsSnapshot: RenderStats.Snapshot = .empty
    let paramCount: Int
    /// Rich parameter metadata for slider ranges and value formatting.
    let paramMetadata: [ExportParamMetadata]?
    /// Debug log owned by the AU. Passed through to the debug pane.
    let debugLog: ExportDebugLog
    /// Render stats owned by the AU. Polled at 1 Hz for stats snapshots.
    let renderStats: RenderStats
    /// Static plugin identity snapshot. Passed through to the debug pane.
    let pluginInfo: PluginInfo

    /// Fires ONLY when a parameter changes from an external source (DAW
    /// automation, MIDI, preset load) — not when the UI writes via
    /// `binding(for:)`. The custom-UI webview subscribes to this so
    /// user-initiated slider drags don't echo back and fight themselves.
    /// See ConjureDSPExtension/UI/ParameterState.swift for the full
    /// rationale.
    let externalValueChange = PassthroughSubject<(index: Int, value: Float), Never>()

    private var parameterTree: AUParameterTree?
    internal private(set) var observerToken: AUParameterObserverToken?

    init(
        paramCount: Int = 8,
        paramMetadata: [ExportParamMetadata]? = nil,
        debugLog: ExportDebugLog,
        renderStats: RenderStats,
        pluginInfo: PluginInfo
    ) {
        self.paramCount = paramCount
        self.paramMetadata = paramMetadata
        self.values = Array(repeating: 0.0, count: paramCount)
        self.debugLog = debugLog
        self.renderStats = renderStats
        self.pluginInfo = pluginInfo
    }

    func attach(to parameterTree: AUParameterTree) {
        detach()

        self.parameterTree = parameterTree

        // Read current values from the tree
        for i in 0..<paramCount {
            if let param = parameterTree.parameter(withAddress: AUParameterAddress(i)) {
                values[i] = param.value
            }
        }

        // Observer fires ONLY for EXTERNAL changes because `binding(for:)`
        // writes with this same token as originator — AU excludes the
        // originator from its own callback. DAW automation / MIDI land
        // here; UI writes don't.
        let count = paramCount
        observerToken = parameterTree.token(byAddingParameterObserver: { [weak self] address, value in
            guard Int(address) < count else { return }
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
    /// Uses `setValue(_:originator:)` with our observer token so UI
    /// writes don't re-fire our observer (and consequently don't echo
    /// back into the custom-UI webview). Kernel still gets the write
    /// via `implementorValueObserver`.
    func binding(for index: Int) -> Binding<Float> {
        Binding<Float>(
            get: {
                // Bounds-check: custom-UI JS (`parameters.get(i)`) can
                // pass any integer. Don't crash the exported appex on a
                // misbehaving UI.
                guard index >= 0, index < self.values.count else { return 0 }
                return self.values[index]
            },
            set: { newValue in
                guard index >= 0, index < self.values.count else { return }
                self.values[index] = newValue
                if let param = self.parameterTree?.parameter(
                    withAddress: AUParameterAddress(index)
                ) {
                    if let token = self.observerToken {
                        param.setValue(newValue, originator: token)
                    } else {
                        param.value = newValue
                    }
                }
            }
        )
    }

    /// Metadata for a specific parameter (nil for legacy 0–1 params).
    func metadata(for index: Int) -> ExportParamMetadata? {
        guard let meta = paramMetadata, index < meta.count else { return nil }
        return meta[index]
    }
}
