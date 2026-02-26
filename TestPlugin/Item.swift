//
//  Item.swift
//  TestPlugin
//
//  Created by Michael Jancsy on 2/25/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
