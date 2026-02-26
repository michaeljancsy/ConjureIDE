//
//  ParameterSlider.swift
//  TestPluginExtension
//
//  Created by Michael Jancsy on 2/25/26.
//

import SwiftUI
import AudioToolbox

/// A SwiftUI Slider container which is bound to an ObservableAUParameter
///
/// This view wraps a SwiftUI Slider, and provides it relevant data from the Parameter, like the minimum and maximum values.
struct ParameterSlider: View {
    @State var param: ObservableAUParameter
    
    var specifier: String {
        switch param.unit {
        case .midiNoteNumber:
            return "%.0f"
        default:
            return "%.2f"
        }
    }
    
    var body: some View {
        VStack {
            Slider(
                value: $param.value,
                in: param.min...param.max,
                onEditingChanged: param.onEditingChanged,
                minimumValueLabel: Text("\(param.min, specifier: specifier)"),
                maximumValueLabel: Text("\(param.max, specifier: specifier)")
            ) {
                EmptyView()
            }
            .accessibility(identifier: param.displayName)
            Text("\(param.displayName): \(param.value, specifier: specifier)")
        }
        .padding()
    }
}
