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
//  Before ranking, every call goes through `RetrievalPlanner`: a separate,
//  deterministic guided-generation request that classifies the need into one
//  taxonomy category (from the full conversation, not just this turn's raw
//  argument) and reflects the need into a clean retrieval query. Search is then
//  SCOPED to that category — see RetrievalPlanner.swift for why this exists.
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

    /// Wall-clock for the WHOLE call — category/query planning plus the hybrid
    /// search itself — fed into `RAGSystem.TurnMetrics.retrieval`.
    @MainActor private(set) var lastCallDuration: Duration = .zero

    /// The plan the last call produced (nil when planning failed/was skipped,
    /// e.g. Apple Intelligence unavailable) — surfaced for debug logging.
    @MainActor private(set) var lastPlan: RetrievalPlan?

    /// Every user message in this conversation so far, oldest first — the
    /// context `RetrievalPlanner` classifies against. Injected (rather than
    /// fetched directly) so this tool stays SwiftData-free, like the rest of
    /// RagComponents.
    private let conversationUserInputs: @MainActor () -> [String]

    /// Hybrid scored search, injected by RAGSystem, SCOPED to a taxonomy
    /// category when the planner supplies one. Main-actor so all SwiftData
    /// access stays on the context's actor even when the model calls concurrently.
    private let search: @MainActor (String, IntentCategory?) -> [RetrievalHit]

    init(
        conversationUserInputs: @escaping @MainActor () -> [String],
        search: @escaping @MainActor (String, IntentCategory?) -> [RetrievalHit]
    ) {
        self.conversationUserInputs = conversationUserInputs
        self.search = search
    }

    /// Clear the per-turn capture before each `respond(to:)`.
    @MainActor func beginTurn() {
        retrievedThisTurn = []
        outputCharsThisTurn = 0
        lastCallDuration = .zero
        lastPlan = nil
    }

    func call(arguments: Arguments) async throws -> String {
        let clock = ContinuousClock()
        let start = clock.now

        // Plan on a SEPARATE session before touching retrieval at all — this is
        // the gate: category classification + query reflection, deterministic,
        // grounded in the whole conversation so far.
        let history = await MainActor.run { conversationUserInputs() }
        let plan = await RetrievalPlanner.plan(conversationMessages: history, toolQuery: arguments.query)

        return await MainActor.run {
            lastPlan = plan
            let effectiveQuery = plan?.searchQuery ?? arguments.query
            let hits = search(effectiveQuery, plan?.category)
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
            lastCallDuration = start.duration(to: clock.now)
            #if DEBUG
            print(String(format: "🧭 plan: %@ → \"%@\" (%.0fms)",
                         plan?.category.rawValue ?? "n/a (unscoped)", effectiveQuery,
                         lastCallDuration / .milliseconds(1)))
            #endif
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
