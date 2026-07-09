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
    /// runs only when the model decides the user needs new products. `approxChars`
    /// tracks context growth toward the 4,096-token window.
    private final class ChatSessionBox {
        var session: LanguageModelSession
        let tool: ProductCatalogTool
        let quizTool: IntakeQuizTool
        let baseChars: Int          // instructions + tool schema estimate
        var approxChars: Int

        init(session: LanguageModelSession, tool: ProductCatalogTool,
             quizTool: IntakeQuizTool, baseChars: Int) {
            self.session = session
            self.tool = tool
            self.quizTool = quizTool
            self.baseChars = baseChars
            self.approxChars = baseChars
        }
    }

    private var chatSessions: [UUID: ChatSessionBox] = [:]
    private static let adHocSessionKey = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// Per-request salary override (tests pass it explicitly); the tool's search
    /// closure reads it, falling back to the stored profile income.
    private var salaryOverride: Double?

    // MARK: - Turn instrumentation (latency + context budget)

    /// Wall-clock breakdown of the last `generateResponse` turn, plus a running
    /// estimate of session context usage (~4 chars/token, 4,096-token window).
    struct TurnMetrics {
        var sessionSetup: Duration = .zero       // session create + prewarm (turn 1)
        var generation: Duration = .zero         // session.respond incl. tool calls
        var retrieval: Duration = .zero          // hybrid search inside the tool
        var questionStructuring: Duration = .zero
        var total: Duration = .zero
        var approxContextTokens: Int = 0

        var summary: String {
            func ms(_ duration: Duration) -> String {
                String(format: "%.0fms", duration / .milliseconds(1))
            }
            return "setup \(ms(sessionSetup)) | respond \(ms(generation)) "
                + "(retrieval \(ms(retrieval))) | structureQ \(ms(questionStructuring)) "
                + "| total \(ms(total)) | ctx ≈ \(approxContextTokens)/4096 tokens"
        }
    }

    /// Metrics of the most recent turn — asserted in tests, printed in DEBUG.
    private(set) var lastTurnMetrics = TurnMetrics()
    private var turnRetrieval: Duration = .zero

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// User-facing text for generation failures — raw error dumps must never
    /// reach the chat (seen in the wild: "GenerationError error -1.").
    static func friendlyFailureMessage(for error: Error) -> String {
        if let generationError = error as? LanguageModelSession.GenerationError {
            switch generationError {
            case .guardrailViolation:
                return "I can't help with that one — I'm BCA's banking assistant. Ask me about cards, accounts, loans, transfers, or payments!"
            case .exceededContextWindowSize:
                return "This conversation has grown too long for me — start a new chat to continue."
            case .rateLimited:
                return "I'm a little busy right now — please try again in a moment."
            case .assetsUnavailable:
                return "The on-device AI model isn't ready yet (it may still be downloading). Please try again shortly."
            default:
                return "Something went wrong on my side — please try sending that again."
            }
        }
        return "Something went wrong on my side — please try sending that again."
    }

    /// Friendly explanation for why Apple Intelligence can't answer at all.
    static func modelUnavailableMessage() -> String {
        switch SystemLanguageModel.default.availability {
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is turned off on this device. Enable it in Settings, then ask me again."
        case .unavailable(.modelNotReady):
            return "The on-device AI model is still getting ready (downloading). Please try again in a few minutes."
        case .unavailable(.deviceNotEligible):
            return "This device doesn't support Apple Intelligence, which I need to answer questions."
        default:
            return "The on-device AI isn't available right now — please try again later."
        }
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
    ///   - intakeContext: the user's answers to the intake questions, folded into
    ///     the first turn's prompt after the sequential question flow completes.
    func generateResponse(
        for userQuery: String,
        userSalary: Double? = nil,
        conversationID: UUID? = nil,
        intakeContext: String? = nil
    ) async throws -> RAGResult {
        let clock = ContinuousClock()
        let turnStart = clock.now
        var metrics = TurnMetrics()

        // 1. Commit incoming user query to persistent conversation history
        let userMessage = ChatMessage(text: userQuery, isUser: true, conversationID: conversationID)
        modelContext.insert(userMessage)
        try? modelContext.save()

        // Graceful degradation: never surface raw framework errors in chat.
        guard SystemLanguageModel.default.isAvailable else {
            let unavailable = Self.modelUnavailableMessage()
            let aiMessage = ChatMessage(text: unavailable, isUser: false, conversationID: conversationID)
            modelContext.insert(aiMessage)
            try? modelContext.save()
            return RAGResult(userInput: userQuery, aiAnswer: unavailable, citedDocuments: [],
                             productCards: [], suggestedFollowUps: [], retrievalConfidence: nil)
        }

        // 2. Per-conversation session: instructions (role, rules, profile, memory,
        //    tool policy) were set once at session creation; the transcript carries
        //    the multi-turn context natively. RAGSystem runs on the main actor
        //    (project default isolation), so tool state is same-actor.
        salaryOverride = userSalary
        let setupStart = clock.now
        let box = chatSession(for: conversationID, firstQuery: userQuery)
        metrics.sessionSetup = setupStart.duration(to: clock.now) // ~0 after turn one
        box.tool.beginTurn()
        box.quizTool.beginTurn()
        turnRetrieval = .zero

        // 3. This turn's message, plus the intake answers on the first real turn.
        let prompt = intakeContext.map {
            "\(userQuery)\n\nMy answers to your clarifying questions:\n\($0)"
        } ?? userQuery

        // 4. Generate. maximumResponseTokens is a hard backstop against a runaway
        //    response; the 3-4 sentence rule in the instructions shapes length.
        let options = GenerationOptions(maximumResponseTokens: 150)
        let generationStart = clock.now
        let cleanAIResponse: String
        do {
            cleanAIResponse = try await box.session.respond(to: prompt, options: options).content
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            // Documented recovery: fresh session seeded with the instructions and
            // the latest exchange (condensed transcript), then retry once.
            let condensed = condensedChatSession(in: box)
            cleanAIResponse = try await condensed.respond(to: prompt, options: options).content
        }
        metrics.generation = generationStart.duration(to: clock.now)
        metrics.retrieval = turnRetrieval

        // 5. Cards, citations, and confidence reflect what the model actually
        //    consulted this turn (empty when it answered from the transcript).
        let retrieved = box.tool.retrievedThisTurn
        let relevantDocs = documents(withIDs: retrieved.map(\.id))

        let aiMessage = ChatMessage(
            text: cleanAIResponse,
            isUser: false,
            conversationID: conversationID,
            citedDocumentIDs: relevantDocs.map(\.id)
        )
        modelContext.insert(aiMessage)
        try? modelContext.save()

        // The model routes the product flow itself: a quiz request this turn
        // (with no products retrieved) hands the questionnaire to the app.
        let quizRequestedFor = relevantDocs.isEmpty ? box.quizTool.requestedNeed : nil

        // 6. When the model asked a decision-tree qualifying question in TEXT
        //    instead (no products, no questionnaire), structure it via one-shot
        //    guided generation so the UI renders tappable option rows.
        var followUps: [FollowUpQuestion] = []
        if relevantDocs.isEmpty, quizRequestedFor == nil, cleanAIResponse.contains("?") {
            let structuringStart = clock.now
            let structurePrompt = """
            A banking assistant asked the user this qualifying question:
            "\(cleanAIResponse)"
            Extract the single question (short) and 2 to 4 brief tappable options for it.
            """
            if let structured = try? await LanguageModelSession()
                .respond(to: structurePrompt,
                         generating: FollowUpQuestion.self,
                         options: GenerationOptions(sampling: .greedy)).content {
                followUps = [structured]
            }
            metrics.questionStructuring = structuringStart.duration(to: clock.now)
        }

        // Context budget: prompt + reply + tool output land in the transcript.
        box.approxChars += prompt.count + cleanAIResponse.count + box.tool.outputCharsThisTurn
        metrics.approxContextTokens = box.approxChars / 4
        metrics.total = turnStart.duration(to: clock.now)
        lastTurnMetrics = metrics
        #if DEBUG
        print("⏱ turn: " + metrics.summary)
        #endif

        return RAGResult(
            userInput: userQuery,
            aiAnswer: cleanAIResponse,
            citedDocuments: relevantDocs,
            productCards: relevantDocs.map(ProductCardInfo.init(document:)),
            suggestedFollowUps: followUps,
            retrievalConfidence: retrieved.map(\.confidence).max(),
            quizRequestedFor: quizRequestedFor
        )
    }

    /// Generates the intake question batch ONCE per conversation: 3–6 decision-
    /// tree-grounded clarifying questions (shape enforced by constrained
    /// decoding), presented to the user one at a time with no further model
    /// calls. Returns `[]` on failure — the caller then answers directly.
    func generateIntakeQuestions(for query: String) async -> [FollowUpQuestion] {
        guard SystemLanguageModel.default.isAvailable else { return [] }
        let profileBlock = fetchUserProfile()?.promptSummary ?? "No profile information provided."

        let prompt = """
        You are a BCA banking assistant. A user just asked: "\(query)"

        You already know this about the user:
        \(profileBlock)

        Using the decision tree below, generate 3 to 6 short clarifying questions
        (most important first) that locate this user's need precisely enough to
        recommend specific products. Walk the relevant branch: category first when
        the request is broad, then the branch's qualifiers (use, amount, tenor).
        Never re-ask what the profile already answers. Each question offers two to
        four brief options; the user can also type their own answer or skip.

        \(BankingDecisionTree.instructionsBlock)
        """

        do {
            let session = LanguageModelSession()
            let response = try await session.respond(
                to: prompt,
                generating: FollowUpSuggestions.self,
                options: GenerationOptions(sampling: .greedy)
            )
            return response.content.questions
        } catch {
            print("⚠️ Intake question generation failed: \(error)")
            return []
        }
    }

    /// Labels the conversation with a decision-tree category via guided
    /// generation (constrained decoding always yields a valid case). Purely for
    /// history/memory labeling — flow ROUTING is the session model's tool choice.
    /// Falls back to the retrieval majority vote when the model is unavailable.
    func classifyIntentCategory(for query: String) async -> String {
        guard SystemLanguageModel.default.isAvailable else {
            return await classifyCategory(for: query)
        }

        let clock = ContinuousClock()
        let start = clock.now
        let prompt = """
        Classify this BCA banking request into the single best-fitting category.
        Use "General" only when nothing else fits.
        Request: "\(query)"
        """

        do {
            let session = LanguageModelSession()
            let category = try await session.respond(
                to: prompt,
                generating: IntentCategory.self,
                options: GenerationOptions(sampling: .greedy)
            ).content
            #if DEBUG
            print(String(format: "⏱ classify %.0fms → %@",
                         start.duration(to: clock.now) / .milliseconds(1), category.rawValue))
            #endif
            return category.rawValue
        } catch {
            print("⚠️ Category classification failed (\(error)); falling back to retrieval vote.")
            return await classifyCategory(for: query)
        }
    }

    // MARK: - Chat session lifecycle

    /// Returns (creating and prewarming if needed) the persistent session for a
    /// conversation. Instructions are built ONCE per session — profile, memories,
    /// tool policy — instead of being re-tokenized on every turn.
    private func chatSession(
        for conversationID: UUID?,
        firstQuery: String
    ) -> ChatSessionBox {
        let key = conversationID ?? Self.adHocSessionKey
        if let existing = chatSessions[key] { return existing }

        let tool = ProductCatalogTool { [weak self] query in
            guard let self else { return [] }
            let retrievalStart = ContinuousClock.now
            defer { self.turnRetrieval += retrievalStart.duration(to: ContinuousClock.now) }
            let salary = self.salaryOverride
                ?? (self.fetchUserProfile().map { $0.monthlyIncome > 0 ? $0.monthlyIncome : nil } ?? nil)
            let hits = self.scoredSearchCore(for: query, userSalary: salary, limit: 2)
                .filter { $0.confidence >= HybridRetriever.minimumConfidence }
            // Weak trailing hits neither ground the model nor become cards —
            // a second product that "doesn't fit" is worse than one good answer.
            return HybridRetriever.cardworthyHits(hits)
        }

        let quizTool = IntakeQuizTool()
        let instructions = chatInstructions(for: conversationID, firstQuery: firstQuery)
        let session = LanguageModelSession(tools: [tool, quizTool], instructions: instructions)
        session.prewarm()

        // ~800 chars covers the injected tool schemas + framing overhead.
        let box = ChatSessionBox(session: session, tool: tool, quizTool: quizTool,
                                 baseChars: instructions.count + 800)
        chatSessions[key] = box
        #if DEBUG
        print("🧾 session instructions ≈ \(box.baseChars / 4) tokens")
        #endif
        return box
    }

    /// Static per-conversation guidance: role + answer rules + tool policy +
    /// profile + memory, plus a short recap when resuming a stored conversation
    /// (a fresh session has no transcript for it).
    private func chatInstructions(for conversationID: UUID?, firstQuery: String) -> String {
        let profileBlock = fetchUserProfile()?.promptSummary ?? "No profile information provided."

        // Context budget: memories capped at 2 one-liners, recap at 4 messages
        // truncated to ~140 chars each (the 4,096-token window is shared with
        // the decision tree, tool outputs, and every turn of the conversation).
        let memories = fetchRelevantMemories(for: firstQuery, excluding: conversationID, limit: 2)
        let memoryBlock = memories.isEmpty
            ? ""
            : "\nRelevant past conversations (memory):\n" + memories.map { "- \($0)" }.joined(separator: "\n") + "\n"

        var recapBlock = ""
        if let conversationID {
            let recent = fetchRecentChatHistory(limit: 4, conversationID: conversationID)
            if !recent.isEmpty {
                recapBlock = "\nEarlier in this conversation:\n" + recent
                    .map { "\($0.isUser ? "User" : "Assistant"): \($0.text.prefix(140))" }
                    .joined(separator: "\n") + "\n"
            }
        }

        return """
        You are a professional banking assistant for BCA.

        EVERY TURN, pick exactly ONE move:
        1. Greeting, chit-chat, or a question about you, the bank, or how something works → answer in text, NO tools. (Who are you? → BCA's banking assistant: ask about banking products and you get answers and suggestions. No real-time data like time or weather — say so briefly and offer banking help.)
        2. The user wants a banking product or service but their need is still VAGUE (no use-case or feature named, preferences unknown) → call askQualifyingQuestions with their need.
        3. The need is SPECIFIC (a feature, use-case, or product is named — e.g. "card with lounge access", "loan to renovate my house"), the questionnaire answers just arrived, or the user asks for new/different products → call searchProductCatalog and answer from its results.
        4. The user refers to products already shown ("that card", "the first one", "its fee") → answer from the conversation, NO tools.

        ANSWER RULES:
        - 3-4 sentences maximum, friendly and natural, in the user's language; never output pipe (|) characters or technical syntax.
        - Recommend ONLY products the searchProductCatalog tool returned in this conversation — never invent products, never repeat tool output verbatim.
        - If the tool found nothing relevant, say so politely; do not guess.
        - Use the User Profile below; never re-ask what it already answers (e.g. income, occupation).

        \(BankingDecisionTree.instructionsBlock)

        User Profile:
        \(profileBlock)
        \(memoryBlock)\(recapBlock)
        """
    }

    /// Apple's documented context-window recovery: keep the first transcript entry
    /// (instructions) and the last, drop the middle, and continue on a new session.
    private func condensedChatSession(in box: ChatSessionBox) -> LanguageModelSession {
        let entries = [box.session.transcript.first, box.session.transcript.last].compactMap { $0 }
        let fresh = LanguageModelSession(tools: [box.tool, box.quizTool],
                                         transcript: Transcript(entries: entries))
        box.session = fresh
        box.approxChars = box.baseChars + 800 // instructions + roughly one exchange
        return fresh
    }

    /// Builds + prewarms the session ahead of time so the KV cache is hot before
    /// the first answer of a conversation.
    func warmChatSession(for conversationID: UUID?, firstQuery: String) {
        _ = chatSession(for: conversationID, firstQuery: firstQuery)
    }

    /// Drops a cached session (conversation finished, replaced, or reloaded —
    /// a reloaded conversation gets a new session with a transcript recap).
    func discardChatSession(for conversationID: UUID?) {
        chatSessions[conversationID ?? Self.adHocSessionKey] = nil
    }

    // MARK: - Category classification (labels conversations for history + memory)

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
