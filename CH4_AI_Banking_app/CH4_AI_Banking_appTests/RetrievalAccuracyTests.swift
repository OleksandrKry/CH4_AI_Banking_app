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

    @Test func cardPolicySuppressesWeakTrailingHits() {
        // vectorContrast = confidence/10 under the calibrated formula (bm25 = 0).
        func hit(_ id: String, confidence: Double) -> RetrievalHit {
            RetrievalHit(document: doc(id, chunk: id), vectorScore: nil,
                         vectorContrast: confidence / 10, bm25Score: 0, rrfScore: 0)
        }

        // Strong pair: both shown.
        #expect(HybridRetriever.cardworthyHits([hit("a", confidence: 0.60),
                                                hit("b", confidence: 0.50)]).count == 2)
        // Trailing hit under the card floor: suppressed.
        #expect(HybridRetriever.cardworthyHits([hit("a", confidence: 0.60),
                                                hit("b", confidence: 0.30)]).count == 1)
        // Above the floor but far behind the top hit: suppressed.
        #expect(HybridRetriever.cardworthyHits([hit("a", confidence: 0.60),
                                                hit("b", confidence: 0.40)]).count == 1)
        // The top hit itself is always kept; empty stays empty.
        #expect(HybridRetriever.cardworthyHits([hit("only", confidence: 0.30)]).count == 1)
        #expect(HybridRetriever.cardworthyHits([]).isEmpty)
    }
}

// MARK: - Golden-set accuracy over the real corpus (model-gated)

