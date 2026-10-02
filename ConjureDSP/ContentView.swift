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
        let status = hostModel.playbackStatus
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
                if let notice = status.notice {
                    PlaybackNoticeView(notice: notice, onReload: hostModel.reloadAudioUnit)
                        .frame(minWidth: 600, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
                }
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
                if !hostModel.audioUnitCrashed, let notice = status.notice {
                    PlaybackNoticeView(notice: notice, onReload: hostModel.reloadAudioUnit)
                }
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
                    .accessibilityIdentifier("audioSourceMenu")
                    Spacer()
                    Button {
                        hostModel.isPlaying ? hostModel.stopPlaying() : hostModel.startPlaying()
                    } label: {
                        Text(hostModel.isPlaying ? "Stop" : "Play")
                    }
                }
                .disabled(!status.controlsEnabled)
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

/// A message about the plugin or playback, with the full error text on
/// request and, when the plugin has stopped, a button to load it again.
private struct PlaybackNoticeView: View {
    let notice: PlaybackStatus.Notice
    let onReload: () -> Void
    @State private var showingDetail = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(notice.message)
                if notice.detail != nil {
                    Button(showingDetail ? "Hide Details" : "More Info") {
                        showingDetail.toggle()
                    }
                    .buttonStyle(.link)
                }
                if notice.offersReload {
                    Button("Reload Plugin", action: onReload)
                        .accessibilityIdentifier("reloadPluginButton")
                }
            }
            if showingDetail, let detail = notice.detail {
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
    }
}

#Preview {
    ContentView(hostModel: AudioUnitHostModel())
}
