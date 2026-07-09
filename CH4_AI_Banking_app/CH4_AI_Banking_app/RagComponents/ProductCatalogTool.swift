//
//  ProductCatalogTool.swift
//  CH4_AI_Banking_app
//
//  FoundationModels tool exposing the hybrid retrieval pipeline to the on-device
//  model. Instead of stuffing retrieved chunks into every prompt, the model calls
//  this tool ONLY when the user asks for new or different products; follow-ups
//  about already-shown products are answered from the session transcript. This
//  keeps the 4,096-token context window for actual conversation.
//

import Foundation
import FoundationModels

final class ProductCatalogTool: Tool {
    let name = "searchProductCatalog"
    let description = """
        Searches BCA's product catalog and returns the best-matching products with full \
        details. Call this when the user asks for a recommendation or about new or \
        different products. Do NOT call it when the user refers to products already \
        shown in this conversation (e.g. "that card", "the first one", "its annual \
        fee") — answer those from the conversation history.
        """

    @Generable
    struct Arguments {
        @Guide(description: "The product need in the user's own words, e.g. 'travel credit card with airport lounge access'.")
        var query: String
    }

    /// What the model actually consulted this turn — read after `respond(to:)`
    /// returns, to build product cards, citations, and the confidence signal.
    struct RetrievedProduct {
        let id: String          // LocalDocument natural key (product name)
        let confidence: Double  // calibrated retrieval confidence of the hit
    }

    @MainActor private(set) var retrievedThisTurn: [RetrievedProduct] = []

    /// Characters this turn's tool output added to the transcript — feeds the
    /// session's context-budget estimate (4,096-token window).
    @MainActor private(set) var outputCharsThisTurn = 0

    /// Hybrid scored search, injected by RAGSystem. Main-actor so all SwiftData
    /// access stays on the context's actor even when the model calls concurrently.
    private let search: @MainActor (String) -> [RetrievalHit]

    init(search: @escaping @MainActor (String) -> [RetrievalHit]) {
        self.search = search
    }

    /// Clear the per-turn capture before each `respond(to:)`.
    @MainActor func beginTurn() {
        retrievedThisTurn = []
        outputCharsThisTurn = 0
    }

    func call(arguments: Arguments) async throws -> String {
        await MainActor.run {
            let hits = search(arguments.query)
            retrievedThisTurn.append(contentsOf: hits.map {
                RetrievedProduct(id: $0.document.id, confidence: $0.confidence)
            })

            let output: String
            if hits.isEmpty {
                output = "No sufficiently relevant BCA products were found for this need. Politely say so; do not guess or invent products."
            } else {
                output = hits.map { Self.compactSummary(of: $0.document) }.joined(separator: "\n")
            }
            outputCharsThisTurn += output.count
            return output
        }
    }

    /// Compact product rendering for the model (~40% fewer tokens than the stored
    /// labeled chunk): same facts, terse labels. Follow-up questions are answered
    /// from these lines living in the session transcript, so keep every field
    /// that a user could reasonably ask about.
    static func compactSummary(of document: LocalDocument) -> String {
        let card = ProductCardInfo(document: document)
        var parts = ["\(card.name) [\(card.category)]"]
        if !card.oneLiner.isEmpty { parts.append(card.oneLiner) }
        if !card.benefits.isEmpty { parts.append("Benefits: \(card.benefits)") }
        if !card.price.isEmpty { parts.append("Price: \(card.price)") }
        if !card.fees.isEmpty { parts.append("Fees: \(card.fees)") }
        if !card.limits.isEmpty { parts.append("Limits: \(card.limits)") }
        if !card.minApplyText.isEmpty { parts.append("Min to apply: \(card.minApplyText)") }
        if !card.requirements.isEmpty { parts.append("Requirements: \(card.requirements)") }
        // "; " on purpose: the answer rules forbid pipe delimiters, and the model
        // sometimes parrots tool output — never hand it characters it must not say.
        return parts.joined(separator: "; ")
    }
}
