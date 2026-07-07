//
//  RAGSystemTests.swift
//  CH4_AI_Banking_appTests
//
//  Integration tests for the RAG orchestrator, seeded from the real
//  `bca-products.json` corpus via the same production pipeline the app uses
//  (RawRow decode -> buildContextualChunk -> NLEmbedding). These use an
//  in-memory SwiftData container and (where noted) the on-device Foundation
//  model, so they are slower and only partly deterministic — kept separate
//  from the pure unit tests.
//

import Testing
import Foundation
import SwiftData
import NaturalLanguage
import FoundationModels
@testable import CH4_AI_Banking_app

@MainActor
struct RAGSystemTests {

    // MARK: - Fixture loading

    /// Locates the real JSON in the source tree relative to this test file.
    ///
    /// We resolve it from `#filePath` rather than a bundle because the JSON is a
    /// member of the *app* target, not the test target — this keeps the test
    /// self-contained without touching resource membership. (Tests run from the
    /// checkout, so the path is stable on the dev machine / CI clone.)
    private func productsJSONURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // .../CH4_AI_Banking_appTests
            .deletingLastPathComponent()   // .../CH4_AI_Banking_app (inner project root)
            .appendingPathComponent("CH4_AI_Banking_app/Data/bca-products.json")
    }

    private func decodeProducts() throws -> [RawRow] {
        let url = productsJSONURL()
        try #require(
            FileManager.default.fileExists(atPath: url.path),
            "bca-products.json not found at \(url.path)"
        )
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([RawRow].self, from: data)
    }

    /// Mirrors the app's ingestion: build a contextual chunk + native embedding
    /// per product and insert it as a `LocalDocument`. Returns the seeded rows.
    @discardableResult
    private func seedRealCorpus(into context: ModelContext) throws -> [RawRow] {
        let rows = try decodeProducts()
        let embedding = NLEmbedding.sentenceEmbedding(for: .english)

        for row in rows {
            let chunk = buildContextualChunk(from: row)
            let vector = embedding?.vector(for: chunk) ?? []

            context.insert(
                LocalDocument(
                    id: UUID().uuidString, // FIX: Matches production ingestion layout exactly
                    chunk: chunk,
                    category: row.category,
                    source: "bca-products.json",
                    embedding: vector,
                    minIncome: 0.0, // Match your updated model parameters
                    annualFee: 0.0,
                    maxLimit: 0.0,
                    officialLink: row.officialLink ?? ""
                )
            )
        }
        try context.save()
        return rows
    }

    /// Throwaway in-memory SwiftData stack — no disk, no app launch. The same
    /// context is shared with the `RAGSystem` so seeded data is visible to it.
    private func makeSystem() throws -> (system: RAGSystem, context: ModelContext) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: LocalDocument.self, ChatMessage.self, UserProfile.self, Conversation.self,
            configurations: config
        )
        let context = ModelContext(container)
        return (RAGSystem(modelContext: context), context)
    }

    // MARK: - Corpus decoding & ingestion (deterministic)

    @Test func productsJSONDecodesCleanly() throws {
        let rows = try decodeProducts()
        // The real corpus has many products; just assert a healthy, non-trivial count.
        #expect(rows.count >= 16)
        #expect(rows.contains { $0.name == "BCA Visa Batman" })
        // Every row now carries an official link.
        #expect(rows.allSatisfy { $0.officialLink?.isEmpty == false })
        // The tolerant decoder coerces the numeric "benefits & features": 3 into a String.
        let platinum = rows.first { $0.name == "BCA Card Platinum" }
        #expect(platinum?.benefitsAndFeatures == "3")
    }

    @Test func ingestionPopulatesOneDocumentPerProduct() throws {
        let (system, context) = try makeSystem()
        let rows = try seedRealCorpus(into: context)

        let docs = system.fetchLocalDocuments()
        #expect(docs.count == rows.count)
        #expect(docs.allSatisfy { !$0.chunk.isEmpty })
        #expect(docs.allSatisfy { $0.source == "bca-products.json" })
    }

    // MARK: - Hybrid retrieval over the real corpus

    @Test func searchSurfacesDistinctivelyNamedProduct() async throws {
        let (system, context) = try makeSystem()
        try seedRealCorpus(into: context)

        // "Batman" is a term exactly one product contains. Querying that distinctive
        // term (rather than a multi-word phrase full of common terms like "card") lets
        // it dominate the hybrid ranking, so the product surfaces in the top results.
        // Exact-rank BM25 behavior is covered by BM25SearchTests.exactKeywordMatchRanksHighest.
        let results = await system.searchRelevantDocuments(for: "Batman", limit: 3)

        #expect(!results.isEmpty)
        #expect(results.contains { $0.chunk.contains("Batman") })
    }

    @Test func searchSurfacesTravelLoungeCardForSemanticQuery() async throws {
        let (system, context) = try makeSystem()
        try seedRealCorpus(into: context)

        // "airport lounge" text lives in the premium travel cards (e.g. Mastercard
        // World, Amex Platinum). Top hit should be a lounge/travel-oriented product.
        let results = await system.searchRelevantDocuments(for: "credit card with airport lounge access", limit: 3)

        #expect(!results.isEmpty)
        let topChunk = results.first?.chunk.lowercased() ?? ""
        #expect(topChunk.contains("lounge") || topChunk.contains("travel"))
    }

    // MARK: - Chat history persistence (deterministic)

    @Test func fetchRecentChatHistoryReturnsLastSixInChronologicalOrder() throws {
        let (system, context) = try makeSystem()

        for index in 1...8 {
            let message = ChatMessage(text: "msg-\(index)", isUser: index.isMultiple(of: 2))
            message.timestamp = Date(timeIntervalSince1970: Double(index))
            context.insert(message)
        }
        try context.save()

        let history = system.fetchRecentChatHistory(limit: 6)
        #expect(history.count == 6)
        #expect(history.first?.text == "msg-3") // 6 newest, oldest-first
        #expect(history.last?.text == "msg-8")
    }

    // MARK: - End-to-end generation over the real corpus (requires on-device model)

    @Test func generateResponsePersistsUserThenAssistantMessage() async throws {
        try #require(
            SystemLanguageModel.default.isAvailable,
            "Apple Intelligence model unavailable on this host — skipping."
        )

        let (system, context) = try makeSystem()
        try seedRealCorpus(into: context)

        let query = "Which card gives me airport lounge access?"
        let result = try await system.generateResponse(for: query)

        #expect(!result.aiAnswer.isEmpty)
        // The result also carries the documents the engines actually retrieved.
        #expect(!result.citedDocuments.isEmpty)
        // Echoes the input, and derives one product card per cited document.
        #expect(result.userInput == query)
        #expect(result.productCards.count == result.citedDocuments.count)
        // Any generated quiz-chip questions must be well-formed (guided generation guarantees shape).
        for followUp in result.suggestedFollowUps {
            #expect(!followUp.question.isEmpty)
            #expect(followUp.options.count <= 4)
        }

        let messages = system.fetchRecentChatHistory(limit: 10)
        #expect(messages.count == 2)
        #expect(messages.first?.isUser == true)
        #expect(messages.first?.text == query)
        #expect(messages.last?.isUser == false)
        #expect(messages.last?.text == result.aiAnswer)
    }

    /// Best-effort *eval* (NON-deterministic wording): only asserts the hard prompt
    /// constraints — non-empty, and no raw pipe delimiter (which the master prompt
    /// forbids). Treat a rare failure as a prompt signal, not a code regression.
    @Test func generatedAnswerObeysNoPipeDelimiterConstraint() async throws {
        try #require(
            SystemLanguageModel.default.isAvailable,
            "Apple Intelligence model unavailable on this host — skipping."
        )

        let (system, context) = try makeSystem()
        try seedRealCorpus(into: context)

        let result = try await system.generateResponse(for: "Tell me about a basic everyday credit card.")
        #expect(!result.aiAnswer.isEmpty)
        #expect(!result.aiAnswer.contains("|"), "AI leaked a raw pipe delimiter the prompt forbids: \(result.aiAnswer)")
    }

    // MARK: - Salary pre-filter (deterministic)

    /// `searchRelevantDocuments(userSalary:)` should drop products whose required
    /// minimum income exceeds the user's salary (0 == no minimum, always eligible).
    @Test func searchExcludesProductsAboveUserSalary() async throws {
        let (system, context) = try makeSystem()

        func doc(_ id: String, minIncome: Double) -> LocalDocument {
            LocalDocument(
                id: id, chunk: "A BCA card named \(id)", category: "test",
                source: "test", embedding: [],
                minIncome: minIncome, annualFee: 0, maxLimit: 0
            )
        }
        context.insert(doc("premium", minIncome: 50_000_000)) // out of reach
        context.insert(doc("everyday", minIncome: 0))         // always eligible
        try context.save()

        let results = await system.searchRelevantDocuments(for: "card", userSalary: 5_000_000, limit: 5)

        #expect(results.allSatisfy { $0.minIncome == 0 || $0.minIncome <= 5_000_000 })
        #expect(!results.contains { $0.id == "premium" })
        #expect(results.contains { $0.id == "everyday" })
    }

    // MARK: - ProductCardInfo derivation (deterministic)

    @Test func productCardParsesNameAndOneLinerFromChunk() {
        let row = RawRow(
            name: "BCA Visa Batman",
            category: "Credit Card",
            description: "Visa card with Batman-themed design.",
            price: "IDR 125,000/year",
            fees: "Late fee: 1%; Cash advance 4%",
            limits: "Based on approval",
            requirements: "Age 21-65",
            benefitsAndFeatures: "Reward BCA, Visa benefits",
            minApply: "IDR 3M/month",
            officialLink: "https://www.bca.co.id/en"
        )
        let doc = LocalDocument(
            id: "batman", chunk: buildContextualChunk(from: row), category: row.category,
            source: "test", embedding: [], minIncome: 3_000_000, annualFee: 125_000, maxLimit: 0
        )

        let card = ProductCardInfo(document: doc)

        #expect(card.id == "batman")
        #expect(card.name == "BCA Visa Batman")
        #expect(card.category == "Credit Card")
        // The one-liner is the Description field, cleanly separated from the pipe-delimited chunk.
        #expect(card.oneLiner == "Visa card with Batman-themed design.")
        // Colon-containing values downstream (e.g. the fee text) must not corrupt earlier fields.
        #expect(!card.oneLiner.contains("Late fee"))
        #expect(card.annualFee == 125_000)
    }

    @Test func productCardFallsBackWhenChunkIsMalformed() {
        let doc = LocalDocument(
            id: "junk", chunk: "no delimiters here", category: "Loans",
            source: "test", embedding: [], minIncome: 0, annualFee: 0, maxLimit: 0
        )
        let card = ProductCardInfo(document: doc)
        #expect(card.name == "Unknown Product")
        #expect(card.oneLiner.isEmpty)
        #expect(card.category == "Loans")
    }

    // MARK: - User profile (deterministic)

    @Test func fetchUserProfileReturnsMostRecentCompletedProfile() throws {
        let (system, context) = try makeSystem()

        // An incomplete profile should be ignored.
        context.insert(UserProfile(occupation: "Student", isComplete: false))

        let complete = UserProfile(
            occupation: "Business owner", incomeBracket: "IDR 25M–50M",
            monthlyIncome: 25_000_000, isComplete: true
        )
        complete.updatedAt = Date(timeIntervalSince1970: 100)
        context.insert(complete)
        try context.save()

        let fetched = system.fetchUserProfile()
        #expect(fetched?.occupation == "Business owner")
        #expect(fetched?.isComplete == true)
        // The prompt summary the LLM reuses reflects the stored fields.
        #expect(system.fetchUserProfile()?.promptSummary.contains("Business owner") == true)
    }

    // MARK: - Intake classification & quiz

    @Test func classifyCategoryReturnsMajorityCategoryOfTopHits() async throws {
        let (system, context) = try makeSystem()
        try seedRealCorpus(into: context)

        // A mortgage-flavored query should classify into a housing/loan category via retrieval.
        let category = await system.classifyCategory(for: "I want to buy a house with a mortgage").lowercased()
        #expect(category.contains("loan") || category.contains("hous"))
    }

    @Test func classifyCategoryIsEmptyWhenNoDocuments() async throws {
        let (system, _) = try makeSystem() // nothing seeded
        let category = await system.classifyCategory(for: "anything")
        #expect(category.isEmpty)
    }

    /// Model-gated: the intake quiz is guided generation, so we only assert its shape —
    /// at most 3 questions, each non-empty with at most 4 options.
    @Test func intakeQuizIsWellFormedForACategory() async throws {
        try #require(
            SystemLanguageModel.default.isAvailable,
            "Apple Intelligence model unavailable on this host — skipping."
        )

        let (system, context) = try makeSystem()
        try seedRealCorpus(into: context)

        let quiz = await system.generateIntakeQuiz(for: "I need a home loan", category: "Housing Loan")
        #expect(quiz.count <= 3)
        for question in quiz {
            #expect(!question.question.isEmpty)
            #expect(question.options.count <= 4)
        }
    }

    // MARK: - Persistence & rehydration (deterministic)

    @Test func fetchMessagesReturnsConversationMessagesOldestFirst() throws {
        let (system, context) = try makeSystem()
        let convoID = UUID()
        let otherID = UUID()

        let first = ChatMessage(text: "first", isUser: true, conversationID: convoID)
        first.timestamp = Date(timeIntervalSince1970: 1)
        let second = ChatMessage(text: "second", isUser: false, conversationID: convoID, citedDocumentIDs: ["a", "b"])
        second.timestamp = Date(timeIntervalSince1970: 2)
        let elsewhere = ChatMessage(text: "other", isUser: true, conversationID: otherID)
        elsewhere.timestamp = Date(timeIntervalSince1970: 3)
        [first, second, elsewhere].forEach(context.insert)
        try context.save()

        let messages = system.fetchMessages(conversationID: convoID)
        #expect(messages.map(\.text) == ["first", "second"])
        #expect(messages.last?.citedDocumentIDs == ["a", "b"]) // cards can be rebuilt on reload
    }

    @Test func documentsWithIDsPreservesRequestedOrder() throws {
        let (system, context) = try makeSystem()
        func doc(_ id: String) -> LocalDocument {
            LocalDocument(id: id, chunk: "Product Name: \(id)", category: "c",
                          source: "s", embedding: [], minIncome: 0, annualFee: 0, maxLimit: 0)
        }
        ["x", "y", "z"].forEach { context.insert(doc($0)) }
        try context.save()

        #expect(system.documents(withIDs: ["z", "x"]).map(\.id) == ["z", "x"])
    }

    // MARK: - Long-term memory (deterministic)

    @Test func fetchRelevantMemoriesRanksMostSimilarSummaryFirst() throws {
        try #require(
            NLEmbedding.sentenceEmbedding(for: .english) != nil,
            "English sentence embedding model unavailable on this host."
        )
        let (system, context) = try makeSystem()

        context.insert(Conversation(
            phase: .finished, category: "Housing Loan", title: "Home loan",
            summary: "User wanted a home mortgage and chose KPR Pembelian.",
            finishedAt: Date(timeIntervalSince1970: 10)
        ))
        context.insert(Conversation(
            phase: .finished, category: "Travel Credit Card", title: "Travel card",
            summary: "User compared travel credit cards for airport lounge access.",
            finishedAt: Date(timeIntervalSince1970: 20)
        ))
        try context.save()

        let memories = system.fetchRelevantMemories(for: "buying a house with a mortgage", excluding: nil)
        #expect(!memories.isEmpty)
        // The mortgage memory should outrank the (more recent) travel-card one on relevance.
        #expect(memories.first?.localizedCaseInsensitiveContains("mortgage") == true)
    }

    @Test func fetchRelevantMemoriesIgnoresUnfinishedConversations() throws {
        let (system, context) = try makeSystem()
        // Not finished / no summary -> not eligible as memory.
        context.insert(Conversation(phase: .loop, category: "Cards", title: "in progress"))
        try context.save()

        #expect(system.fetchRelevantMemories(for: "anything", excluding: nil).isEmpty)
    }
}
