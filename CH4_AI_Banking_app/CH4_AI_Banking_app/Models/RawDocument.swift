//
//  RawDocument.swift
//  CH4_AI_Banking_app
//
//  Created by I Gusti Ngurah Bagus Ferry Mahayudha on 02/07/26.
//

import Foundation

// MARK: - Swift Struct: Transfer Object matching Spreadsheet JSON
struct RawRow: Codable {
    let name: String
    let category: String
    let description: String
    let price: String
    let fees: String
    let limits: String
    let requirements: String
    let benefitsAndFeatures: String
    let minApply: String? // Optional: some products (e.g. car loans) omit "min_apply".
    
    enum CodingKeys: String, CodingKey {
        case name, category, description, price, fees, limits, requirements
        case benefitsAndFeatures = "benefits & features" // Handles spaces/ampersands in table headers
        case minApply = "min_apply"
    }
}

/// Turns a single spreadsheet row dictionary into an explicit, contextually rich sentence block.
func buildContextualChunk(from row: RawRow) -> String {
    return """
    Product Name: \(row.name) | \
    Product Category: \(row.category) | \
    Description: \(row.description) | \
    Price & Annual Cost: \(row.price) | \
    Fee Structure & Hidden Charges: \(row.fees) | \
    Transaction, Credit, & Cash Withdrawal Limits: \(row.limits) | \
    Requirements to Apply & Eligibility Criteria: \(row.requirements) | \
    Product Benefits & Key Features: \(row.benefitsAndFeatures) | \
    Minimum Income Requirement to Apply: \(row.minApply ?? "Not specified")
    """
}
