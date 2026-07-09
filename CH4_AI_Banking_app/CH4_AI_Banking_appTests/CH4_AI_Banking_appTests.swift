//
//  CH4_AI_Banking_appTests.swift
//  CH4_AI_Banking_appTests
//
//  Created by Raissa Raffi Darmawan on 01/07/26.
//

import Testing
import Foundation
import NaturalLanguage
@testable import CH4_AI_Banking_app

// MARK: - Cosine Similarity Math (pure, no model / no SwiftData)

struct VectorMathTests {

    @Test func identicalVectorsAreMaximallySimilar() {
        let v: [Double] = [1, 2, 3, 4]
        #expect(abs(VectorMath.cosineSimilarity(v, v) - 1.0) < 1e-9)
    }

    @Test func orthogonalVectorsHaveZeroSimilarity() {
        #expect(abs(VectorMath.cosineSimilarity([1, 0], [0, 1])) < 1e-9)
    }

    @Test func oppositeVectorsAreNegativeOne() {
        #expect(abs(VectorMath.cosineSimilarity([1, 0], [-1, 0]) + 1.0) < 1e-9)
    }

    @Test func magnitudeDoesNotAffectSimilarity() {
        // Same direction, different length -> still ~1.0
        #expect(abs(VectorMath.cosineSimilarity([1, 1], [10, 10]) - 1.0) < 1e-9)
    }

    @Test func mismatchedOrEmptyReturnsZero() {
        #expect(VectorMath.cosineSimilarity([1, 2, 3], [1, 2]) == 0)
        #expect(VectorMath.cosineSimilarity([], []) == 0)
    }

    @Test func zeroVectorReturnsZeroInsteadOfNaN() {
        let result = VectorMath.cosineSimilarity([0, 0, 0], [1, 2, 3])
        #expect(result == 0)
        #expect(!result.isNaN)
    }
}

// MARK: - BM25 Keyword Ranking (no model / no SwiftData container)

struct BM25SearchTests {

    /// `@Model` instances can be created directly, without a `ModelContext`,
    /// which lets us exercise the ranking logic in isolation.
    private func makeDoc(_ id: String, _ chunk: String) -> LocalDocument {
        LocalDocument(id: id, chunk: chunk, category: "test", source: "test", embedding: [],
                      minIncome: 0, annualFee: 0, maxLimit: 0)
    }

    @Test func exactKeywordMatchRanksHighest() {
        let docs = [
            makeDoc("savings", "BCA Tahapan savings account with low monthly fees"),
            makeDoc("credit", "BCA credit card with generous cashback rewards"),
            makeDoc("loan", "Home mortgage loan with a fixed interest rate")
        ]
        let engine = BM25Search(query: "credit card cashback", documents: docs)
        let ranked = engine.rankByKeyword()
        #expect(ranked.first?.id == "credit")
    }

    @Test func queryWithNoUsableTermsReturnsAllDocuments() {
        let docs = [makeDoc("a", "alpha"), makeDoc("b", "beta")]
        // Punctuation-only query tokenizes to nothing.
        let engine = BM25Search(query: "!!! ???", documents: docs)
        #expect(engine.rankByKeyword().count == docs.count)
    }

    @Test func rareTermOutranksCommonTerm() {
        // "bca" appears in every doc (low IDF); "mortgage" is rare (high IDF).
        let docs = [
            makeDoc("d1", "bca savings account"),
            makeDoc("d2", "bca credit card"),
            makeDoc("d3", "bca mortgage loan")
        ]
        let engine = BM25Search(query: "bca mortgage", documents: docs)
        #expect(engine.rankByKeyword().first?.id == "d3")
    }
}

// MARK: - Sequential intake flow (pure struct logic — generate once, ask one by one)

struct IntakeFlowTests {

    private func makeFlow() -> IntakeFlow {
        IntakeFlow(
            originalQuery: "I want a loan",
            questions: [
                FollowUpQuestion(question: "Purpose?", options: ["Home", "Car"]),
                FollowUpQuestion(question: "Amount?", options: ["<100M", ">100M"]),
                FollowUpQuestion(question: "Tenor?", options: ["Short", "Long"]),
            ]
        )
    }

    @Test func walksQuestionsOneAtATime() {
        var flow = makeFlow()
        #expect(flow.current?.question == "Purpose?")
        #expect(flow.progress == "1/3")

        flow.record("Home")
        #expect(flow.current?.question == "Amount?")
        #expect(flow.progress == "2/3")
        #expect(!flow.isComplete)

        flow.record(nil)               // skip
        flow.record("Long")
        #expect(flow.isComplete)
        #expect(flow.current == nil)
    }

    @Test func summaryKeepsAnswersAndOmitsSkips() {
        var flow = makeFlow()
        flow.record("Home")
        flow.record(nil)               // skipped
        flow.record("  Long  ")        // trimmed

        let summary = flow.summary()
        #expect(summary.contains("- Purpose?: Home"))
        #expect(summary.contains("- Tenor?: Long"))
        #expect(!summary.contains("Amount?"))
    }

    @Test func blankAnswerCountsAsSkip() {
        var flow = makeFlow()
        flow.record("   ")
        #expect(flow.summary().isEmpty)
        #expect(flow.current?.question == "Amount?") // still advanced
    }
}

// MARK: - Vector Search (integration; requires the on-device embedding model)

@MainActor // the app's types default to main-actor isolation (project setting)
struct VectorSearchTests {

    /// Skips (not fails) on hosts without NL embedding assets, e.g. fresh simulators.
    @Test(.enabled("Needs an on-device NL embedding model") {
        await RetrievalEvaluator.embedderAvailable()
    })
    func semanticallyRelevantDocumentRanksAboveIrrelevantOne() async throws {
        // Docs and query must share the same embedding space, so embed both with
        // the contextual model VectorSearch now uses.
        func doc(_ id: String, _ text: String) -> LocalDocument {
            LocalDocument(
                id: id,
                chunk: text,
                category: "test",
                source: "test",
                embedding: ContextualEmbedder.shared.vector(for: text) ?? [],
                minIncome: 0, annualFee: 0, maxLimit: 0
            )
        }

        let docs = [
            doc("card", "credit card with cashback and reward points"),
            doc("trail", "the mountain trail was covered in fresh snow")
        ]

        let engine = VectorSearch(query: "best rewards credit card", documents: docs)
        let ranked = try #require(engine.rankBySimilarity())
        #expect(ranked.first?.id == "card")
    }
}
