//
//  CategoryBadges.swift
//  CH4_AI_Banking_app
//
//  Letter avatar (Section 07) + category tag pill (Section 01C). Saturated fills
//  are allowed only inside these small marks.
//

import SwiftUI

/// Solid circle with a single category letter — the trade-card pattern.
struct CategoryAvatar: View {
    let category: String
    var size: CGFloat = 44

    var body: some View {
        let style = CategoryStyle(category: category)
        Text(style.letter)
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(style.color))
    }
}

/// Low-opacity pill with the category's hue and uppercase text tag.
struct CategoryTag: View {
    let category: String

    var body: some View {
        let style = CategoryStyle(category: category)
        Text(style.tag)
            .font(.caption).fontWeight(.semibold)
            .tracking(0.5)
            .foregroundStyle(style.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(style.color.opacity(0.18)))
    }
}

#Preview {
    HStack(spacing: 16) {
        CategoryAvatar(category: "Car Loans")
        CategoryAvatar(category: "Everyday Account")
        CategoryAvatar(category: "Credit Card")
        CategoryTag(category: "Credit Card")
    }
    .padding()
    .background(Theme.base)
}
