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
    /// Calibrated on the golden set (ctx | distilled | 0.4/1, 2026-07): all 22
    /// positives scored ≥ 0.35 and all 3 out-of-scope negatives ≤ 0.34. The floor
    /// `HybridRetriever.minimumConfidence` is tied to this definition —
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
    /// 0.25 sits under the weakest golden-set positive (0.35) with margin, so it
    /// only drops clearly-ungrounded hits (no keyword match AND no cosine
    /// contrast). Word-collision negatives (e.g. "visa requirements" vs. Visa
    /// cards) are indistinguishable at the retrieval layer by design — the master
    /// prompt's decline instruction handles those with the context in view.
    static let minimumConfidence = 0.25

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
