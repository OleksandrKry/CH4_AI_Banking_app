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
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()
    
    let container: ModelContainer
        
    init() {
        do {
            container = try ModelContainer(for: LocalDocument.self, ChatMessage.self)
            try seedBcaDatabaseIfNeeded(context: container.mainContext)
        } catch {
            fatalError("Failed to configure SwiftData Container: \(error)")
        }
    }
    
    private func seedBcaDatabaseIfNeeded(context: ModelContext) throws {
        let descriptor = FetchDescriptor<LocalDocument>()
        let existingCount = try context.fetchCount(descriptor)
        guard existingCount == 0 else { return }
        
        print("📥 SwiftData empty. Starting contextual pipeline ingestion engine...")
        
        // 1. Fetch your spreadsheet table JSON asset from the Xcode target bundle
        guard let fileURL = Bundle.main.url(forResource: "bca_products", withExtension: "json") else {
            print("⚠️ Ingestion halted: 'bca_products.json' file not found.")
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
            // Generate a unique ID identifier slug from the product name string
            let uniqueID = row.name.lowercased()
                .replacingOccurrences(of: " ", with: "_")
                .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
            
            // Invoke our contextual anchor string formatter
            let descriptiveChunk = buildContextualChunk(from: row)
            
            // Build the native 512-dimension vector array properties
            let nativeVector = sentenceEmbedding.vector(for: descriptiveChunk) ?? Array(repeating: 0.0, count: 512)
            
            let localDoc = LocalDocument(
                id: uniqueID,
                chunk: descriptiveChunk,
                category: row.category,
                source: "bca_products.json",
                embedding: nativeVector
            )
            
            context.insert(localDoc)
        }
        
        try context.save()
        print("✅ Success! Ingested \(spreadsheetRows.count) highly descriptive card chunks into SwiftData.")
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }

}
