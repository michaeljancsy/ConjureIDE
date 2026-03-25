//
//  CrossPlatform.swift
//  ConjureDSPExtension
//
//  Created by Michael Jancsy on 2/25/26.
//

import Foundation
import SwiftUI

#if os(iOS) || os(visionOS)
typealias HostingController = UIHostingController
#elseif os(macOS)
typealias HostingController = NSHostingController

extension NSView {
	
	func bringSubviewToFront(_ view: NSView) {
		// This function is a no-opp for macOS
	}
}
#endif
