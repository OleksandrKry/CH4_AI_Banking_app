//
//  LocalDocument.swift
//  CH4_AI_Banking_app
//
//  Created by I Gusti Ngurah Bagus Ferry Mahayudha on 02/07/26.
//

import Foundation
import SwiftData

@Model
final class LocalDocument {
    @Attribute(.unique) var id: String
    var chunk: String
    var category: String
    var source: String
    var embedding: [Double]

    // Explicit numerical columns for low-code database pre-filtering
    var minIncome: Double  // E.g., 3000000.0
    var annualFee: Double  // E.g., 125000.0
    var maxLimit: Double   // E.g., 3000000.0 (0.0 if approval-based)

    // Provenance link to the official BCA product page (Section 11 "References").
    var officialLink: String

    init(id: String, chunk: String, category: String, source: String, embedding: [Double], minIncome: Double, annualFee: Double, maxLimit: Double, officialLink: String = "") {
        self.id = id
        self.chunk = chunk
        self.category = category
        self.source = source
        self.embedding = embedding
        self.minIncome = minIncome
        self.annualFee = annualFee
        self.maxLimit = maxLimit
        self.officialLink = officialLink
    }
}
