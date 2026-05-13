//
//  ContentView.swift
//  ConjureDSP
//
//  Created by Michael Jancsy on 2/25/26.
//

import AudioToolbox
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    let hostModel: AudioUnitHostModel
    @State private var showFilePicker = false
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
                        .frame(minWidth: 600, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
                } else {
                    Text(hostModel.viewModel.message)
                        .frame(minWidth: 600, minHeight: 200)
                }
            }

            if hostModel.viewModel.showAudioControls {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(BuiltInAudioSource.allCases) { source in
                            Button(source.displayName) {
                                hostModel.selectBuiltIn(source)
                            }
                        }
                        if case .external(let url) = hostModel.audioSource {
                            Divider()
                            Button(url.lastPathComponent) {}
                                .disabled(true)
                        }
                        Divider()
                        Button("Other\u{2026}") {
                            showFilePicker = true
                        }
                    } label: {
                        Text(hostModel.audioSource.displayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button {
                        hostModel.isPlaying ? hostModel.stopPlaying() : hostModel.startPlaying()
                    } label: {
                        Text(hostModel.isPlaying ? "Stop" : "Play")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .fileImporter(
                    isPresented: $showFilePicker,
                    allowedContentTypes: [.audio],
                    allowsMultipleSelection: false
                ) { result in
                    if case .success(let urls) = result, let url = urls.first {
                        hostModel.selectExternalFile(url)
                    }
                }
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
