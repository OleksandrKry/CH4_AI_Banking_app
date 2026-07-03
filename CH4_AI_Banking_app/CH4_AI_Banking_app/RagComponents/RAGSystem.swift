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
        
    /// Processes user input and returns a structured payload containing the clean AI answer and raw source metadata
    func generateResponse(for userQuery: String, userSalary: Double? = nil) async throws -> RAGResult {
        // 1. Commit incoming user query to persistent conversation history
        let userMessage = ChatMessage(text: userQuery, isUser: true)
        modelContext.insert(userMessage)
        try? modelContext.save()
        
        // 2. Perform On-Device Hybrid Search (Vector + Keyword BM25) with Pre-filtering
        let relevantDocs = await searchRelevantDocuments(for: userQuery, userSalary: userSalary, limit: 2)
        let spreadsheetContext = relevantDocs.map { $0.chunk }.joined(separator: "\n")
        
        // 3. Extract recent chat history context to give the model memory hooks
        let conversationHistory = fetchRecentChatHistory(limit: 6)
        var chatTranscript = ""
        for message in conversationHistory {
            let speaker = message.isUser ? "Human" : "Assistant"
            chatTranscript += "\(speaker): \(message.text)\n"
        }
        
        // 4. Draft the master contextual prompt instruction
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
        
        // 5. Fire generation inference request directly to Apple Intelligence
        let session = LanguageModelSession()
        let response = try await session.respond(to: masterPrompt)
        let cleanAIResponse = response.content
        
        // 6. Save the AI's final cleaned statement back to storage memory
        let aiMessage = ChatMessage(text: cleanAIResponse, isUser: false)
        modelContext.insert(aiMessage)
        try? modelContext.save()

        // 7. Derive UI-facing product cards + generate the clarifying "quiz chip" questions
        let productCards = relevantDocs.map(ProductCardInfo.init(document:))
        let followUps = await generateFollowUpQuestions(for: userQuery, context: spreadsheetContext)

        // 8. Wrap the full layout payload the front end needs
        return RAGResult(
            userInput: userQuery,
            aiAnswer: cleanAIResponse,
            citedDocuments: relevantDocs,
            productCards: productCards,
            suggestedFollowUps: followUps
        )
    }

    // MARK: - Clarifying Question Generation (guided generation)

    /// Produces the design's inline quiz chips: up to two short clarifying questions,
    /// each with a few tappable options. Uses guided generation so the output is a
    /// well-formed `[FollowUpQuestion]` with no manual parsing. Returns `[]` on failure.
    private func generateFollowUpQuestions(for query: String, context: String) async -> [FollowUpQuestion] {
        let prompt = """
        You are a BCA banking assistant helping a user narrow down products.
        The user asked: "\(query)"

        Using the product context below, propose up to two SHORT clarifying questions that
        would help you recommend a better product (e.g. budget, intended use, eligibility).
        Each question must offer two to four brief, tappable answer options.
        If the question is already specific enough, return no questions.

        Product Context:
        \(context)
        """

        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt, generating: FollowUpSuggestions.self)
            return response.content.questions
        } catch {
            print("⚠️ Follow-up question generation failed: \(error.localizedDescription)")
            return []
        }
    }
    
    // MARK: - Dual Hybrid Search Engine Integration
    
    func searchRelevantDocuments(for query: String, userSalary: Double? = nil, limit: Int = 3) async -> [LocalDocument] {
        var documents = fetchLocalDocuments()
        guard !documents.isEmpty else { return [] }
        
        // Deterministic Low-Code Pre-Filtering Stage
        if let salary = userSalary {
            documents = documents.filter { doc in
                return doc.minIncome == 0.0 || doc.minIncome <= salary
            }
        }
        
        guard documents.count > limit else { return documents }
        
        let vectorEngine = VectorSearch(query: query, documents: documents)
        let bm25Engine = BM25Search(query: query, documents: documents)
        
        guard let vectorSorted = vectorEngine.rankBySimilarity() else {
            print("⚠️ Vector Generation Failed. Falling back exclusively to BM25 text metrics.")
            return Array(bm25Engine.rankByKeyword().prefix(limit))
        }
        
        let bm25Sorted = bm25Engine.rankByKeyword()
        let rrfScores = reciprocalRankFusion(vectorRanked: vectorSorted, bm25Ranked: bm25Sorted)
        
        let finalRankedList = documents.sorted { (rrfScores[$0.id] ?? 0.0) > (rrfScores[$1.id] ?? 0.0) }
        
        return Array(finalRankedList.prefix(limit))
    }
    
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
    
    // Note: `internal` (not `private`) so the test target can exercise them directly.
    func fetchLocalDocuments() -> [LocalDocument] {
        let descriptor = FetchDescriptor<LocalDocument>()
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func fetchRecentChatHistory(limit: Int) -> [ChatMessage] {
        var descriptor = FetchDescriptor<ChatMessage>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.fetchLimit = limit
        let recentDescending = (try? modelContext.fetch(descriptor)) ?? []
        return recentDescending.reversed()
    }
}
