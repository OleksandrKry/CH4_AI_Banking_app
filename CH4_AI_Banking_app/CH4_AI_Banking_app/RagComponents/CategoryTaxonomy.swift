//
//  CategoryTaxonomy.swift
//  CH4_AI_Banking_app
//
//  The product corpus is hand-curated and its raw `Category` strings are NOT
//  a controlled vocabulary — 47 products currently carry 29 distinct raw
//  category strings (e.g. "Credit Card", "Travel Credit Card", "Co-branded
//  Credit Card", and "Premium Credit Card" are all just "credit card" for
//  retrieval purposes). This table is the single, exhaustive mapping from
//  every raw string to the fixed `IntentCategory` taxonomy, so retrieval can
//  be SCOPED to one bucket before ranking instead of searching the whole
//  corpus every time.
//
//  Exhaustiveness against the live corpus is enforced by
//  RetrievalAccuracyTests.categoryTaxonomyIsExhaustive — when a new product
//  introduces a raw category this table doesn't know about, that test fails
//  until the table is updated, instead of the product silently becoming
//  unreachable through category-scoped search.
//

import Foundation

enum CategoryTaxonomy {

    /// Raw `LocalDocument.category` / `RawRow.category` string -> taxonomy
    /// bucket. Keys are matched exactly against the corpus as authored.
    static let map: [String: IntentCategory] = [
        // Cards
        "Credit Card": .creditCard,
        "Travel Credit Card": .creditCard,
        "Co-branded Credit Card": .creditCard,
        "Premium Credit Card": .creditCard,
        "Debit Card": .debitCard,
        // Accounts
        "Savings Account": .savingsAccount,
        "Youth Savings Account": .savingsAccount,
        "Premium Savings Account": .savingsAccount,
        "Foreign Currency Account": .savingsAccount,
        // Investing
        "Government Bond": .investment,
        "Fixed Deposit": .investment,
        "Insurance Investment": .investment,
        // Loans
        "Housing Loan": .housingLoan,
        "Car Loan": .vehicleLoan,
        "Motorcycle Loan": .vehicleLoan,
        "Personal Loan": .personalLoan,
        "Secured Personal Loan": .personalLoan,
        // Transfers & payments
        "Transfer Service": .transfersAndPayments,
        "International Transfer": .transfersAndPayments,
        "Payment Service": .transfersAndPayments,
        "Payment Feature": .transfersAndPayments,
        "ATM Service": .transfersAndPayments,
        // Digital services
        "Digital Banking App": .digitalServices,
        "Mobile Banking App": .digitalServices,
        "Internet Banking": .digitalServices,
        "Security Service": .digitalServices,
        "Card Management Service": .digitalServices,
        "Digital Document Service": .digitalServices,
        "Alert Service": .digitalServices,
    ]

    /// Maps a raw category string to its taxonomy bucket. Unknown strings fall
    /// back to `.general` rather than crashing or silently dropping the
    /// product from every scoped search — `.general` is excluded from
    /// category scoping (see `RAGSystem.scoredSearchCore`), so an unmapped
    /// product stays reachable through the unscoped fallback while the
    /// exhaustiveness test surfaces the gap in this table.
    static func bucket(for rawCategory: String) -> IntentCategory {
        map[rawCategory] ?? .general
    }

    /// Documents whose raw category maps into `category`. Pure and
    /// SwiftData-free (mirrors `HybridRetriever` / `BM25Search`), so it's
    /// directly unit-testable without a ModelContext.
    static func documents(in category: IntentCategory, from documents: [LocalDocument]) -> [LocalDocument] {
        documents.filter { bucket(for: $0.category) == category }
    }
}
