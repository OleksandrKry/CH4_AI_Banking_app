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
        different products. Do NOT call it for questions about products already shown \
        in this conversation — answer those from the conversation history.
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

    /// Hybrid scored search, injected by RAGSystem. Main-actor so all SwiftData
    /// access stays on the context's actor even when the model calls concurrently.
    private let search: @MainActor (String) -> [RetrievalHit]

    init(search: @escaping @MainActor (String) -> [RetrievalHit]) {
        self.search = search
    }

    /// Clear the per-turn capture before each `respond(to:)`.
    @MainActor func beginTurn() {
        retrievedThisTurn = []
    }

    func call(arguments: Arguments) async throws -> String {
        await MainActor.run {
            let hits = search(arguments.query)
            retrievedThisTurn.append(contentsOf: hits.map {
                RetrievedProduct(id: $0.document.id, confidence: $0.confidence)
            })

            guard !hits.isEmpty else {
                return "No sufficiently relevant BCA products were found for this need. Politely say so; do not guess or invent products."
            }
            return hits.map(\.document.chunk).joined(separator: "\n\n")
        }
    }
}
