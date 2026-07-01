//
//  CH4_AI_Banking_appApp.swift
//  CH4_AI_Banking_app
//
//  Created by Raissa Raffi Darmawan on 01/07/26.
//

import SwiftUI
import SwiftData

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

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
