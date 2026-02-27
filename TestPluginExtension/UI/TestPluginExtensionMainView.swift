//
//  TestPluginExtensionMainView.swift
//  TestPluginExtension
//
//  Created by Michael Jancsy on 2/25/26.
//

import SwiftUI

struct TestPluginExtensionMainView: View {
    var defaultScriptSource: String
    var onSaveScript: (String) -> (Bool, String?)

    @State private var scriptSource: String = ""
    @State private var errorMessage: String?
    @State private var showSuccess: Bool = false

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Python DSP Script [build 0227a]")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 8)

            TextEditor(text: $scriptSource)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .border(Color.secondary.opacity(0.3), width: 1)
                .padding(.horizontal)
                .accessibilityIdentifier("scriptEditor")

            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
                    .padding(.horizontal)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if showSuccess {
                Text("Script reloaded successfully")
                    .foregroundColor(.green)
                    .font(.caption)
                    .padding(.horizontal)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button("Save Changes") {
                let result = onSaveScript(scriptSource)
                if result.0 {
                    errorMessage = nil
                    showSuccess = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        showSuccess = false
                    }
                } else {
                    showSuccess = false
                    errorMessage = result.1 ?? "Unknown error"
                }
            }
            .accessibilityIdentifier("saveChangesButton")
            .padding(.bottom)
        }
        .onAppear {
            scriptSource = defaultScriptSource
        }
    }
}
