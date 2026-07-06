//
//  ChatViewModel.swift
//  CH4_AI_Banking_app
//
//  Drives the chat screen: holds the in-memory transcript (richer than the
//  persisted ChatMessage — it also carries product cards + quiz chips) and
//  bridges the UI to the RAGSystem. Uses Observation (no Combine).
//

import Foundation
import SwiftData
import Observation

/// One entry in the on-screen transcript.
enum TranscriptItem: Identifiable {
    case user(id: UUID, text: String)
    case assistant(id: UUID, answer: String, cards: [ProductCardInfo], followUps: [FollowUpQuestion])

    var id: UUID {
        switch self {
        case .user(let id, _): return id
        case .assistant(let id, _, _, _): return id
        }
    }
}

@MainActor
@Observable
final class ChatViewModel {
    var transcript: [TranscriptItem] = []
    var draft: String = ""
    var isResponding = false

    private let rag: RAGSystem

    init(modelContext: ModelContext) {
        self.rag = RAGSystem(modelContext: modelContext)
    }

    /// Sends whatever is currently in the input field.
    func sendDraft() async {
        let text = draft
        draft = ""
        await send(text)
    }

    /// Sends an explicit string (used by starter chips and quiz-chip taps, which
    /// echo back as a user bubble per the design).
    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isResponding else { return }

        transcript.append(.user(id: UUID(), text: trimmed))
        isResponding = true
        defer { isResponding = false }

        do {
            let result = try await rag.generateResponse(for: trimmed)
            transcript.append(
                .assistant(id: UUID(), answer: result.aiAnswer, cards: result.productCards, followUps: result.suggestedFollowUps)
            )
        } catch {
            transcript.append(
                .assistant(id: UUID(), answer: "Sorry, something went wrong: \(error.localizedDescription)", cards: [], followUps: [])
            )
        }
    }
}
