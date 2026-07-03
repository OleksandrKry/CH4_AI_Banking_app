//
//  ProductCardInfo.swift
//  CH4_AI_Banking_app
//
//  UI-facing view model for the design's product cards (category tag + name +
//  one-liner + key numbers). Derived from a `LocalDocument` by parsing the
//  contextual chunk built in `buildContextualChunk`, so no re-ingestion or
//  extra model call is needed.
//

import Foundation

struct ProductCardInfo: Identifiable, Equatable {
    let id: String          // Mirrors the source LocalDocument.id
    let category: String    // Loans / Accounts / Cards ... (drives the category tag + avatar)
    let name: String        // Product Name
    let oneLiner: String    // Short Description shown on the card
    let minIncome: Double   // Extracted numeric columns, reused for the detail sheet
    let annualFee: Double
    let maxLimit: Double

    init(document: LocalDocument) {
        let fields = Self.fields(from: document.chunk)
        self.id = document.id
        self.category = document.category
        self.name = fields["Product Name"] ?? "Unknown Product"
        self.oneLiner = fields["Description"] ?? ""
        self.minIncome = document.minIncome
        self.annualFee = document.annualFee
        self.maxLimit = document.maxLimit
    }

    /// Splits a `buildContextualChunk` string ("Label: value | Label: value | …")
    /// back into a keyed dictionary. Splits each segment on its *first* colon so
    /// values that themselves contain colons (e.g. "Late fee: 1%") stay intact.
    private static func fields(from chunk: String) -> [String: String] {
        var result: [String: String] = [:]
        for segment in chunk.components(separatedBy: "|") {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            result[key] = value
        }
        return result
    }
}
