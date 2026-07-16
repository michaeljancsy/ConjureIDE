//
//  TypeAliases.swift
//  ConjureDSP
//
//  Created by Michael Jancsy on 2/25/26.
//
//  Derived from Apple's AUv3 sample-code host harness ("Creating custom
//  audio effects"). Portions copyright © Apple Inc. Used under the Apple
//  Sample Code License — see ACKNOWLEDGEMENTS.md at the repository root.
//

import CoreMIDI
import AudioToolbox

#if os(iOS) || os(visionOS)
import UIKit

public typealias ViewController = UIViewController
#elseif os(macOS)
import AppKit

public typealias KitView = NSView
public typealias ViewController = NSViewController
#endif
