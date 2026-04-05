//
//  ExportParameterState.swift
//  ConjureDSPExportAUTemplateExtension
//

import AudioToolbox
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

    private var parameterTree: AUParameterTree?
    private var observerToken: AUParameterObserverToken?

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

        // Observe changes from ANY source (DAW automation, MIDI learn, etc.)
        let count = paramCount
        observerToken = parameterTree.token(byAddingParameterObserver: { [weak self] address, value in
            guard Int(address) < count else { return }
            DispatchQueue.main.async {
                self?.values[Int(address)] = value
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
    /// The setter writes through `AUParameter.value`, which triggers
    /// `implementorValueObserver` → `dsp_kernel_set_parameter()`.
    func binding(for index: Int) -> Binding<Float> {
        Binding<Float>(
            get: { self.values[index] },
            set: { newValue in
                self.values[index] = newValue
                if let param = self.parameterTree?.parameter(
                    withAddress: AUParameterAddress(index)
                ) {
                    param.value = newValue
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
