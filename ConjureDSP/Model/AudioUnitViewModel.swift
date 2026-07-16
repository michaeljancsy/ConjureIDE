//
//  AudioUnitViewModel.swift
//  ConjureDSP
//
//  Created by Michael Jancsy on 2/25/26.
//
//  Derived from Apple's AUv3 sample-code host harness ("Creating custom
//  audio effects"). Portions copyright © Apple Inc. Used under the Apple
//  Sample Code License — see ACKNOWLEDGEMENTS.md at the repository root.
//

import SwiftUI
import AudioToolbox
import CoreAudioKit

struct AudioUnitViewModel {
    var showAudioControls: Bool = false
    var showMIDIContols: Bool = false
    var title: String = "-"
    var message: String = "No Audio Unit loaded.."
    var viewController: ViewController?
}
