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

// MARK: - Vector Search (integration; requires the on-device embedding model)

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

// MARK: - Intake quiz state (pure struct logic — options / own answer / skip)

struct IntakeFlowTests {

    private func makeIntake() -> PendingIntake {
        PendingIntake(
            query: "I want a loan",
            category: "Housing Loan",
            questions: [
                FollowUpQuestion(question: "Purpose?", options: ["New home", "Renovation"]),
                FollowUpQuestion(question: "Tenure?", options: ["≤10y", "10–20y"]),
                FollowUpQuestion(question: "Budget?", options: ["<1B", ">1B"]),
            ]
        )
    }

    @Test func resolvedMeansAnsweredOrSkipped() {
        var intake = makeIntake()
        #expect(!intake.allResolved)

        intake.answers["Purpose?"] = "Renovation"       // provided option
        intake.answers["Tenure?"] = "about 15 years"    // user's own version
        #expect(!intake.allResolved)                    // one question still open

        intake.skipped.insert("Budget?")                // deliberately skipped
        #expect(intake.allResolved)
        #expect(intake.answeredCount == 2)
    }

    @Test func customAnswersAreDetectedAgainstOptions() {
        var intake = makeIntake()
        intake.answers["Purpose?"] = "Renovation"
        intake.answers["Tenure?"] = "about 15 years"

        #expect(!intake.isCustomAnswer(for: "Purpose?"))
        #expect(intake.isCustomAnswer(for: "Tenure?"))
        #expect(!intake.isCustomAnswer(for: "Budget?")) // unanswered → not custom
    }

    @Test func summaryIncludesAnswersAndOmitsSkipped() {
        var intake = makeIntake()
        intake.answers["Purpose?"] = "New home"
        intake.answers["Tenure?"] = "about 15 years  "  // raw text is trimmed in the summary
        intake.skipped.insert("Budget?")

        let summary = intake.summary()
        #expect(summary.contains("- Purpose?: New home"))
        #expect(summary.contains("- Tenure?: about 15 years"))
        #expect(!summary.contains("Budget?"))
    }
}
