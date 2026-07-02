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
    
    /// Computes the semantic angle distance between two raw floating-point vector arrays
    private func cosineSimilarity(_ v1: [Double], _ v2: [Double]) -> Double {
        guard v1.count == v2.count, !v1.isEmpty else { return 0 }
        let dotProduct = zip(v1, v2).map(*).reduce(0, +)
        let magnitude1 = sqrt(v1.map { $0 * $0 }.reduce(0, +))
        let magnitude2 = sqrt(v2.map { $0 * $0 }.reduce(0, +))
        return dotProduct / (magnitude1 * magnitude2)
    }
    
    /// Generates the native 512-dimension sentence vector using the device OS kernel
    private func getNativeEmbedding(for text: String) -> [Double]? {
        guard let sentenceEmbedding = NLEmbedding.sentenceEmbedding(for: .english) else { return nil }
        return sentenceEmbedding.vector(for: text)
    }
    
    /// Ranks documents by vector similarity. Returns nil if the embedding model fails to initialize.
    func rankBySimilarity() -> [LocalDocument]? {
        // FIX: Safely unwrap the query vector generation step
        guard let queryEmbedding = getNativeEmbedding(for: query) else {
            return nil
        }
        
        // FIX: Correctly sort and return the matched array elements
        return documents.sorted { doc1, doc2 in
            return cosineSimilarity(queryEmbedding, doc1.embedding) > cosineSimilarity(queryEmbedding, doc2.embedding)
        }
    }
}
