//
//  RetrievalPlanner.swift
//  CH4_AI_Banking_app
//
//  The gate between "the model wants to search" and "retrieval runs": a
//  SEPARATE, deterministic guided-generation request — its own session, never
//  the main chat session — that does two things in ONE constrained-decoding
//  call:
//   1. Classifies the need into the fixed taxonomy, reading the FULL
//      conversation so far (not just the latest tool argument), so context
//      from earlier turns informs the category.
//   2. Reflects on the raw need and rewrites it as a clean, canonical
//      retrieval query — the model's own tool-call phrasing can be slangy or
//      underspecified, and BM25 + embeddings both respond better to
//      normalized banking terms than to a raw fragment.
//
//  Retrieval is then SCOPED to exactly the classified category before ranking
//  (see `RAGSystem.scoredSearchCore` / `CategoryTaxonomy`). Without this gate,
//  a query like "motorcycle loan" can and does surface an unrelated travel
//  credit card purely on embedding noise — measured via
//  scripts/retrieval-eval.sh, where "motorcyle lone" (typo) ranked three
//  Singapore Airlines cards above the actual motorcycle-loan product.
//

import Foundation
import FoundationModels

@Generable
struct RetrievalPlan: Equatable {
    @Guide(description: "The single best-fitting product category for this need, based on the WHOLE conversation, not just the latest message.")
    var category: IntentCategory

    @Guide(description: "Reflect on the need and rewrite it as a clean, specific retrieval query in canonical banking terms — expand vague words, drop filler ('I need', 'please'), keep it 4 to 12 words. Example: 'need smth for spending on trips, want points' -> 'travel credit card with rewards miles'.")
    var searchQuery: String
}

enum RetrievalPlanner {

    /// Deterministic: greedy sampling + constrained decoding means the same
    /// inputs always produce the same category. Runs on a fresh session,
    /// separate from the chat session, so it never grows that session's
    /// transcript or context budget. Returns nil on failure — callers fall
    /// back to unscoped search with the raw tool argument, the same graceful-
    /// degradation style used throughout this pipeline (see
    /// `RAGSystem.classifyIntentCategory`, `generateIntakeQuestions`).
    static func plan(conversationMessages: [String], toolQuery: String) async -> RetrievalPlan? {
        guard SystemLanguageModel.default.isAvailable else { return nil }

        let history = conversationMessages.isEmpty ? "" : """
            The user's messages so far in this conversation:
            \(conversationMessages.map { "- \($0)" }.joined(separator: "\n"))

            """
        // Opens with the same "you are a BCA banking assistant" framing every
        // other one-shot session in this pipeline uses (generateIntakeQuestions,
        // classifyIntentCategory) — a bare dump of the decision tree without it
        // measurably increased on-device guardrail refusals on ordinary loan/
        // card queries during testing.
        let prompt = """
            You are a routing step for BCA's banking assistant, classifying a customer's product need — not giving financial advice.

            \(history)Their current need, as understood so far: "\(toolQuery)"

            \(BankingDecisionTree.instructionsBlock)

            Classify the need into the single best-fitting category and rewrite it as a clean retrieval query.
            """

        do {
            let session = LanguageModelSession()
            let response = try await session.respond(
                to: prompt,
                generating: RetrievalPlan.self,
                options: GenerationOptions(sampling: .greedy)
            )
            return response.content
        } catch {
            print("⚠️ Retrieval planning failed (\(error)); falling back to unscoped search.")
            #if DEBUG
            // Simulator stdout doesn't reach headless xcodebuild logs — drop the
            // raw error where it can actually be read during diagnosis.
            try? "\(error)".write(to: URL(fileURLWithPath: "/tmp/ch4-planner-error.txt"),
                                   atomically: true, encoding: .utf8)
            #endif
            return nil
        }
    }
}
