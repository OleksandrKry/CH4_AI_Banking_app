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
        
    /// The "answer" step (loop phase): retrieve, generate the assistant reply, persist it, and
    /// return the UI payload. The quiz now happens at *intake* (see beginIntake), not after the answer.
    ///
    /// - Parameters:
    ///   - conversationID: scopes persisted messages + history to one conversation.
    ///   - intakeContext: the user's quiz answers for this request, injected into the prompt.
    func generateResponse(
        for userQuery: String,
        userSalary: Double? = nil,
        conversationID: UUID? = nil,
        intakeContext: String? = nil
    ) async throws -> RAGResult {
        // 1. Commit incoming user query to persistent conversation history
        let userMessage = ChatMessage(text: userQuery, isUser: true, conversationID: conversationID)
        modelContext.insert(userMessage)
        try? modelContext.save()

        // 2. Load durable profile so recommendations are personalized + pre-qualified.
        //    An explicit userSalary argument still wins (used by tests); otherwise use the profile's income.
        let profile = fetchUserProfile()
        let effectiveSalary = userSalary ?? (profile.map { $0.monthlyIncome > 0 ? $0.monthlyIncome : nil } ?? nil)
        let profileBlock = profile?.promptSummary ?? "No profile information provided."

        // Long-term memory: the most relevant past finished conversations (by similarity).
        let memories = fetchRelevantMemories(for: userQuery, excluding: conversationID)
        let memoryBlock = memories.isEmpty
            ? ""
            : "\nRelevant past conversations (memory):\n" + memories.map { "- \($0)" }.joined(separator: "\n") + "\n"

        // 3. Perform On-Device Hybrid Search (Vector + Keyword BM25) with Pre-filtering
        let relevantDocs = await searchRelevantDocuments(for: userQuery, userSalary: effectiveSalary, limit: 2)
        let spreadsheetContext = relevantDocs.map { $0.chunk }.joined(separator: "\n")

        // 4. Recent chat history, scoped to this conversation when provided
        let conversationHistory = fetchRecentChatHistory(limit: 6, conversationID: conversationID)
        var chatTranscript = ""
        for message in conversationHistory {
            let speaker = message.isUser ? "Human" : "Assistant"
            chatTranscript += "\(speaker): \(message.text)\n"
        }

        // 5. Draft the master contextual prompt instruction
        let intakeBlock = intakeContext.map { "\nUser's quiz answers for this request:\n\($0)\n" } ?? ""
        let masterPrompt = """
        You are a professional banking assistant for BCA.
        Analyze the User Profile, the user's quiz answers, structural Data Context, and Chat History to answer accurately.

        CRITICAL CONSTRAINTS:
        - Keep your answer to 3-4 sentences maximum. Be concise: answer only what was asked and do not volunteer unrelated products, caveats, or extra detail. Make sure that the sentences are understandable.
        - Deliver a natural, friendly answer. No technical syntax or database references.
        - NEVER include raw data delimiters like pipes (|) in your response output.
        - Tailor the recommendation to the User Profile and quiz answers when relevant.
        - Please response to user prompted language, whatever it is respectively.
        - If the context doesn't clarify the answer, politely decline to guess.

        User Profile:
        \(profileBlock)
        \(memoryBlock)\(intakeBlock)
        Data Context:
        \(spreadsheetContext)

        Chat History:
        \(chatTranscript)

        Current User Question: \(userQuery)

        Answer:
        """

        // 6. Fire generation inference request directly to Apple Intelligence.
        //    The 3-4 sentence instruction shapes length; maximumResponseTokens is a
        //    hard backstop against a runaway response (set with headroom to avoid
        //    truncating mid-sentence).
        let session = LanguageModelSession()
        let response = try await session.respond(
            to: masterPrompt,
            options: GenerationOptions(maximumResponseTokens: 150)
        )
        let cleanAIResponse = response.content

        // 7. Save the AI's final cleaned statement back to storage memory,
        //    tagging which products it cited so cards can be rebuilt on reload.
        let aiMessage = ChatMessage(
            text: cleanAIResponse,
            isUser: false,
            conversationID: conversationID,
            citedDocumentIDs: relevantDocs.map(\.id)
        )
        modelContext.insert(aiMessage)
        try? modelContext.save()

        // 8. Derive UI-facing product cards (the quiz lives at intake now, so no post-answer chips)
        let productCards = relevantDocs.map(ProductCardInfo.init(document:))

        return RAGResult(
            userInput: userQuery,
            aiAnswer: cleanAIResponse,
            citedDocuments: relevantDocs,
            productCards: productCards,
            suggestedFollowUps: []
        )
    }

    // MARK: - Intake: category classification + dynamic quiz generation

    /// Classifies a query into a product category by reusing the retrieval we already run:
    /// the majority category among the top hits. No CoreML, no extra model call. Returns ""
    /// when nothing relevant is found (query too vague to classify).
    func classifyCategory(for query: String) async -> String {
        let profile = fetchUserProfile()
        let salary = profile.map { $0.monthlyIncome > 0 ? $0.monthlyIncome : nil } ?? nil
        let top = await searchRelevantDocuments(for: query, userSalary: salary, limit: 5)
        guard !top.isEmpty else { return "" }

        let counts = Dictionary(grouping: top, by: { $0.category }).mapValues(\.count)
        return counts.max { $0.value < $1.value }?.key ?? top[0].category
    }

    /// Generates the minimal category-specific intake quiz (0–3 questions) via guided generation.
    /// Seeded with what we already know (durable profile) so it doesn't re-ask occupation/income.
    /// Returns `[]` when no clarification is needed or on failure — the caller then answers directly.
    func generateIntakeQuiz(for query: String, category: String) async -> [FollowUpQuestion] {
        let profileBlock = fetchUserProfile()?.promptSummary ?? "No profile information provided."
        let categoryLabel = category.isEmpty ? "banking" : category

        let prompt = """
        You are a BCA banking assistant preparing to recommend products in the "\(categoryLabel)" category.
        The user asked: "\(query)"

        You already know this about the user:
        \(profileBlock)

        Generate the MINIMUM set of short clarifying questions (0 to 3) needed to recommend a good
        "\(categoryLabel)" product. Only ask what actually changes the recommendation for THIS category
        (e.g. intended use, amount, tenor, travel frequency). Do NOT re-ask occupation or income —
        those are already known. Each question must offer two to four brief, tappable options.
        If no clarification is needed, return no questions.
        """

        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt, generating: FollowUpSuggestions.self)
            return response.content.questions
        } catch {
            print("⚠️ Intake quiz generation failed: \(error.localizedDescription)")
            return []
        }
    }
    
    // MARK: - Long-term memory (past conversations)

    /// Returns the most relevant finished-conversation summaries for a query. Pulls a recent
    /// pool of finished conversations, then ranks them by embedding similarity to the query
    /// (falling back to most-recent if the embedding model is unavailable).
    func fetchRelevantMemories(for query: String, excluding currentID: UUID?, limit: Int = 3, poolSize: Int = 20) -> [String] {
        var descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.phaseRaw == "finished" && $0.summary != "" },
            sortBy: [SortDescriptor(\.finishedAt, order: .reverse)]
        )
        descriptor.fetchLimit = poolSize
        var pool = (try? modelContext.fetch(descriptor)) ?? []
        if let currentID { pool.removeAll { $0.id == currentID } }
        guard !pool.isEmpty else { return [] }

        guard let queryVector = ContextualEmbedder.shared.vector(for: query) else {
            return Array(pool.prefix(limit)).map(\.summary) // embedder not ready → fall back to recency
        }

        let ranked = pool
            .compactMap { convo -> (summary: String, score: Double)? in
                guard let vector = ContextualEmbedder.shared.vector(for: convo.summary) else { return nil }
                return (convo.summary, VectorMath.cosineSimilarity(queryVector, vector))
            }
            .sorted { $0.score > $1.score }

        return ranked.prefix(limit).map(\.summary)
    }

    /// Generates a one-line recap of a conversation, stored on the Conversation at Finish and
    /// later surfaced as memory. Falls back to the opening user message if generation fails.
    func summarizeConversation(id: UUID, category: String) async -> String {
        let messages = fetchMessages(conversationID: id)
        guard !messages.isEmpty else { return "" }

        let transcript = messages
            .map { "\($0.isUser ? "User" : "Assistant"): \($0.text)" }
            .joined(separator: "\n")

        let prompt = """
        Summarize this banking assistant conversation in ONE short sentence (under 25 words) for future reference.
        Include the product category, what the user wanted, and any product they settled on. No preamble.

        Category: \(category.isEmpty ? "unknown" : category)
        Conversation:
        \(transcript)

        Summary:
        """

        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt)
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            print("⚠️ Summary generation failed: \(error.localizedDescription)")
            return messages.first(where: { $0.isUser })?.text ?? ""
        }
    }

    /// All messages for a conversation, oldest first — used to rehydrate a reopened conversation.
    func fetchMessages(conversationID: UUID) -> [ChatMessage] {
        let descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.conversationID == conversationID },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Looks up documents by id (used to rebuild product cards for a reloaded reply).
    func documents(withIDs ids: [String]) -> [LocalDocument] {
        guard !ids.isEmpty else { return [] }
        let idSet = Set(ids)
        let all = fetchLocalDocuments().filter { idSet.contains($0.id) }
        // Preserve the original cited order.
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
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

    func fetchRecentChatHistory(limit: Int, conversationID: UUID? = nil) -> [ChatMessage] {
        var descriptor: FetchDescriptor<ChatMessage>
        if let conversationID {
            descriptor = FetchDescriptor<ChatMessage>(
                predicate: #Predicate { $0.conversationID == conversationID },
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
            )
        } else {
            descriptor = FetchDescriptor<ChatMessage>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        }
        descriptor.fetchLimit = limit
        let recentDescending = (try? modelContext.fetch(descriptor)) ?? []
        return recentDescending.reversed()
    }

    /// The most recently updated completed onboarding profile, if any.
    func fetchUserProfile() -> UserProfile? {
        var descriptor = FetchDescriptor<UserProfile>(
            predicate: #Predicate { $0.isComplete },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }
}
