//
//  Item.swift
//  CH4_AI_Banking_app
//
//  Created by Raissa Raffi Darmawan on 01/07/26.
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
