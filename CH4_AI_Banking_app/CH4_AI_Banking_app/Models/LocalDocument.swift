//
//  LocalDocument.swift
//  CH4_AI_Banking_app
//
//  Created by I Gusti Ngurah Bagus Ferry Mahayudha on 02/07/26.
//

import Foundation
import SwiftData

// MARK: - SwiftData Entity: Local Persistent Storage
@Model
final class LocalDocument {
    @Attribute(.unique) var id: String
    var chunk: String       // The rich context narrative sentence block
    var category: String    // Metadata column for easy UI grouping if needed
    var source: String      // Track provenance (e.g., "bca_products.json")
    var embedding: [Double] // 512-dimension vector from Apple NLP
    
    init(id: String, chunk: String, category: String, source: String, embedding: [Double]) {
        self.id = id
        self.chunk = chunk
        self.category = category
        self.source = source
        self.embedding = embedding
    }
}
