//
//  ProductCardInfo.swift
//  CH4_AI_Banking_app
//
//  UI-facing view model for the design's product cards + detail sheet. Derived
//  from a `LocalDocument` by parsing the contextual chunk built in
//  `buildContextualChunk`, so no re-ingestion or extra model call is needed.
//
//  The detail sheet shows the *real string fields* (price, fees, limits, …)
//  rather than the lossy numeric columns — those numbers are often 0/unknown for
//  loans and services, which used to render as "—" or a misleading "Free".
//

import Foundation

struct ProductCardInfo: Identifiable, Equatable {
    let id: String          // Mirrors the source LocalDocument.id
    let category: String    // Loans / Accounts / Cards ... (drives the category tag + avatar)
    let name: String        // Product Name
    let oneLiner: String    // Short Description shown on the card

    // Real, human-readable strings from the source data — the truth for the sheet.
    let price: String       // Price / rate
    let fees: String        // Actual fee schedule (never assume "Free")
    let limits: String
    let requirements: String
    let benefits: String
    let minApplyText: String // "Minimum Income Requirement to Apply" free text

    // Extracted numeric columns — kept for salary pre-filtering, not for display.
    let minIncome: Double
    let annualFee: Double
    let maxLimit: Double

    let officialLink: String // Source page for the "References" row on the sheet

    init(document: LocalDocument) {
        let fields = Self.fields(from: document.chunk)
        // Treat the ingestion placeholder "Not specified" as empty.
        func value(_ key: String) -> String {
            let raw = fields[key] ?? ""
            return raw.caseInsensitiveCompare("Not specified") == .orderedSame ? "" : raw
        }

        self.id = document.id
        self.category = document.category
        self.name = fields["Product Name"] ?? "Unknown Product"
        self.oneLiner = value("Description")

        self.price = value("Price & Annual Cost")
        self.fees = value("Fee Structure & Hidden Charges")
        self.limits = value("Transaction, Credit, & Cash Withdrawal Limits")
        self.requirements = value("Requirements to Apply & Eligibility Criteria")
        self.benefits = value("Product Benefits & Key Features")
        self.minApplyText = value("Minimum Income Requirement to Apply")

        self.minIncome = document.minIncome
        self.annualFee = document.annualFee
        self.maxLimit = document.maxLimit
        self.officialLink = document.officialLink
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
