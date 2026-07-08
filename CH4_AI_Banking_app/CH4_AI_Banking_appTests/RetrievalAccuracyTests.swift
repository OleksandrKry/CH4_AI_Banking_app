//
//  RetrievalAccuracyTests.swift
//  CH4_AI_Banking_appTests
//
//  Two layers of retrieval coverage:
//   1. HybridRetrieverTests — deterministic fusion-logic tests with injected
//      embeddings (no model, no SwiftData, run everywhere).
//   2. RetrievalAccuracyTests — the golden-set benchmark over the real corpus
//      through the production embedder, gated on model availability. Floors are
//      calibrated with scripts/retrieval-eval.sh; see RetrievalEvaluator.
//

import Testing
import Foundation
import NaturalLanguage
@testable import CH4_AI_Banking_app

// MARK: - Fusion logic (deterministic, injected embeddings)

struct HybridRetrieverTests {

    private func doc(_ id: String, chunk: String, embedding: [Double] = [],
                     tag: String = "test") -> LocalDocument {
        LocalDocument(id: id, chunk: chunk, category: "test", source: "test",
                      embedding: embedding, minIncome: 0, annualFee: 0, maxLimit: 0,
                      embeddingModel: tag)
    }

    @Test func keywordEvidenceBreaksVectorTies() {
        // Both docs have identical vectors; only "batman" keyword evidence differs.
        let docs = [
            doc("other", chunk: "unrelated text entirely", embedding: [1, 0]),
            doc("match", chunk: "batman themed card", embedding: [1, 0]),
        ]
        let hits = HybridRetriever.rank(query: "batman", documents: docs,
                                        activeEmbeddingTag: "test", embedQuery: { _ in [1, 0] })
        #expect(hits.first?.document.id == "match")
        #expect((hits.first?.bm25Score ?? 0) > 0)
        #expect(hits.last?.bm25Score == 0)
    }

    @Test func zeroBM25DocsGetNoKeywordRankContribution() {
        // No embeddings at all → ranking driven purely by BM25; the doc matching
        // no query term keeps rrf == 0 instead of arbitrary tie-order rank credit.
        let docs = [doc("a", chunk: "mortgage loan"), doc("b", chunk: "credit card")]
        let hits = HybridRetriever.rank(query: "mortgage", documents: docs,
                                        activeEmbeddingTag: "test", embedQuery: { _ in nil })
        #expect(hits.first?.document.id == "a")
        #expect(hits.last?.rrfScore == 0)
    }

    @Test func mismatchedEmbeddingSpaceIsNeverCosineCompared() {
        // A stored vector from another embedder must not produce a garbage cosine.
        let docs = [doc("stale", chunk: "no keyword overlap", embedding: [1, 0], tag: "old-model")]
        let hits = HybridRetriever.rank(query: "anything", documents: docs,
                                        activeEmbeddingTag: "new-model", embedQuery: { _ in [1, 0] })
        #expect(hits.first?.vectorScore == nil)
    }

    @Test func weightsIsolateEachEngine() {
        // The query vector matches "vecfav"; the keyword "alpha" matches "kwfav".
        let docs = [
            doc("vecfav", chunk: "zzz yyy xxx", embedding: [1, 0]),
            doc("kwfav", chunk: "alpha beta gamma", embedding: [0, 1]),
        ]
        let vectorOnly = HybridRetriever.rank(
            query: "alpha", documents: docs,
            weights: .init(vector: 1, bm25: 0),
            activeEmbeddingTag: "test", embedQuery: { _ in [1, 0] })
        #expect(vectorOnly.first?.document.id == "vecfav")

        let bm25Only = HybridRetriever.rank(
            query: "alpha", documents: docs,
            weights: .init(vector: 0, bm25: 1),
            activeEmbeddingTag: "test", embedQuery: { _ in [1, 0] })
        #expect(bm25Only.first?.document.id == "kwfav")
    }

    @Test func confidenceReflectsKeywordOnlyEvidence() {
        // Exact keyword hits must not read as zero-confidence when no vector exists.
        let docs = [doc("kw", chunk: "batman card")]
        let hits = HybridRetriever.rank(query: "batman", documents: docs,
                                        activeEmbeddingTag: "test", embedQuery: { _ in nil })
        #expect(hits.first?.vectorScore == nil)
        #expect((hits.first?.confidence ?? 0) > 0)
    }
}

// MARK: - Golden-set accuracy over the real corpus (model-gated)

struct RetrievalAccuracyTests {

    /// Same #filePath resolution as RAGSystemTests: the JSON belongs to the app
    /// target, so tests read it straight from the checkout.
    private func productsJSONURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CH4_AI_Banking_app/Data/bca-products.json")
    }

    @Test func everyProductIsExactlyOneChunk() throws {
        let rows = try RetrievalEvaluator.loadRows(from: productsJSONURL())
        // 53 products after deduplicating the doubled KPR block — one chunk each.
        #expect(rows.count == 53)
        #expect(Set(rows.map(\.name)).count == rows.count)

        let corpus = RetrievalEvaluator.buildCorpus(
            rows: rows, tag: "test",
            embedText: buildEmbeddingText(from:), embed: { _ in [] })
        #expect(corpus.count == rows.count)
        #expect(corpus.allSatisfy { !$0.chunk.isEmpty })
    }

    @Test func goldenQueriesReferenceRealProducts() throws {
        // Guards the golden set against corpus renames going stale.
        let names = Set(try RetrievalEvaluator.loadRows(from: productsJSONURL()).map(\.name))
        for query in RetrievalEvaluator.goldenSet {
            #expect(query.expected.isSubset(of: names),
                    "Golden set references unknown products: \(query.expected.subtracting(names))")
        }
    }

    @Test(.enabled("Needs an on-device NL embedding model") {
        await RetrievalEvaluator.embedderAvailable()
    })
    func goldenSetAccuracyMeetsFloors() async throws {
        let rows = try RetrievalEvaluator.loadRows(from: productsJSONURL())
        let tag = ContextualEmbedder.shared.indexTag
        let corpus = RetrievalEvaluator.buildCorpus(
            rows: rows, tag: tag,
            embedText: buildEmbeddingText(from:),
            embed: { ContextualEmbedder.shared.vector(for: $0) })

        let report = RetrievalEvaluator.evaluate(
            label: "prod-path (\(ContextualEmbedder.shared.modelTag))",
            corpus: corpus, weights: .current, tag: tag,
            embedQuery: { ContextualEmbedder.shared.vector(for: $0) })

        print(RetrievalEvaluator.header())
        print(RetrievalEvaluator.summaryLine(report))
        print(RetrievalEvaluator.details(report))

        // Floors sit a step below the values measured by scripts/retrieval-eval.sh,
        // so they catch regressions without flaking on model-revision drift. The
        // NLEmbedding fallback ranks noticeably worse than the contextual model
        // (and can't embed the Indonesian queries), hence the looser floor.
        if ContextualEmbedder.shared.modelTag.hasPrefix("contextual") {
            #expect(report.hitRate(at: 1) >= 0.70)
            #expect(report.hitRate(at: 3) >= 0.85)
            #expect(report.mrr >= 0.75)
        } else {
            #expect(report.hitRate(at: 3) >= 0.55)
        }

        // Out-of-scope questions must stay under the decline floor while typical
        // positives clear it — this is what keeps wrong-product pitches out.
        let negativeMax = report.negativeTopConfidences.max() ?? 0
        #expect(negativeMax < RetrievalEvaluator.percentile(report.positiveTopConfidences, 0.25),
                "Confidence no longer separates in-scope from out-of-scope queries.")
    }
}
