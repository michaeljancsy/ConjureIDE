//
//  PythonRuntimeErrorView.swift
//  ConjureDSPExportAUTemplateExtension
//

import SwiftUI

struct PythonRuntimeErrorView: View {
    let presetName: String?

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.yellow)

            Text("Python Runtime Not Found")
                .font(.headline)

            if let name = presetName {
                Text("\"\(name)\" requires the ConjureDSP Python runtime to process audio.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Text("Launch ConjureDSP once to install the runtime, then reopen your DAW project.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()

            Text("Made with ConjureDSP")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
        }
        .padding(.horizontal, 24)
    }
}