@MainActor // the app's types default to main-actor isolation (project setting)
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
        // One chunk per product with no duplicate rows. The corpus is curated by
        // hand, so the exact count moves — uniqueness and a healthy floor are the
        // invariants (the doubled-KPR regression would trip the uniqueness check).
        #expect(rows.count >= 40)
        #expect(Set(rows.map(\.name)).count == rows.count)

        let corpus = RetrievalEvaluator.buildCorpus(
            rows: rows, tag: "test",
            embedText: buildEmbeddingText(from:), embed: { _ in [] })
        #expect(corpus.count == rows.count)
        #expect(corpus.allSatisfy { !$0.chunk.isEmpty })
    }

    /// R18: the corpus is hand-curated with an uncontrolled category vocabulary
    /// (29 raw strings for 47 products as of this writing) — this test fails
    /// the moment a new product introduces a raw category `CategoryTaxonomy`
    /// doesn't know about, instead of that product silently becoming
    /// unreachable through category-scoped retrieval.
    @Test func categoryTaxonomyIsExhaustive() throws {
        let rows = try RetrievalEvaluator.loadRows(from: productsJSONURL())
        let rawCategories = Set(rows.map(\.category))
        let unmapped = rawCategories.filter { CategoryTaxonomy.map[$0] == nil }
        #expect(unmapped.isEmpty, "Unmapped product categories — add them to CategoryTaxonomy.map: \(unmapped.sorted())")
    }

    /// R18: scoping to a bucket returns ONLY products whose raw category maps
    /// into it — the mechanism `RAGSystem.scoredSearchCore` relies on to keep
    /// cross-category products out of the candidate set entirely.
    @Test func categoryScopingContainsOnlyMatchingProducts() throws {
        let rows = try RetrievalEvaluator.loadRows(from: productsJSONURL())
        let corpus = RetrievalEvaluator.buildCorpus(
            rows: rows, tag: "test", embedText: { _ in "" }, embed: { _ in nil })

        let vehicleLoans = CategoryTaxonomy.documents(in: .vehicleLoan, from: corpus)
        #expect(Set(vehicleLoans.map(\.id)) == ["KKB BCA", "KSM BCA"])
        #expect(!vehicleLoans.contains { CategoryTaxonomy.bucket(for: $0.category) != .vehicleLoan })

        // Every bucket partitions the corpus disjointly — a product with one
        // raw category never appears under a DIFFERENT taxonomy bucket.
        for category in IntentCategory.allCases where category != .general {
            let scoped = CategoryTaxonomy.documents(in: category, from: corpus)
            #expect(scoped.allSatisfy { CategoryTaxonomy.bucket(for: $0.category) == category })
        }
    }

    @Test func goldenQueriesReferenceRealProducts() throws {
        // Guards the golden + edge sets against corpus renames going stale.
        let names = Set(try RetrievalEvaluator.loadRows(from: productsJSONURL()).map(\.name))
        for query in RetrievalEvaluator.goldenSet + RetrievalEvaluator.edgeSet {
            #expect(query.expected.isSubset(of: names),
                    "Eval set references unknown products: \(query.expected.subtracting(names))")
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
        // (its cosine contrast saturates and it can't embed Indonesian), so both
        // the floors AND the confidence-separation check are contextual-gated.
        if ContextualEmbedder.shared.modelTag.hasPrefix("contextual") {
            #expect(report.hitRate(at: 1) >= 0.70)
            #expect(report.hitRate(at: 3) >= 0.85)
            #expect(report.mrr >= 0.75)

            // Out-of-scope questions must stay under the decline floor while
            // typical positives clear it — keeps wrong-product pitches out.
            let negativeMax = report.negativeTopConfidences.max() ?? 0
            #expect(negativeMax < RetrievalEvaluator.percentile(report.positiveTopConfidences, 0.25),
                    "Confidence no longer separates in-scope from out-of-scope queries.")
        } else {
            #expect(report.hitRate(at: 3) >= 0.55)
        }

        // Edge cases (typos, vague one-worders, code-switching): the bar is
        // category steering, so the floors are deliberately looser.
        let edge = RetrievalEvaluator.evaluate(
            label: "edge (\(ContextualEmbedder.shared.modelTag))",
            corpus: corpus, weights: .current, tag: tag,
            queries: RetrievalEvaluator.edgeSet,
            embedQuery: { ContextualEmbedder.shared.vector(for: $0) })

        print(RetrievalEvaluator.summaryLine(edge))
        print(RetrievalEvaluator.details(edge))

        if ContextualEmbedder.shared.modelTag.hasPrefix("contextual") {
            #expect(edge.hitRate(at: 3) >= 0.6)
        }

        // R18: category-gate ablation — oracle ground-truth categories (no LLM
        // call needed here; the real on-device classifier's OWN accuracy is
        // verified separately in RAGSystemTests, which needs Apple
        // Intelligence). Scoping must never make retrieval WORSE on queries
        // where the true category is known — that would mean the taxonomy
        // partition itself is broken — and on the edge (typo/vague) set it
        // measurably RESCUES the cross-category failures unscoped retrieval
        // can't avoid (e.g. "motorcyle lone" surfacing a travel credit card).
        if ContextualEmbedder.shared.modelTag.hasPrefix("contextual") {
            let scopableGolden = RetrievalEvaluator.goldenSet.filter { $0.category != nil }
            let unscopedSubset = RetrievalEvaluator.evaluate(
                label: "unscoped (scopable subset)", corpus: corpus, weights: .current, tag: tag,
                queries: scopableGolden, embedQuery: { ContextualEmbedder.shared.vector(for: $0) })
            let scoped = RetrievalEvaluator.evaluateScoped(
                label: "scoped (oracle)", corpus: corpus, weights: .current, tag: tag,
                queries: scopableGolden, embedQuery: { ContextualEmbedder.shared.vector(for: $0) })

            print(RetrievalEvaluator.summaryLine(unscopedSubset))
            print(RetrievalEvaluator.summaryLine(scoped))
            #expect(scoped.hitRate(at: 1) >= unscopedSubset.hitRate(at: 1))
            #expect(scoped.hitRate(at: 3) >= 0.95)

            let scopableEdge = RetrievalEvaluator.edgeSet.filter { $0.category != nil }
            let scopedEdge = RetrievalEvaluator.evaluateScoped(
                label: "edge scoped (oracle)", corpus: corpus, weights: .current, tag: tag,
                queries: scopableEdge, embedQuery: { ContextualEmbedder.shared.vector(for: $0) })
            print(RetrievalEvaluator.summaryLine(scopedEdge))
            print(RetrievalEvaluator.details(scopedEdge))
            #expect(scopedEdge.hitRate(at: 1) >= 0.65)
        }
    }
}
