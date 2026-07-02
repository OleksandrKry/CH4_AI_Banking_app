//
//  RAGSystem.swift
//  CH4_AI_Banking_app
//
//  Created by I Gusti Ngurah Bagus Ferry Mahayudha on 02/07/26.
//

import Foundation
import SwiftData
import NaturalLanguage
import FoundationModels

class RAGSystem {
    private var modelContext: ModelContext
    
    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }
    
    // MARK: - Core Hybrid RAG Pipeline Orchestrator
    
    func generateResponse(for userQuery: String) async throws -> String {
        let userMessage = ChatMessage(text: userQuery, isUser: true)
        modelContext.insert(userMessage)
        try? modelContext.save()
        
        // 2. Perform On-Device Hybrid Search (Vector + Keyword BM25)
        let relevantDocs = await searchRelevantDocuments(for: userQuery, limit: 2)
        // FIX: Point mapping closure target to pull the .chunk property value
        let spreadsheetContext = relevantDocs.map { $0.chunk }.joined(separator: "\n")
        
        let conversationHistory = fetchRecentChatHistory(limit: 6)
        var chatTranscript = ""
        for message in conversationHistory {
            let speaker = message.isUser ? "Human" : "Assistant"
            chatTranscript += "\(speaker): \(message.text)\n"
        }
        
        let masterPrompt = """
        You are a professional banking assistant for BCA. 
        Analyze the structural Data Context and Chat History text blocks provided below to answer the user's question accurately.
        
        CRITICAL CONSTRAINTS:
        - Deliver a natural, friendly sentence. No technical syntax or database references.
        - NEVER include raw data delimiters like pipes (|) in your response output.
        - If the context doesn't clarify the answer, politely decline to guess.
        
        Data Context:
        \(spreadsheetContext)
        
        Chat History:
        \(chatTranscript)
        
        Current User Question: \(userQuery)
        
        Answer:
        """
        
        let session = LanguageModelSession()
        let response = try await session.respond(to: masterPrompt)
        let cleanAIResponse = response.content
        
        let aiMessage = ChatMessage(text: cleanAIResponse, isUser: false)
        modelContext.insert(aiMessage)
        try? modelContext.save()
        
        return cleanAIResponse
    }
    
    // MARK: - Dual Hybrid Search Engine Integration
    
    func searchRelevantDocuments(for query: String, limit: Int = 3) async -> [LocalDocument] {
        let documents = fetchLocalDocuments()
        guard !documents.isEmpty else { return [] }
        
        // 1. Setup the decoupled processing engines
        let vectorEngine = VectorSearch(query: query, documents: documents)
        // FIX: Injected contextual initialization states directly into constructor allocation
        let bm25Engine = BM25Search(query: query, documents: documents)
        
        // Track Engine A: Dense Retrieval Vector Track
        guard let vectorSorted = vectorEngine.rankBySimilarity() else {
            print("⚠️ Vector Generation Failed. Falling back exclusively to BM25 text metrics.")
            // FIX: Refactored call to run matching parameterless routine
            return Array(bm25Engine.rankByKeyword().prefix(limit))
        }
        
        // Track Engine B: Sparse Retrieval Keyword Track
        // FIX: Refactored call to run matching parameterless routine
        let bm25Sorted = bm25Engine.rankByKeyword()
        
        // Track Engine C: Score Mixer Loop utilizing Reciprocal Rank Fusion (RRF)
        let rrfScores = reciprocalRankFusion(vectorRanked: vectorSorted, bm25Ranked: bm25Sorted)
        
        let finalRankedList = documents.sorted { (rrfScores[$0.id] ?? 0.0) > (rrfScores[$1.id] ?? 0.0) }
        
        return Array(finalRankedList.prefix(limit))
    }
    
    // MARK: - Mathematical Scoring Matrix Sub-routines
    
    private func reciprocalRankFusion(vectorRanked: [LocalDocument], bm25Ranked: [LocalDocument]) -> [String: Double] {
        var rrfScores: [String: Double] = [:]
        let k: Double = 60.0
        
        for (rank, doc) in vectorRanked.enumerated() {
            let rankPlacement = Double(rank + 1)
            rrfScores[doc.id, default: 0.0] += (1.0 / (k + rankPlacement)) * 0.4
        }
        
        for (rank, doc) in bm25Ranked.enumerated() {
            let rankPlacement = Double(rank + 1)
            rrfScores[doc.id, default: 0.0] += (1.0 / (k + rankPlacement)) * 1.0
        }
        
        return rrfScores
    }
    
    // MARK: - Utilities & Tokenizers
    
    private func fetchLocalDocuments() -> [LocalDocument] {
        let descriptor = FetchDescriptor<LocalDocument>()
        return (try? modelContext.fetch(descriptor)) ?? []
    }
    
    private func fetchRecentChatHistory(limit: Int) -> [ChatMessage] {
        var descriptor = FetchDescriptor<ChatMessage>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.fetchLimit = limit
        let recentDescending = (try? modelContext.fetch(descriptor)) ?? []
        return recentDescending.reversed()
    }
}
