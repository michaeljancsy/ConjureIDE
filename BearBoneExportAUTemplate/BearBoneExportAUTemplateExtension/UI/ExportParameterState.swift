//
//  ExportParameterState.swift
//  BearBoneExportAUTemplateExtension
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
    let paramCount: Int

    private var parameterTree: AUParameterTree?
    private var observerToken: AUParameterObserverToken?

    init(paramCount: Int = 8) {
        self.paramCount = paramCount
        self.values = Array(repeating: 0.0, count: paramCount)
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
            guard address < count else { return }
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
}
