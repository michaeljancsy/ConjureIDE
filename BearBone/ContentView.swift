//
//  ContentView.swift
//  BearBone
//
//  Created by Michael Jancsy on 2/25/26.
//

import AudioToolbox
import SwiftUI

struct ContentView: View {
    let hostModel: AudioUnitHostModel
    @State private var isSheetPresented = false
    
    var margin = 10.0
    var doubleMargin: Double {
        margin * 2.0
    }
    
    var body: some View {
        VStack(spacing: 0) {
            if hostModel.audioUnitCrashed {
                HStack(spacing: 2) {
                    Text("(\(hostModel.viewModel.title))")
                        .textSelection(.enabled)
                    Text("crashed!")
                }
                .padding(.top, margin)
                ValidationView(hostModel: hostModel, isSheetPresented: $isSheetPresented)
            } else {
                HStack(spacing: 8) {
                    Text("\(hostModel.viewModel.title)")
                        .textSelection(.enabled)
                        .bold()
                    ValidationView(hostModel: hostModel, isSheetPresented: $isSheetPresented)
                }
                .padding(.vertical, 4)

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
    }
}

#Preview {
    ContentView(hostModel: AudioUnitHostModel())
}
