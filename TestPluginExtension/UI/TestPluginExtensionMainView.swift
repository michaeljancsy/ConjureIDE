//
//  TestPluginExtensionMainView.swift
//  TestPluginExtension
//
//  Created by Michael Jancsy on 2/25/26.
//

import SwiftUI

struct TestPluginExtensionMainView: View {
    var parameterTree: ObservableAUParameterGroup
    
    var body: some View {
        ParameterSlider(param: parameterTree.global.gain)
    }
}
