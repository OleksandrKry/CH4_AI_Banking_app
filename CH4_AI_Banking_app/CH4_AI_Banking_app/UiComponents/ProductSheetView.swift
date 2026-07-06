//
//  ProductSheetView.swift
//  CH4_AI_Banking_app
//
//  Section 06: the product detail bottom sheet — the only modal. Opens compact
//  and expands in place (iOS-native detents + grabber). Stays flat (surface-1),
//  not glowing, so long text stays readable.
//

import SwiftUI

struct ProductSheetView: View {
    let product: ProductCardInfo
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    CategoryTag(category: product.category)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.body)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(Theme.hairline))
                    }
                }

                Text(product.name)
                    .font(.largeTitle).fontWeight(.bold)
                    .foregroundStyle(Theme.textPrimary)

                if !product.oneLiner.isEmpty {
                    Text(product.oneLiner)
                        .font(.body)
                        .foregroundStyle(Theme.textSecondary)
                }

                HStack(spacing: 12) {
                    StatCell(label: "MIN INCOME", value: Self.money(product.minIncome))
                    StatCell(label: "ANNUAL FEE", value: product.annualFee <= 0 ? "Free" : Self.money(product.annualFee))
                    StatCell(label: "MAX LIMIT", value: Self.money(product.maxLimit))
                }

                Spacer(minLength: 8)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.surface1.ignoresSafeArea())
    }

    /// Compact IDR formatting: 3,000,000 -> "IDR 3M"; 0 -> "—".
    private static func money(_ value: Double) -> String {
        guard value > 0 else { return "—" }
        if value >= 1_000_000 {
            let millions = value / 1_000_000
            let text = millions.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f", millions)
                : String(format: "%.1f", millions)
            return "IDR \(text)M"
        }
        return "IDR \(Int(value))"
    }
}

/// One labeled statistic cell used inside the sheet.
struct StatCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption).fontWeight(.semibold)
                .foregroundStyle(Theme.textTertiary)
            Text(value)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.hairline)
        )
    }
}

#Preview {
    ProductSheetView(
        product: ProductCardInfo(
            document: LocalDocument(
                id: "flex",
                chunk: "Product Name: Personal Loan Flex | Description: A fixed-rate loan for planned purchases.",
                category: "Car Loans", source: "preview", embedding: [],
                minIncome: 3_000_000, annualFee: 0, maxLimit: 60_000_000
            )
        )
    )
}
