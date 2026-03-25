//
//  ContentView.swift
//  ConjureDSP
//
//  Created by Michael Jancsy on 2/25/26.
//

import AudioToolbox
import SwiftUI

struct ContentView: View {
    let hostModel: AudioUnitHostModel
    @ObservedObject var exportHandler: PendingExportHandler
    #if DEBUG
    @State private var isSheetPresented = false
    #endif
    
    var margin = 10.0
    var doubleMargin: Double {
        margin * 2.0
    }
    
    var body: some View {
        VStack(spacing: 0) {
            if hostModel.audioUnitCrashed {
                #if DEBUG
                HStack(spacing: 2) {
                    Text("(\(hostModel.viewModel.title))")
                        .textSelection(.enabled)
                    Text("crashed!")
                }
                .padding(.top, margin)
                ValidationView(hostModel: hostModel, isSheetPresented: $isSheetPresented)
                #endif
            } else {
                #if DEBUG
                HStack(spacing: 8) {
                    Text("\(hostModel.viewModel.title)")
                        .textSelection(.enabled)
                        .bold()
                    ValidationView(hostModel: hostModel, isSheetPresented: $isSheetPresented)
                }
                .padding(.vertical, 4)
                #endif

                if let viewController = hostModel.viewModel.viewController {
                    AUViewControllerUI(viewController: viewController)
                        .frame(minWidth: 400, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
                } else {
                    Text(hostModel.viewModel.message)
                        .frame(minWidth: 400, minHeight: 200)
                }
            }

            if hostModel.viewModel.showAudioControls {
                HStack(spacing: 8) {
                    Text("Audio Playback")
                    Button {
                        hostModel.isPlaying ? hostModel.stopPlaying() : hostModel.startPlaying()
                    } label: {
                        Text(hostModel.isPlaying ? "Stop" : "Play")
                    }
                }
                .padding(.vertical, 4)
            }
            if hostModel.viewModel.showMIDIContols {
                Text("MIDI Input: Enabled")
                    .padding(.vertical, 4)
            }
        }
        .alert("Export Installed", isPresented: .init(
            get: { exportHandler.installedExportName != nil },
            set: { if !$0 { exportHandler.installedExportName = nil } }
        )) {
            Button("OK") { exportHandler.installedExportName = nil }
        } message: {
            Text("Installed \"\(exportHandler.installedExportName ?? "")\". Launch the app once to register, then find it in your DAW.")
        }
        .alert("Export Error", isPresented: .init(
            get: { exportHandler.installError != nil },
            set: { if !$0 { exportHandler.installError = nil } }
        )) {
            Button("OK") { exportHandler.installError = nil }
        } message: {
            Text(exportHandler.installError ?? "")
        }
    }
}

#Preview {
    ContentView(hostModel: AudioUnitHostModel(), exportHandler: PendingExportHandler())
}
