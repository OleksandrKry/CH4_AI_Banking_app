//
//  CategoryStyle.swift
//  CH4_AI_Banking_app
//
//  Maps a product's category string to the curated Sanzo-Wada combination
//  (Section 01C) plus a letter glyph and short tag, so category identity reads
//  in color, letter, and text — never color alone (HIG accessibility).
//

import SwiftUI

struct CategoryStyle {
    let letter: String   // Trade-card avatar glyph: L / A / C / ?
    let tag: String      // Short uppercase tag: LOANS / ACCOUNTS / CARDS
    let color: Color

    init(category: String) {
        let value = category.lowercased()
        if value.contains("loan") {
            letter = "L"; tag = "LOANS"; color = Color(hex: 0xBF5B3E)          // Terracotta
        } else if value.contains("account") || value.contains("saving") || value.contains("deposit") {
            letter = "A"; tag = "ACCOUNTS"; color = Color(hex: 0xD9A441)       // Ochre
        } else if value.contains("card") {
            letter = "C"; tag = "CARDS"; color = Color(hex: 0x1E7D74)          // Peacock
        } else {
            letter = "?"; tag = category.uppercased(); color = Color(hex: 0x7A4B6D) // Plum (reserved)
        }
    }
}
