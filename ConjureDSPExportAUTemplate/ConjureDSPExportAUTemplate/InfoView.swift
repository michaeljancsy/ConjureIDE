//
//  InfoView.swift
//  ConjureDSPExportAUTemplate
//

import SwiftUI

struct InfoView: View {
    private let auInfo: AUInfo

    init() {
        auInfo = AUInfo.discover() ?? AUInfo.placeholder
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(auInfo.name)
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 8) {
                InfoRow(label: "Type", value: "Audio Effect (aufx)")
                InfoRow(label: "Subtype", value: auInfo.subtype)
                InfoRow(label: "Manufacturer", value: auInfo.manufacturer)
                InfoRow(label: "Version", value: "\(auInfo.version)")
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 8).fill(.background.secondary))

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("This audio effect is registered and available in your DAW.")
                    .font(.callout)

                Text("How to find it:")
                    .font(.caption.bold())
                    .padding(.top, 4)

                Text("Logic Pro: Channel strip > Audio FX slot > Audio Units > CONJ")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Ableton Live: Audio Effects > Audio Units > CONJ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(24)
        .frame(minWidth: 350, minHeight: 280)
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospaced()
        }
    }
}
