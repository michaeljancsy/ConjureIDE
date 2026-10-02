//
//  PlaybackStatus.swift
//  ConjureDSP
//
//  What the host window shows about the plugin and playback, derived from
//  two facts the host model tracks: whether the plugin's process has stopped,
//  and the error from the last failed attempt to start audio. Free of SwiftUI
//  and AVFoundation so the logic tests cover it directly.
//

import Foundation

struct PlaybackStatus: Equatable {
    struct Notice: Equatable {
        let message: String
        /// Full error text, shown on request.
        let detail: String?
        /// Whether the notice carries a "Reload Plugin" button.
        let offersReload: Bool
    }

    /// Play/Stop and the audio source menu. Off while the plugin is gone:
    /// starting the engine with the dead plugin in the graph fails.
    let controlsEnabled: Bool
    let notice: Notice?

    init(pluginStopped: Bool, startError: String?) {
        if pluginStopped {
            controlsEnabled = false
            notice = Notice(message: "The plugin stopped unexpectedly.", detail: nil, offersReload: true)
        } else if let startError {
            controlsEnabled = true
            notice = Notice(message: "Playback couldn't start.", detail: startError, offersReload: false)
        } else {
            controlsEnabled = true
            notice = nil
        }
    }
}
