//
//  ParameterState.swift
//  BearBoneExtension
//
//  Created by Michael Jancsy on 3/4/26.
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
final class ParameterState: ObservableObject {
    @Published var values: [Float]

    private var parameterTree: AUParameterTree?
    private var observerToken: AUParameterObserverToken?

    init() {
        self.values = Array(repeating: 0.0, count: 8)
    }

    func attach(to parameterTree: AUParameterTree) {
        detach()

        self.parameterTree = parameterTree

        // Read current values from the tree
        for i in 0..<8 {
            if let param = parameterTree.parameter(withAddress: AUParameterAddress(i)) {
                values[i] = param.value
            }
        }

        // Observe changes from ANY source (DAW automation, MIDI learn, etc.)
        // The callback fires on an arbitrary thread, so dispatch to main for SwiftUI.
        observerToken = parameterTree.token(byAddingParameterObserver: { [weak self] address, value in
            guard address < 8 else { return }
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
