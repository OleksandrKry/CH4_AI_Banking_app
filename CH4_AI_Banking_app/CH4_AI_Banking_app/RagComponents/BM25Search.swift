//
//  BM25Search.swift
//  CH4_AI_Banking_app
//
//  Created by I Gusti Ngurah Bagus Ferry Mahayudha on 02/07/26.
//

import Foundation

class BM25Search {
    
    // 1. Define instance state variables
    private var query: String
    private var documents: [LocalDocument]
    
    // 2. Initialize with injected context parameters, matching VectorSearch pattern
    init(query: String, documents: [LocalDocument]) {
        self.query = query
        self.documents = documents
    }

    private func tokenize(_ text: String) -> [String] {
        let cleanText = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        return cleanText.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    
    // FIX: Removed 'private' keyword and renamed to reflect parameterless context tracking
    func rankByKeyword() -> [LocalDocument] {
        let queryTerms = tokenize(query)
        guard !queryTerms.isEmpty else { return documents }
        
        let totalDocs = Double(documents.count)
        var docTokens: [String: [String]] = [:]
        var totalLength: Double = 0.0
        var documentFrequencies: [String: Double] = [:]
        
        for doc in documents {
            // FIX: Map tokenizer target directly to your contextually built narrative chunk string
            let tokens = tokenize(doc.chunk)
            docTokens[doc.id] = tokens
            totalLength += Double(tokens.count)
            for uniqueTerm in Set(tokens) {
                documentFrequencies[uniqueTerm, default: 0.0] += 1.0
            }
        }
        
        let avgdl = totalLength / totalDocs
        let k1: Double = 1.5
        let b: Double = 0.75
        var scores: [String: Double] = [:]
        
        for doc in documents {
            let tokens = docTokens[doc.id] ?? []
            let docLen = Double(tokens.count)
            var docScore = 0.0
            
            var termFrequencies: [String: Double] = [:]
            for token in tokens { termFrequencies[token, default: 0.0] += 1.0 }
            
            for term in queryTerms {
                guard let tf = termFrequencies[term], tf > 0 else { continue }
                let df = documentFrequencies[term] ?? 0.0
                let idf = log((totalDocs - df + 0.5) / (df + 0.5) + 1.0)
                
                let numerator = tf * (k1 + 1.0)
                let denominator = tf + k1 * (1.0 - b + b * (docLen / avgdl))
                docScore += idf * (numerator / denominator)
            }
            scores[doc.id] = docScore
        }
        
        return documents.sorted { (scores[$0.id] ?? 0.0) > (scores[$1.id] ?? 0.0) }
    }
}
