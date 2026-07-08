//
//  CH4_AI_Banking_appApp.swift
//  CH4_AI_Banking_app
//
//  Created by Raissa Raffi Darmawan on 01/07/26.
//

import SwiftUI
import SwiftData
import NaturalLanguage

@main
struct CH4_AI_Banking_appApp: App {
    // The RAG container — holds the models the chat UI actually reads.
    let container: ModelContainer

    // `App.init()` must be synchronous, so we only build the container here.
    // The async, model-powered seeding runs from a `.task` once the scene appears.
    init() {
        let schema = Schema([LocalDocument.self, ChatMessage.self, UserProfile.self, Conversation.self])
        do {
            container = try ModelContainer(for: schema)
        } catch {
            // An older on-disk store predates the current schema (e.g. the new
            // UserProfile model / added officialLink column) and can't migrate
            // automatically. In development it's safe to discard the incompatible
            // store and rebuild from scratch (seeding will re-run on next launch).
            print("⚠️ SwiftData store incompatible (\(error)). Rebuilding from scratch.")
            Self.deleteDefaultStore()
            do {
                container = try ModelContainer(for: schema)
            } catch {
                fatalError("Failed to configure SwiftData Container after reset: \(error)")
            }
        }
    }

    /// Removes the default SwiftData store files so a fresh, schema-current store can be created.
    private static func deleteDefaultStore() {
        let directory = URL.applicationSupportDirectory
        for name in ["default.store", "default.store-shm", "default.store-wal"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    @MainActor
    private func seedBcaDatabaseIfNeeded(context: ModelContext) async {
        // Load the embedder (contextual if available, else NLEmbedding fallback).
        await ContextualEmbedder.shared.prepare()
        guard ContextualEmbedder.shared.isReady else {
            print("⚠️ No embedder available; skipping seeding this launch.")
            return
        }
        let indexTag = ContextualEmbedder.shared.indexTag

        do {
            let existing = try context.fetch(FetchDescriptor<LocalDocument>())
            if let first = existing.first {
                if first.embeddingModel == indexTag {
                    return // already seeded with the current embedder + text scheme
                }
                // Stored vectors came from a different embedding space — re-seed.
                print("♻️ Embedding index changed (\(first.embeddingModel) → \(indexTag)); re-seeding.")
                existing.forEach { context.delete($0) }
                try context.save()
            }

            print("📥 Starting contextual pipeline ingestion engine...")

            guard let fileURL = Bundle.main.url(forResource: "bca-products", withExtension: "json") else {
                print("⚠️ Ingestion halted: 'bca-products.json' file not found.")
                return
            }

            let data = try Data(contentsOf: fileURL)
            let spreadsheetRows = try JSONDecoder().decode([RawRow].self, from: data)

            for row in spreadsheetRows {
                let descriptiveChunk = buildContextualChunk(from: row)

                // Let the AI extract the math variables out of the raw text columns
                let extractedMetrics = await extractNumericalMetadata(from: descriptiveChunk)

                // The vector index embeds the distilled text; BM25 and the LLM
                // context keep the full descriptive chunk (see buildEmbeddingText).
                let nativeVector = ContextualEmbedder.shared.vector(for: buildEmbeddingText(from: row)) ?? []

                let localDoc = LocalDocument(
                    // Deterministic natural key: idempotent re-seeds, and stored
                    // citedDocumentIDs stay resolvable after a re-seed.
                    id: row.name,
                    chunk: descriptiveChunk,
                    category: row.category,
                    source: "bca-products.json",
                    embedding: nativeVector,
                    minIncome: extractedMetrics.minIncome,    // Saved explicitly!
                    annualFee: extractedMetrics.annualFee,    // Saved explicitly!
                    maxLimit: extractedMetrics.maxLimit,      // Saved explicitly!
                    officialLink: row.officialLink ?? "",     // Source page for the References row
                    embeddingModel: indexTag                  // So we re-seed if the embedder or text scheme changes
                )

                context.insert(localDoc)
            }

            try context.save()
            print("✅ Ingested \(spreadsheetRows.count) product chunks into SwiftData.")
        } catch {
            print("⚠️ Ingestion failed: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    await seedBcaDatabaseIfNeeded(context: container.mainContext)
                }
        }
        .modelContainer(container)
    }

}
