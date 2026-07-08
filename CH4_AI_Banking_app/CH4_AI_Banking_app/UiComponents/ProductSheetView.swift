//
//  ProductSheetView.swift
//  CH4_AI_Banking_app
//
//  Section 06: the product detail bottom sheet — the only modal. Opens compact
//  and expands in place (iOS-native detents + grabber). Stays flat (surface-1),
//  not glowing, so long text stays readable.
//
//  Shows the real product strings (price, fees, limits, requirements) so nothing
//  reads "—" and fees are always truthful — never a guessed "Free".
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

                detailsSection

                referencesSection

                Spacer(minLength: 8)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.surface1.ignoresSafeArea())
    }

    /// The real key facts, straight from the source data. Only rows that actually
    /// have a value are shown, so there are no empty "—" placeholders.
    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            DetailRow(label: "Price / Rate", value: product.price)
            DetailRow(label: "Fees", value: product.fees)
            DetailRow(label: "Limits", value: product.limits)
            DetailRow(label: "Minimum to Apply", value: product.minApplyText)
            DetailRow(label: "Requirements", value: product.requirements)
        }
    }

    /// Section 11: a labeled external link ("web page to dive deeper"), never a bare URL.
    @ViewBuilder
    private var referencesSection: some View {
        if let url = URL(string: product.officialLink), !product.officialLink.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Rectangle().fill(Theme.hairline).frame(height: 1)

                Text("REFERENCES")
                    .font(.caption).fontWeight(.semibold)
                    .tracking(0.5)
                    .foregroundStyle(Theme.accent)

                Link(destination: url) {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.up.right")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Theme.hairline))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(product.name) — official page")
                                .font(.subheadline).fontWeight(.medium)
                                .foregroundStyle(Theme.textPrimary)
                            Text(url.host ?? product.officialLink)
                                .font(.footnote)
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// One labeled detail row that wraps its (possibly long) string value. Renders
/// nothing when the value is empty, so missing fields simply don't appear.
struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        if !value.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(label.uppercased())
                    .font(.caption).fontWeight(.semibold)
                    .tracking(0.5)
                    .foregroundStyle(Theme.textTertiary)
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.hairline)
            )
        }
    }
}

#Preview {
    ProductSheetView(
        product: ProductCardInfo(
            document: LocalDocument(
                id: "takeover",
                chunk: """
                Product Name: KPR BCA Take Over | Product Category: Housing Loan | \
                Description: Transfer existing mortgage from another bank with the option to add extra credit. | \
                Price & Annual Cost: Competitive interest rate options. | \
                Fee Structure & Hidden Charges: Provision fee: 0.25%; Admin fee: Free; Appraisal fee: IDR 1.1M-1.5M; Penalty: 0.2%/day. | \
                Transaction, Credit, & Cash Withdrawal Limits: Loan tenure up to 20 years, limit IDR 1B to 10B. | \
                Requirements to Apply & Eligibility Criteria: Existing KPR active for at least 2 years, clean payment record for 12 months. | \
                Product Benefits & Key Features: Competitive interest rates, flexible remaining tenor, option to top up loan. | \
                Minimum Income Requirement to Apply: Existing KPR active for 2 years
                """,
                category: "Housing Loan", source: "preview", embedding: [],
                minIncome: 0, annualFee: 0, maxLimit: 0,
                officialLink: "https://www.bca.co.id/en/Individu/produk/Pinjaman"
            )
        )
    )
}
