//
//  ProductCardView.swift
//  CH4_AI_Banking_app
//
//  Section 05: brand-glow carousel card with deliberately minimal content —
//  category tag, name, one-liner. Numbers wait for the sheet (progressive disclosure).
//

import SwiftUI

struct ProductCardView: View {
    let product: ProductCardInfo
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CategoryTag(category: product.category)
                Spacer()
                CategoryAvatar(category: product.category, size: 32)
            }

            Text(product.name)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)

            Text(product.oneLiner)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(3)

            Spacer(minLength: 0)

            HStack {
                Text("View details")
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundStyle(Theme.accent)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Theme.hairline))
            }
        }
        .padding(16)
        .frame(width: 240, height: 200, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.surface1)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Theme.hairline, lineWidth: 1)
                )
        )
        .shadow(color: Theme.brandSurface.opacity(0.35), radius: 22, x: 0, y: 10)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

#Preview {
    ProductCardView(
        product: ProductCardInfo(
            document: LocalDocument(
                id: "flex",
                chunk: "Product Name: Personal Loan Flex | Description: Fixed rate, repay over 12–84 months, no early-payment fee.",
                category: "Car Loans", source: "preview", embedding: [],
                minIncome: 3_000_000, annualFee: 0, maxLimit: 60_000_000
            )
        )
    ) {}
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.base)
}
