//
//  RAGResult.swift
//  CH4_AI_Banking_app
//
//  Created by I Gusti Ngurah Bagus Ferry Mahayudha on 03/07/26.
//

import Foundation


struct RAGResult {
    let userInput: String                       // Echo of the question that produced this result
    let aiAnswer: String                        // The clean, natural-language assistant answer
    let citedDocuments: [LocalDocument]         // The exact items pulled by the BM25 & Vector engines
    let productCards: [ProductCardInfo]         // UI-facing cards derived from citedDocuments (category + name + one-liner)
    let suggestedFollowUps: [FollowUpQuestion]  // "Questions to users" — the design's inline quiz chips
    let retrievalConfidence: Double?            // Top hit's calibrated confidence (nil when nothing was retrieved)
}
