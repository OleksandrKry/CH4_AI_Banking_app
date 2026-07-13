//
//  HybridRetriever.swift
//  CH4_AI_Banking_app
//
//  Scored hybrid retrieval: dense vectors (cosine) + BM25 keywords fused with
//  weighted Reciprocal Rank Fusion. Extracted from RAGSystem so the ranking is
//  SwiftData-free (evaluable from unit tests and the scripts/retrieval-eval.sh
//  CLI harness) and so every stage's score survives to the caller — retrieval
//  confidence is a first-class output instead of a discarded intermediate.
//

import Foundation

/// One ranked document together with every retrieval signal that produced its
/// position, so callers can log, threshold, and evaluate retrieval quality.
struct RetrievalHit {
    let document: LocalDocument
    /// Cosine similarity query↔document in -1...1. Nil when no usable vector
    /// exists (embedder unavailable, empty stored vector, or the stored vector
    /// was produced in a different embedding space than the query vector).
    let vectorScore: Double?
    /// Cosine CONTRAST: this document's cosine minus the corpus-mean cosine for
    /// the same query. Contextual embeddings are anisotropic — every document
    /// lands in ~0.7...0.95 raw cosine — so only standing out from the corpus
    /// carries semantic meaning (measured: RetrievalEvaluator.calibrationDump).
    let vectorContrast: Double?
    /// Raw BM25 keyword score (0 when the document matches no query term).
    let bm25Score: Double
    /// Weighted Reciprocal Rank Fusion score — the final ranking key.
    let rrfScore: Double

    /// Retrieval confidence in 0...1 = max(semantic contrast, keyword evidence).
    /// Used for THRESHOLDING (floors, the card margin, the "recommended" badge)
    /// — deliberately NOT the primary ranking key (see `rank`'s sort comment
    /// for why a confidence-primary sort was tried and reverted). Calibrated on
    /// the golden set (ctx | distilled, category-scoped, 2026-07): 22 positives
    /// ranged 0.396–0.85 and 5 out-of-scope negatives ranged 0.29–0.37. The
    /// floor `HybridRetriever.minimumConfidence` is tied to this definition —
    /// recalibrate with scripts/retrieval-eval.sh whenever it changes.
    var confidence: Double {
        let semantic = min(1, max(0, (vectorContrast ?? 0) * 10))
        let keyword = bm25Score / (bm25Score + 10)
        return max(semantic, keyword)
    }
}

enum HybridRetriever {

    /// RRF fusion weights. `current` is what production uses — calibrated on the
    /// golden set (see RetrievalEvaluator / scripts/retrieval-eval.sh).
    struct Weights {
        var vector: Double
        var bm25: Double
        var rrfK: Double = 60

        static let current = Weights(vector: 0.4, bm25: 1.0)
    }

    /// Calibrated floor under which a hit counts as "nothing relevant found":
    /// the pipeline then declines instead of pitching an unrelated product.
    /// 0.25 sits comfortably under the weakest golden-set positive (0.396 as of
    /// 2026-07), so it only drops clearly-ungrounded hits (no keyword match AND
    /// no cosine contrast) — it is NOT tuned to reject every out-of-scope
    /// negative on its own (several sit above 0.25 too); that finer separation
    /// is checked statistically (negative-max vs. positive-p25) in
    /// RetrievalAccuracyTests, not by this hard floor. Word-collision negatives
    /// (e.g. "visa requirements" vs. Visa cards) are indistinguishable at the
    /// retrieval layer by design — the master prompt's decline instruction
    /// handles those with the context in view.
    static let minimumConfidence = 0.25

    /// Card display policy: the best hit is always worth grounding on, but a
    /// TRAILING hit becomes a product card only when it clears `cardConfidence`
    /// AND sits within `cardMargin` of the top hit — a weak second product reads
    /// as a wrong answer in the UI. Calibrated via the golden-set sweep
    /// (scripts/retrieval-eval.sh): margin 0.10 lifts card precision without
    /// ever costing recall — the margin only ever removes wrong cards.
    static let cardConfidence = 0.35
    static let cardMargin = 0.10

    /// Applies the card policy to confidence-floored, ranked hits. `floor` and
    /// `margin` are injectable so the eval harness can sweep candidate values.
    static func cardworthyHits(
        _ hits: [RetrievalHit],
        floor: Double = cardConfidence,
        margin: Double = cardMargin
    ) -> [RetrievalHit] {
        guard let top = hits.first else { return [] }
        let trailing = hits.dropFirst().filter {
            $0.confidence >= floor && $0.confidence >= top.confidence - margin
        }
        return [top] + trailing
    }

