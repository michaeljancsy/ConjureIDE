//
//  Parameters.swift
//  TestPluginExtension
//
//  Created by Michael Jancsy on 2/25/26.
//

import Foundation
import AudioToolbox

/// Parameter addresses — currently no parameters are defined.
/// Add cases here with raw AUParameterAddress values when adding parameters.
enum TestPluginExtensionParameterAddress: AUParameterAddress {
    case _placeholder = 0xFFFF_FFFF
}
