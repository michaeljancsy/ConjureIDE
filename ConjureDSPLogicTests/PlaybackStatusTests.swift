//
//  PlaybackStatusTests.swift
//  ConjureDSPLogicTests
//
//  What the host window shows when the plugin's process stops or audio fails
//  to start. Guards CONJUREDSP-6H: the plugin process died, the window still
//  offered Play, and starting the engine with the dead plugin in the graph
//  hit a fatalError.
//

import Testing

@Suite struct PlaybackStatusTests {

    @Test func normalStateEnablesControlsWithNoNotice() {
        let status = PlaybackStatus(pluginStopped: false, startError: nil)
        #expect(status.controlsEnabled)
        #expect(status.notice == nil)
    }

    @Test func stoppedPluginDisablesControlsAndOffersReload() {
        let status = PlaybackStatus(pluginStopped: true, startError: nil)
        #expect(!status.controlsEnabled)
        #expect(status.notice?.offersReload == true)
    }

    @Test func startFailureKeepsControlsAndCarriesTheRealError() {
        let error = "Error Domain=com.apple.coreaudio.avfaudio Code=-10868 \"(null)\""
        let status = PlaybackStatus(pluginStopped: false, startError: error)
        #expect(status.controlsEnabled)
        #expect(status.notice?.detail == error)
        #expect(status.notice?.offersReload == false)
    }

    @Test func stoppedPluginOutranksAnEarlierStartFailure() {
        let status = PlaybackStatus(pluginStopped: true, startError: "earlier failure")
        #expect(!status.controlsEnabled)
        #expect(status.notice?.offersReload == true)
    }
}