    /// Ranks `documents` against `query`. Pure function of its inputs; the query
    /// embedder is injectable so tests and the eval harness can pin the backend.
    static func rank(
        query: String,
        documents: [LocalDocument],
        weights: Weights = .current,
        activeEmbeddingTag: String? = nil,
        embedQuery: (String) -> [Double]? = { ContextualEmbedder.shared.vector(for: $0) }
    ) -> [RetrievalHit] {
        guard !documents.isEmpty else { return [] }

        let queryVector = embedQuery(query)
        let bm25Scores = BM25Search(query: query, documents: documents).scores()

        // A stored vector is only comparable when it was produced in the same
        // embedding space as the query vector — enforced via the index tag.
        var vectorScores: [String: Double] = [:]
        if let queryVector {
            for doc in documents where !doc.embedding.isEmpty {
                if let tag = activeEmbeddingTag, !doc.embeddingModel.isEmpty, doc.embeddingModel != tag {
                    continue
                }
                vectorScores[doc.id] = VectorMath.cosineSimilarity(queryVector, doc.embedding)
            }
        }

        // Anisotropy baseline: semantic evidence is measured against the corpus
        // mean for THIS query, not as an absolute cosine (see RetrievalHit docs).
        let meanCosine = vectorScores.isEmpty
            ? 0 : vectorScores.values.reduce(0, +) / Double(vectorScores.count)

        // Rank lists feeding RRF. Docs with zero BM25 carry no keyword evidence,
        // so they are excluded instead of being ranked in arbitrary tie order.
        let vectorRanked = documents
            .filter { vectorScores[$0.id] != nil }
            .sorted { (vectorScores[$0.id] ?? -1) > (vectorScores[$1.id] ?? -1) }
        let bm25Ranked = documents
            .filter { (bm25Scores[$0.id] ?? 0) > 0 }
            .sorted { (bm25Scores[$0.id] ?? 0) > (bm25Scores[$1.id] ?? 0) }

        var rrfScores: [String: Double] = [:]
        for (rank, doc) in vectorRanked.enumerated() {
            rrfScores[doc.id, default: 0] += weights.vector / (weights.rrfK + Double(rank + 1))
        }
        for (rank, doc) in bm25Ranked.enumerated() {
            rrfScores[doc.id, default: 0] += weights.bm25 / (weights.rrfK + Double(rank + 1))
        }

        return documents
            .map { doc in
                RetrievalHit(
                    document: doc,
                    vectorScore: vectorScores[doc.id],
                    vectorContrast: vectorScores[doc.id].map { $0 - meanCosine },
                    bm25Score: bm25Scores[doc.id] ?? 0,
                    rrfScore: rrfScores[doc.id] ?? 0
                )
            }
            // Primary key is `rrfScore`, NOT `confidence`. A confidence-primary
            // sort was tried (2026-07) to fix one case — "Quick personal loan
            // without any collateral" ranked "BCA Secured Personal Loan" above
            // the correct unsecured "BCA Personal Loan" purely on a keyword-
            // rank artifact — but it regressed others: `confidence`'s semantic
            // term is a corpus-relative CONTRAST clamped to 1.0, and on some
            // embedding backends/queries multiple unrelated documents clamp to
            // the same ceiling, so the sort loses discrimination and a
            // magnitude-noisy document (e.g. a debit card, on a "credit card
            // with airport lounge access" query) can outrank the genuinely
            // relevant one. Measured via scripts/retrieval-eval.sh +
            // RAGSystemTests on-device: RRF fusion here is comparably or MORE
            // accurate than confidence-primary once the category gate
            // (RetrievalPlanner + CategoryTaxonomy) narrows candidates first —
            // scoping fixes cross-category leakage structurally, which is what
            // most confusable-cluster mistakes actually were. The residual
            // same-category near-miss above is a harder, negation-blind-BM25
            // problem for a future, more targeted fix — not a reason to make
            // ranking globally less robust.
            .sorted { lhs, rhs in
                if lhs.rrfScore != rhs.rrfScore { return lhs.rrfScore > rhs.rrfScore }
                if (lhs.vectorScore ?? -2) != (rhs.vectorScore ?? -2) {
                    return (lhs.vectorScore ?? -2) > (rhs.vectorScore ?? -2)
                }
                if lhs.bm25Score != rhs.bm25Score { return lhs.bm25Score > rhs.bm25Score }
                return lhs.document.id < rhs.document.id // deterministic order on full ties
            }
    }
}
