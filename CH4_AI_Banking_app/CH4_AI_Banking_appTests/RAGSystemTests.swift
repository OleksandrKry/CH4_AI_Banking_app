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

    /// Total number of products in `bca-products.json`. Update if the corpus changes.
    private static let expectedProductCount = 16

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
            let uniqueID = row.name.lowercased()
                .replacingOccurrences(of: " ", with: "_")
                .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
            let chunk = buildContextualChunk(from: row)
            let vector = embedding?.vector(for: chunk) ?? []

            context.insert(
                LocalDocument(
                    id: uniqueID,
                    chunk: chunk,
                    category: row.category,
                    source: "bca-products.json",
                    embedding: vector
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
            for: LocalDocument.self, ChatMessage.self,
            configurations: config
        )
        let context = ModelContext(container)
        return (RAGSystem(modelContext: context), context)
    }

    // MARK: - Corpus decoding & ingestion (deterministic)

    @Test func productsJSONDecodesCleanly() throws {
        let rows = try decodeProducts()
        #expect(rows.count == Self.expectedProductCount)
        #expect(rows.contains { $0.name == "BCA Visa Batman" })
        // The car-loan product legitimately omits `min_apply`.
        #expect(rows.contains { $0.name == "KKB BCA" && $0.minApply == nil })
    }

    @Test func ingestionPopulatesOneDocumentPerProduct() throws {
        let (system, context) = try makeSystem()
        try seedRealCorpus(into: context)

        let docs = system.fetchLocalDocuments()
        #expect(docs.count == Self.expectedProductCount)
        #expect(docs.allSatisfy { !$0.chunk.isEmpty })
        #expect(docs.allSatisfy { $0.source == "bca-products.json" })
    }

    // MARK: - Hybrid retrieval over the real corpus

    @Test func searchSurfacesDistinctivelyNamedProduct() async throws {
        let (system, context) = try makeSystem()
        try seedRealCorpus(into: context)

        // "Batman" appears in exactly one product, so BM25 (and RRF, if the
        // embedding model is present) should rank it first regardless.
        let results = await system.searchRelevantDocuments(for: "Batman themed card design", limit: 3)

        #expect(!results.isEmpty)
        #expect(results.first?.chunk.contains("Batman") == true)
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
        let response = try await system.generateResponse(for: query)

        #expect(!response.isEmpty)

        let messages = system.fetchRecentChatHistory(limit: 10)
        #expect(messages.count == 2)
        #expect(messages.first?.isUser == true)
        #expect(messages.first?.text == query)
        #expect(messages.last?.isUser == false)
        #expect(messages.last?.text == response)
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

        let response = try await system.generateResponse(for: "Tell me about a basic everyday credit card.")
        #expect(!response.isEmpty)
        #expect(!response.contains("|"), "AI leaked a raw pipe delimiter the prompt forbids: \(response)")
    }
}
