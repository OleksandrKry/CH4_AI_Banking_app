//
//  RawDocument.swift
//  CH4_AI_Banking_app
//
//  Created by I Gusti Ngurah Bagus Ferry Mahayudha on 02/07/26.
//

import Foundation

// MARK: - Swift Struct: Transfer Object matching the BCA product JSON
//
// The real data is messy: keys are capitalized ("Name"/"Category"), several
// rows omit "fees" or "min_apply", one row has a numeric "benefits & features",
// and every row now carries an "official_link". A tolerant custom decoder keeps
// one bad row from failing the whole file.
struct RawRow: Codable {
    let name: String
    let category: String
    let description: String?
    let price: String?
    let fees: String?
    let limits: String?
    let requirements: String?
    let benefitsAndFeatures: String?
    let minApply: String?
    let officialLink: String?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case category = "Category"
        case description, price, fees, limits, requirements
        case benefitsAndFeatures = "benefits & features"
        case minApply = "min_apply"
        case officialLink = "official_link"
    }
}

extension RawRow {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = Self.flexibleString(container, .name) ?? "Unknown Product"
        category = Self.flexibleString(container, .category) ?? "Uncategorized"
        description = Self.flexibleString(container, .description)
        price = Self.flexibleString(container, .price)
        fees = Self.flexibleString(container, .fees)
        limits = Self.flexibleString(container, .limits)
        requirements = Self.flexibleString(container, .requirements)
        benefitsAndFeatures = Self.flexibleString(container, .benefitsAndFeatures)
        minApply = Self.flexibleString(container, .minApply)
        officialLink = Self.flexibleString(container, .officialLink)
    }

    /// Decodes a value as a String even if the JSON stored it as a number, and
    /// returns nil for missing keys instead of throwing.
    private static func flexibleString(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        if let string = try? container.decode(String.self, forKey: key) { return string }
        if let int = try? container.decode(Int.self, forKey: key) { return String(int) }
        if let double = try? container.decode(Double.self, forKey: key) { return String(double) }
        return nil
    }
}
