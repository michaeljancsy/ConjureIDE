//
//  ContentView.swift
//  TestPlugin
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
        VStack() {
            VStack {
                if hostModel.audioUnitCrashed {
                    HStack(spacing: 2) {
                        Text("(\(hostModel.viewModel.title))")
                            .textSelection(.enabled)
                        Text("crashed!")
                    }
                    ValidationView(hostModel: hostModel, isSheetPresented: $isSheetPresented)
                } else {
                    VStack {
                        Text("\(hostModel.viewModel.title)")
                            .textSelection(.enabled)
                            .bold()
                        ValidationView(hostModel: hostModel, isSheetPresented: $isSheetPresented)
                        if let viewController = hostModel.viewModel.viewController {
                            AUViewControllerUI(viewController: viewController)
                                .padding(margin)
                        } else {
                            Text(hostModel.viewModel.message)
                                .frame(minWidth: 400, minHeight: 200)
                        }
                    }
                }
            }
            .padding(doubleMargin)
            
            if hostModel.viewModel.showAudioControls {
                Text("Audio Playback")
                Button {
                    hostModel.isPlaying ? hostModel.stopPlaying() : hostModel.startPlaying()
                    
                } label: {
                    Text(hostModel.isPlaying ? "Stop" : "Play")
                }
            }
            if hostModel.viewModel.showMIDIContols {
                Text("MIDI Input: Enabled")
            }
            Spacer()
                .frame(height: margin)
        }
    }
}

#Preview {
    ContentView(hostModel: AudioUnitHostModel())
}
