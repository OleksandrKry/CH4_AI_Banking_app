//
//  VectorSearch.swift
//  CH4_AI_Banking_app
//
//  Created by I Gusti Ngurah Bagus Ferry Mahayudha on 02/07/26.
//

import Foundation
import NaturalLanguage

class VectorSearch {
    
    private var query: String
    private var documents: [LocalDocument] 
    
    init(query: String, documents: [LocalDocument]) {
        self.query = query
        self.documents = documents
    }
    
    /// Generates a mean-pooled contextual sentence vector for the text.
    private func getNativeEmbedding(for text: String) -> [Double]? {
        // Transformer-based contextual embedding, loaded once at launch.
        return ContextualEmbedder.shared.vector(for: text)
    }

    /// Ranks documents by cosine similarity to the query (a nearest-neighbour search).
    /// Returns `nil` if the on-device embedding model fails to initialize.
    func rankBySimilarity() -> [LocalDocument]? {
        // Safely unwrap the query vector generation step.
        guard let queryEmbedding = getNativeEmbedding(for: query) else {
            return nil
        }

        // Score every document exactly once, then sort by that cached score.
        // (The previous version recomputed the similarity — and the query's
        // magnitude — twice per comparison inside `sorted`, which is wasteful.)
        let scored = documents.map { doc in
            (document: doc, score: VectorMath.cosineSimilarity(queryEmbedding, doc.embedding))
        }
        return scored
            .sorted { $0.score > $1.score }
            .map { $0.document }
    }
}
