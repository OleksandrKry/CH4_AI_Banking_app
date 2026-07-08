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

    /// One persistent FoundationModels session per conversation. The session owns
    /// the transcript (native multi-turn memory) and the catalog tool — retrieval
    /// runs only when the model decides the user needs new products.
    private var chatSessions: [UUID: (session: LanguageModelSession, tool: ProductCatalogTool)] = [:]
    private static let adHocSessionKey = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// Per-request salary override (tests pass it explicitly); the tool's search
    /// closure reads it, falling back to the stored profile income.
    private var salaryOverride: Double?

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Core RAG Orchestrator (session + tool calling)

    /// The "answer" step (loop phase): generate the assistant reply on the
    /// conversation's persistent session, persist it, and return the UI payload.
    /// Retrieval happens INSIDE generation via `ProductCatalogTool` — the model
    /// calls it for new-product requests and answers follow-ups about
    /// already-shown products from the transcript.
    ///
    /// - Parameters:
    ///   - conversationID: scopes persisted messages + the session to one conversation.
    ///   - intakeContext: the user's quiz answers, appended to the first turn's prompt.
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

        // 2. Per-conversation session: instructions (role, rules, profile, memory,
        //    tool policy) were set once at session creation; the transcript carries
        //    the multi-turn context natively.
        salaryOverride = userSalary
        let (session, tool) = chatSession(for: conversationID, firstQuery: userQuery)
        await tool.beginTurn()

        // 3. The prompt is just this turn: the query, plus quiz answers on turn one.
        let prompt = intakeContext.map {
            "\(userQuery)\n\nMy answers to your clarifying questions:\n\($0)"
        } ?? userQuery

        // 4. Generate. maximumResponseTokens is a hard backstop against a runaway
        //    response; the 3-4 sentence rule in the instructions shapes length.
        let options = GenerationOptions(maximumResponseTokens: 150)
        let cleanAIResponse: String
        do {
            cleanAIResponse = try await session.respond(to: prompt, options: options).content
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            // Documented recovery: fresh session seeded with the instructions and
            // the latest exchange (condensed transcript), then retry once.
            let condensed = condensedChatSession(for: conversationID, from: session, tool: tool)
            cleanAIResponse = try await condensed.respond(to: prompt, options: options).content
        }

        // 5. Cards, citations, and confidence reflect what the model actually
        //    consulted this turn (empty when it answered from the transcript).
        let retrieved = await MainActor.run { tool.retrievedThisTurn }
        let relevantDocs = documents(withIDs: retrieved.map(\.id))

        let aiMessage = ChatMessage(
            text: cleanAIResponse,
            isUser: false,
            conversationID: conversationID,
            citedDocumentIDs: relevantDocs.map(\.id)
        )
        modelContext.insert(aiMessage)
        try? modelContext.save()

        return RAGResult(
            userInput: userQuery,
            aiAnswer: cleanAIResponse,
            citedDocuments: relevantDocs,
            productCards: relevantDocs.map(ProductCardInfo.init(document:)),
            suggestedFollowUps: [],
            retrievalConfidence: retrieved.map(\.confidence).max()
        )
    }

    // MARK: - Chat session lifecycle

    /// Returns (creating and prewarming if needed) the persistent session for a
    /// conversation. Instructions are built ONCE per session — profile, memories,
    /// tool policy — instead of being re-tokenized on every turn.
    private func chatSession(
        for conversationID: UUID?,
        firstQuery: String
    ) -> (session: LanguageModelSession, tool: ProductCatalogTool) {
        let key = conversationID ?? Self.adHocSessionKey
        if let existing = chatSessions[key] { return existing }

        let tool = ProductCatalogTool { [weak self] query in
            guard let self else { return [] }
            let salary = self.salaryOverride
                ?? (self.fetchUserProfile().map { $0.monthlyIncome > 0 ? $0.monthlyIncome : nil } ?? nil)
            return self.scoredSearchCore(for: query, userSalary: salary, limit: 2)
                .filter { $0.confidence >= HybridRetriever.minimumConfidence }
        }

        let session = LanguageModelSession(
            tools: [tool],
            instructions: chatInstructions(for: conversationID, firstQuery: firstQuery)
        )
        session.prewarm()
        chatSessions[key] = (session, tool)
        return (session, tool)
    }

    /// Static per-conversation guidance: role + answer rules + tool policy +
    /// profile + memory, plus a short recap when resuming a stored conversation
    /// (a fresh session has no transcript for it).
    private func chatInstructions(for conversationID: UUID?, firstQuery: String) -> String {
        let profileBlock = fetchUserProfile()?.promptSummary ?? "No profile information provided."

        let memories = fetchRelevantMemories(for: firstQuery, excluding: conversationID)
        let memoryBlock = memories.isEmpty
            ? ""
            : "\nRelevant past conversations (memory):\n" + memories.map { "- \($0)" }.joined(separator: "\n") + "\n"

        var recapBlock = ""
        if let conversationID {
            let recent = fetchRecentChatHistory(limit: 6, conversationID: conversationID)
            if !recent.isEmpty {
                recapBlock = "\nEarlier in this conversation:\n"
                    + recent.map { "\($0.isUser ? "User" : "Assistant"): \($0.text)" }.joined(separator: "\n") + "\n"
            }
        }

        return """
        You are a professional banking assistant for BCA.

        CRITICAL CONSTRAINTS:
        - Keep your answer to 3-4 sentences maximum. Be concise: answer only what was asked and do not volunteer unrelated products, caveats, or extra detail. Make sure the sentences are understandable.
        - Deliver a natural, friendly answer. No technical syntax, database references, or raw delimiters like pipes (|).
        - Respond in the user's language, whatever it is.
        - Recommend ONLY products returned by the searchProductCatalog tool in this conversation. Call the tool when the user asks for a recommendation or about new or different products. Do NOT call it for questions about products already discussed — answer those from the conversation.
        - Tailor recommendations to the User Profile and the user's quiz answers when relevant.
        - If no relevant product was found, politely decline to guess.

        User Profile:
        \(profileBlock)
        \(memoryBlock)\(recapBlock)
        """
    }

    /// Apple's documented context-window recovery: keep the first transcript entry
    /// (instructions) and the last, drop the middle, and continue on a new session.
    private func condensedChatSession(
        for conversationID: UUID?,
        from session: LanguageModelSession,
        tool: ProductCatalogTool
    ) -> LanguageModelSession {
        let entries = [session.transcript.first, session.transcript.last].compactMap { $0 }
        let fresh = LanguageModelSession(tools: [tool], transcript: Transcript(entries: entries))
        chatSessions[conversationID ?? Self.adHocSessionKey] = (fresh, tool)
        return fresh
    }

    /// Builds + prewarms the session ahead of time (called while the user fills
    /// the intake quiz, so the KV cache is hot before the first answer).
    func warmChatSession(for conversationID: UUID?, firstQuery: String) {
        _ = chatSession(for: conversationID, firstQuery: firstQuery)
    }

    /// Drops a cached session (conversation finished, replaced, or reloaded —
    /// a reloaded conversation gets a new session with a transcript recap).
    func discardChatSession(for conversationID: UUID?) {
        chatSessions[conversationID ?? Self.adHocSessionKey] = nil
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

    /// Generates the category-specific intake quiz (3–6 questions, shape enforced by
    /// constrained decoding) — the questions the user answers BEFORE the first
    /// recommendation. Seeded with what we already know (durable profile) so it
    /// doesn't re-ask occupation/income. Returns `[]` only on generation failure —
    /// the caller then answers directly without a quiz.
    func generateIntakeQuiz(for query: String, category: String) async -> [FollowUpQuestion] {
        let profileBlock = fetchUserProfile()?.promptSummary ?? "No profile information provided."
        let categoryLabel = category.isEmpty ? "banking" : category

        let focusLine = category.isEmpty
            ? "The query is broad, so the FIRST question must ask which product category they need (e.g. loan, savings, card, investment, transfers)."
            : "Only ask what actually changes the recommendation within \"\(categoryLabel)\" (e.g. intended use, amount, tenor, travel frequency)."

        let prompt = """
        You are a BCA banking assistant preparing to recommend products in the "\(categoryLabel)" category.
        The user asked: "\(query)"

        You already know this about the user:
        \(profileBlock)

        Generate 3 to 6 short clarifying questions to gather the context needed for a precise
        recommendation, ordered most important first. \(focusLine)
        Do NOT re-ask occupation or income — those are already known. Each question offers two to
        four brief, tappable options covering the most common answers; the user can also type
        their own answer or skip a question, so options don't need to be exhaustive.
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
        await scoredSearch(for: query, userSalary: userSalary, limit: limit).map(\.document)
    }

    /// Scored hybrid search — the retrieval entry point. Returns the top hits with
    /// their cosine/BM25/RRF scores and calibrated confidence so callers can
    /// threshold, log, and evaluate retrieval instead of trusting bare documents.
    /// The ranking itself lives in `HybridRetriever` (shared with the eval harness).
    func scoredSearch(for query: String, userSalary: Double? = nil, limit: Int = 3) async -> [RetrievalHit] {
        scoredSearchCore(for: query, userSalary: userSalary, limit: limit)
    }

    /// Synchronous core of `scoredSearch` — also called by `ProductCatalogTool`
    /// from inside a generation turn (on the main actor).
    func scoredSearchCore(for query: String, userSalary: Double? = nil, limit: Int = 3) -> [RetrievalHit] {
        var documents = fetchLocalDocuments()
        guard !documents.isEmpty else { return [] }

        // Deterministic Low-Code Pre-Filtering Stage
        if let salary = userSalary {
            documents = documents.filter { doc in
                return doc.minIncome == 0.0 || doc.minIncome <= salary
            }
        }

        let hits = HybridRetriever.rank(
            query: query,
            documents: documents,
            activeEmbeddingTag: ContextualEmbedder.shared.indexTag
        )

        #if DEBUG
        for hit in hits.prefix(limit) {
            let cosine = hit.vectorScore.map { String(format: "%.3f", $0) } ?? "  n/a"
            print(String(format: "🔎 conf %.2f | cos %@ | bm25 %5.2f | %@",
                         hit.confidence, cosine, hit.bm25Score,
                         ProductCardInfo(document: hit.document).name))
        }
        #endif

        return Array(hits.prefix(limit))
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
