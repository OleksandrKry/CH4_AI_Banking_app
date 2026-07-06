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
        do {
            container = try ModelContainer(for: LocalDocument.self, ChatMessage.self)
        } catch {
            fatalError("Failed to configure SwiftData Container: \(error)")
        }
    }

    @MainActor
    private func seedBcaDatabaseIfNeeded(context: ModelContext) async {
        do {
            let descriptor = FetchDescriptor<LocalDocument>()
            let existingCount = try context.fetchCount(descriptor)
            guard existingCount == 0 else { return }

            print("📥 SwiftData empty. Starting contextual pipeline ingestion engine...")

            // 1. Fetch your spreadsheet table JSON asset from the Xcode target bundle
            guard let fileURL = Bundle.main.url(forResource: "bca-products", withExtension: "json") else {
                print("⚠️ Ingestion halted: 'bca-products.json' file not found.")
                return
            }

            let data = try Data(contentsOf: fileURL)
            let spreadsheetRows = try JSONDecoder().decode([RawRow].self, from: data)

            guard let sentenceEmbedding = NLEmbedding.sentenceEmbedding(for: .english) else {
                print("❌ Native Apple NLP models failed to load on-device.")
                return
            }

            // 2. Loop through your rows
            for row in spreadsheetRows {
                let descriptiveChunk = buildContextualChunk(from: row)

                // Let the AI extract the math variables out of the raw text columns
                let extractedMetrics = await extractNumericalMetadata(from: descriptiveChunk)

                let nativeVector = sentenceEmbedding.vector(for: descriptiveChunk) ?? Array(repeating: 0.0, count: 512)

                let localDoc = LocalDocument(
                    id: UUID().uuidString,
                    chunk: descriptiveChunk,
                    category: row.category,
                    source: "bca-products.json",
                    embedding: nativeVector,
                    minIncome: extractedMetrics.minIncome,    // Saved explicitly!
                    annualFee: extractedMetrics.annualFee,    // Saved explicitly!
                    maxLimit: extractedMetrics.maxLimit       // Saved explicitly!
                )

                context.insert(localDoc)
            }

            try context.save()
            print("✅ Success! Ingested \(spreadsheetRows.count) highly descriptive card chunks into SwiftData.")
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
