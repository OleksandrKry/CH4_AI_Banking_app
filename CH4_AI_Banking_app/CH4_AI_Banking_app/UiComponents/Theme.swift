//
//  Theme.swift
//  CH4_AI_Banking_app
//
//  Design tokens from "Design Foundations · V3": a dedicated dark palette,
//  a single brand blue, and one accent for anything interactive.
//

import SwiftUI

extension Color {
    /// Creates a color from a 0xRRGGBB hex literal.
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

enum Theme {
    // Surfaces & text (Section 01)
    static let base = Color(hex: 0x05070C)          // near-black background
    static let surface1 = Color(hex: 0x0A0F1A)      // elevated flat surface
    static let hairline = Color.white.opacity(0.07) // quiet fill / hairline
    static let textPrimary = Color(hex: 0xF2F4F8)
    static let textSecondary = Color(hex: 0x99A2B5)
    static let textTertiary = Color(hex: 0x5B6472)

    // Brand blue ramp (Section 01B)
    static let brandSurface = Color(hex: 0x0060AF)  // Blue 600 — surfaces, glow
    static let accent = Color(hex: 0x5B9CF2)        // Blue 400 — the only tint color
    static let tintText = Color(hex: 0xB7D3F7)      // Blue 200 — tint text on dark
}
