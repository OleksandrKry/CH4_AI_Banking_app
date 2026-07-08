//
//  Conversation.swift
//  CH4_AI_Banking_app
//
//  The per-topic conversation state machine. Each conversation moves through
//  three phases — intake (dynamic quiz to gather context), loop (review products
//  / ask follow-ups with no quiz), and finished (user marked satisfied; stored so
//  the assistant can reuse past preferences). A new query after "finished" starts
//  a fresh conversation back in the intake phase.
//

import Foundation
import SwiftData

enum ConversationPhase: String, Codable, Sendable {
    case intake     // Gathering context via the category-specific quiz
    case loop       // Reviewing products / follow-ups — answer directly, no quiz
    case finished   // User tapped Finish; kept for reuse / re-checking
}

@Model
final class Conversation {
    @Attribute(.unique) var id: UUID
    var phaseRaw: String            // Stored as raw String for migration safety
    var category: String            // Classified product category for this topic
    var title: String               // Short label, usually the opening query
    var slots: [String: String]     // Per-intent answers collected during intake
    var summary: String             // One-line recap generated at Finish; fed to the AI as memory
    var startedAt: Date
    var finishedAt: Date?

    init(
        id: UUID = UUID(),
        phase: ConversationPhase = .intake,
        category: String = "",
        title: String = "",
        slots: [String: String] = [:],
        summary: String = "",
        startedAt: Date = Date(),
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.phaseRaw = phase.rawValue
        self.category = category
        self.title = title
        self.slots = slots
        self.summary = summary
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    /// Typed accessor over the raw-string storage.
    var phase: ConversationPhase {
        get { ConversationPhase(rawValue: phaseRaw) ?? .intake }
        set { phaseRaw = newValue.rawValue }
    }
}
