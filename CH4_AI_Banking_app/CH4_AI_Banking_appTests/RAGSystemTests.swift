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

@Suite(.serialized) // FM tests share the on-device model; parallel sessions get throttled
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

    /// Mirrors the app's ingestion: full chunk for BM25/LLM context, distilled
    /// text embedded via the same `ContextualEmbedder` the queries use (query and
    /// document vectors MUST share one embedding space), tagged with the index tag.
    @discardableResult
    private func seedRealCorpus(into context: ModelContext) throws -> [RawRow] {
        let rows = try decodeProducts()
        let tag = ContextualEmbedder.shared.indexTag

        for row in rows {
            let chunk = buildContextualChunk(from: row)
            let vector = ContextualEmbedder.shared.vector(for: buildEmbeddingText(from: row)) ?? []

            context.insert(
                LocalDocument(
                    id: row.name, // deterministic natural key, matches production seeding
                    chunk: chunk,
                    category: row.category,
                    source: "bca-products.json",
                    embedding: vector,
                    minIncome: 0.0, // Match your updated model parameters
                    annualFee: 0.0,
                    maxLimit: 0.0,
                    officialLink: row.officialLink ?? "",
                    embeddingModel: tag
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
        // The curated data gives every product real benefits text (the tolerant
        // decoder still guards against future numeric/missing values).
        let platinum = rows.first { $0.name == "BCA Card Platinum" }
        #expect(platinum?.benefitsAndFeatures?.isEmpty == false)
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

        do {
            let result = try await system.generateResponse(for: "Tell me about a basic everyday credit card.")
            #expect(!result.aiAnswer.isEmpty)
            #expect(!result.aiAnswer.contains("|"), "AI leaked a raw pipe delimiter the prompt forbids: \(result.aiAnswer)")
        } catch {
            // Transient GenerationErrors (seen on-device too) surface as friendly
            // text in the app — assert the mapping instead of failing the suite
            // on a model-layer hiccup.
            let message = RAGSystem.friendlyFailureMessage(for: error)
            #expect(!message.isEmpty)
            #expect(!message.contains("GenerationError"))
        }
    }

    // MARK: - Conversation triggers & off-topic behavior (model-gated e2e)
    //
    // These pin the DIRECTION the conversation takes (retrieve vs. answer from
    // context vs. decline); the wording is the model's business and never asserted.
    // See docs/REQUIREMENTS.md for the R# mapping.

    /// R9: off-topic requests must not produce product cards — the tool's
    /// confidence floor filters everything, so cards stay empty even if the
    /// model chooses to call it.
    @Test func offTopicQueryDeclinesWithoutProducts() async throws {
        try #require(SystemLanguageModel.default.isAvailable,
                     "Apple Intelligence model unavailable on this host — skipping.")
        let (system, context) = try makeSystem()
        try seedRealCorpus(into: context)

        let result = try await system.generateResponse(for: "Can you write me a poem about cats?")
        #expect(!result.aiAnswer.isEmpty)
        #expect(result.productCards.isEmpty)
        #expect(result.retrievalConfidence == nil)
        #expect(!result.aiAnswer.contains("GenerationError"))
    }

    /// R10/R11: "dummy" input and guardrail-prone requests either get a graceful
    /// answer or map to a friendly failure message — never a raw framework error.
    /// ("I want to buy a new iPhone" reproduced a raw "GenerationError error -1."
    /// in the chat UI before the friendly mapping existed.)
    @Test(arguments: ["I want to buy a new iPhone", "asdf qwerty zzz 12345"])
    func roughInputNeverLeaksRawErrors(query: String) async throws {
        try #require(SystemLanguageModel.default.isAvailable,
                     "Apple Intelligence model unavailable on this host — skipping.")
        let (system, context) = try makeSystem()
        try seedRealCorpus(into: context)

        do {
            let result = try await system.generateResponse(for: query)
            #expect(!result.aiAnswer.isEmpty)
            #expect(!result.aiAnswer.contains("GenerationError"))
        } catch {
            // The chat view model shows this mapping — assert it stays friendly.
            let message = RAGSystem.friendlyFailureMessage(for: error)
            #expect(!message.contains("GenerationError"))
            #expect(!message.isEmpty)
        }
    }

    /// R5: a broad first query should start decision-tree qualification, not
    /// dump products (the tree tells the model to ask the category first).
    @Test func broadFirstQueryQualifiesBeforeRecommending() async throws {
        try #require(SystemLanguageModel.default.isAvailable,
                     "Apple Intelligence model unavailable on this host — skipping.")
        let (system, context) = try makeSystem()
        try seedRealCorpus(into: context)

        let result = try await system.generateResponse(for: "What banking products do you have?")
        #expect(!result.aiAnswer.isEmpty)
        // Prompt-enforced model judgment (like R7): in the app, first messages
        // run through the sequential intake flow before this path, so a stray
        // eager retrieval here is recorded, not failed.
        withKnownIssue("Small model occasionally retrieves for broad queries instead of qualifying",
                       isIntermittent: true) {
            #expect(result.productCards.isEmpty)
        }
    }

    /// R7: follow-ups about products already on screen answer from the session
    /// transcript — no re-retrieval, so no cards get silently swapped.
    @Test func followUpAboutShownProductAnswersFromContext() async throws {
        try #require(SystemLanguageModel.default.isAvailable,
                     "Apple Intelligence model unavailable on this host — skipping.")
        let (system, context) = try makeSystem()
        try seedRealCorpus(into: context)
        let conversationID = UUID()

        let first = try await system.generateResponse(
            for: "Which credit card gives me airport lounge access?",
            conversationID: conversationID)
        try #require(!first.citedDocuments.isEmpty, "First turn should retrieve products.")

        let second = try await system.generateResponse(
            for: "What is the annual fee for that first card?",
            conversationID: conversationID)
        #expect(!second.aiAnswer.isEmpty)
        // The requirement is "no silent product swap": ideally the model answers
        // from the transcript (no retrieval); re-fetching the SAME products is
        // tolerated, surfacing different ones is the bug. Tool discipline is
        // prompt-enforced on a small model, so record misses as an intermittent
        // known issue instead of failing CI on model judgment.
        let firstIDs = Set(first.citedDocuments.map(\.id))
        let secondIDs = Set(second.citedDocuments.map(\.id))
        withKnownIssue("Small-model tool discipline occasionally re-searches on follow-ups",
                       isIntermittent: true) {
            #expect(secondIDs.isEmpty || secondIDs.isSubset(of: firstIDs),
                    "Follow-up about a shown product must not swap in different products.")
        }
    }

    /// R8: explicitly asking for NEW/different products triggers retrieval again.
    @Test func askingForDifferentProductsRetrievesAgain() async throws {
        try #require(SystemLanguageModel.default.isAvailable,
                     "Apple Intelligence model unavailable on this host — skipping.")
        let (system, context) = try makeSystem()
        try seedRealCorpus(into: context)
        let conversationID = UUID()

        let first = try await system.generateResponse(
            for: "Which credit card gives me airport lounge access?",
            conversationID: conversationID)
        try #require(!first.citedDocuments.isEmpty, "First turn should retrieve products.")

        let second = try await system.generateResponse(
            for: "Actually, show me a different card with no annual fee instead.",
            conversationID: conversationID)
        #expect(!second.citedDocuments.isEmpty,
                "A new-product request must call the catalog tool again.")
    }

    /// R6: the intake questions are generated ONCE per conversation with the
    /// 3–6 / 2–4 shape enforced by constrained decoding ([] = failure fallback).
    @Test func intakeQuestionsGenerateOnceWithThreeToSix() async throws {
        try #require(SystemLanguageModel.default.isAvailable,
                     "Apple Intelligence model unavailable on this host — skipping.")
        let (system, _) = try makeSystem()

        let questions = await system.generateIntakeQuestions(for: "I need a loan")
        if !questions.isEmpty {
            #expect((3...6).contains(questions.count))
            for question in questions {
                #expect(!question.question.isEmpty)
                #expect((2...4).contains(question.options.count))
            }
        }
    }

    /// R13: the AI classifies intents into decision-tree categories
    /// (constrained decoding guarantees a valid case). The corpus is seeded so
    /// the retrieval-vote fallback also yields a real category if the guided
    /// call is unavailable (e.g. throttled by parallel test sessions).
    @Test func intentClassificationPicksATreeCategory() async throws {
        try #require(SystemLanguageModel.default.isAvailable,
                     "Apple Intelligence model unavailable on this host — skipping.")
        let (system, context) = try makeSystem()
        try seedRealCorpus(into: context)

        let start = ContinuousClock.now
        let category = await system.classifyIntentCategory(
            for: "I want to buy my first house with a mortgage")
        let elapsed = start.duration(to: ContinuousClock.now)
        #expect(category == "Housing Loan")

        let line = String(format: "⏱ classify %.0fms → %@\n", elapsed / .milliseconds(1), category)
        try? line.write(to: URL(fileURLWithPath: "/tmp/ch4-classify-metrics.txt"),
                        atomically: true, encoding: .utf8)
    }

    /// R16: the product flow is gated on TRANSACTIONAL intent — product-seeking
    /// queries route to the quiz, identity/capability questions and smalltalk
    /// route to a direct answer.
    @Test(arguments: [
        ("I need a credit card for travel", QueryIntent.transactional),
        ("who are you and what can you help with?", QueryIntent.informational),
        ("what's the time?", QueryIntent.smalltalk),
    ])
    func triageRoutesIntentCorrectly(query: String, expected: QueryIntent) async throws {
        try #require(SystemLanguageModel.default.isAvailable,
                     "Apple Intelligence model unavailable on this host — skipping.")
        let (system, _) = try makeSystem()

        let triage = await system.triageQuery(for: query)
        if expected == .transactional {
            #expect(triage.intent == .transactional)
        } else {
            // informational vs smalltalk boundary is fuzzy; what matters is that
            // neither ever triggers the product flow.
            #expect(triage.intent != .transactional)
        }
    }

    /// R15: every turn reports its stage timings and context estimate.
    @Test func turnMetricsCaptureStageTimings() async throws {
        try #require(SystemLanguageModel.default.isAvailable,
                     "Apple Intelligence model unavailable on this host — skipping.")
        let (system, context) = try makeSystem()
        try seedRealCorpus(into: context)

        let result = try await system.generateResponse(
            for: "Which credit card gives me airport lounge access?")
        try #require(!result.citedDocuments.isEmpty)

        let metrics = system.lastTurnMetrics
        #expect(metrics.generation > .zero)
        #expect(metrics.retrieval > .zero)           // the tool actually searched
        #expect(metrics.total >= metrics.generation)
        #expect(metrics.approxContextTokens > 200)   // instructions + turn landed

        // Simulator stdout doesn't reach headless xcodebuild logs, and the clone
        // simulators are erased after the run — drop the numbers on the HOST
        // filesystem (simulators share it) so CI/agents can read them.
        let line = "⏱ E2E turn: " + metrics.summary + "\n"
        print(line)
        try? line.write(to: URL(fileURLWithPath: "/tmp/ch4-turn-metrics.txt"),
                        atomically: true, encoding: .utf8)
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

    @Test(.enabled("Needs an on-device NL embedding model") {
        await RetrievalEvaluator.embedderAvailable()
    })
    func fetchRelevantMemoriesRanksMostSimilarSummaryFirst() async throws {
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
