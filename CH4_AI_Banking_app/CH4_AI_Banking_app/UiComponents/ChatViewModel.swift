//
//  ChatViewModel.swift
//  CH4_AI_Banking_app
//
//  Drives the chat screen through the conversation state machine:
//    intake (classify → dynamic quiz) → loop (answer directly) → finished (user tap).
//  A new query after "finished" starts a fresh Conversation back in intake.
//  Uses Observation (no Combine).
//

import Foundation
import SwiftData
import Observation

/// One entry in the on-screen transcript.
enum TranscriptItem: Identifiable {
    case user(id: UUID, text: String)
    case assistant(id: UUID, answer: String, cards: [ProductCardInfo])
    case notice(id: UUID, text: String)

    var id: UUID {
        switch self {
        case .user(let id, _): return id
        case .assistant(let id, _, _): return id
        case .notice(let id, _): return id
        }
    }
}

/// A dynamic intake quiz awaiting the user's answers.
struct PendingIntake {
    let query: String
    let category: String
    let questions: [FollowUpQuestion]
    var answers: [String: String] = [:]   // question -> selected option

    var allAnswered: Bool { questions.allSatisfy { answers[$0.question] != nil } }

    /// Compiled answers injected into the answer prompt.
    func summary() -> String {
        questions.compactMap { question in
            answers[question.question].map { "- \(question.question): \($0)" }
        }.joined(separator: "\n")
    }
}

@MainActor
@Observable
final class ChatViewModel {
    var transcript: [TranscriptItem] = []
    var draft = ""
    var isResponding = false
    var pendingIntake: PendingIntake?
    var phase: ConversationPhase = .intake

    /// True while the user is in the product-review loop and can end the conversation.
    var canFinish: Bool { phase == .loop && pendingIntake == nil && !isResponding }

    private let rag: RAGSystem
    private let modelContext: ModelContext
    private var activeConversation: Conversation?

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        self.rag = RAGSystem(modelContext: modelContext)
    }

    // MARK: - Sending

    func sendDraft() async {
        let text = draft
        draft = ""
        await send(text)
    }

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isResponding, pendingIntake == nil else { return }

        // Start a fresh conversation only when none is active (Finish clears the active one).
        if activeConversation == nil {
            startNewConversation(title: trimmed)
        }

        transcript.append(.user(id: UUID(), text: trimmed))

        switch activeConversation?.phase ?? .intake {
        case .intake:          await runIntake(for: trimmed)
        case .loop, .finished: await answer(for: trimmed, intakeContext: nil) // finished + new message = resume
        }
    }

    // MARK: - Intake quiz interaction

    func selectIntakeOption(question: String, option: String) {
        pendingIntake?.answers[question] = option
    }

    /// Submits the intake quiz: persists the answers as slots, then answers the original query.
    func submitIntake() async {
        guard let intake = pendingIntake else { return }
        activeConversation?.slots = intake.answers
        try? modelContext.save()

        let summary = intake.summary()
        pendingIntake = nil
        await answer(for: intake.query, intakeContext: summary.isEmpty ? nil : summary)
    }

    // MARK: - Finishing

    /// Finishes the active conversation: generates a one-line summary (memory) and marks it done.
    func finishConversation() async {
        guard let conversation = activeConversation else { return }

        isResponding = true
        let summary = await rag.summarizeConversation(id: conversation.id, category: conversation.category)
        isResponding = false

        conversation.summary = summary
        conversation.phase = .finished
        conversation.finishedAt = Date()
        try? modelContext.save()

        phase = .finished
        activeConversation = nil // next send() starts a new conversation
        transcript.append(.notice(id: UUID(), text: "Conversation finished. Ask something new to start again."))
    }

    // MARK: - History & rehydration

    /// Clears the screen for a brand-new conversation (also used by the "New chat" button).
    func newConversation() {
        activeConversation = nil
        pendingIntake = nil
        phase = .intake
        transcript = []
    }

    /// Reopens a stored conversation, rebuilding the transcript (and its product cards).
    /// Sending a new message resumes it (see `send`).
    func loadConversation(_ conversation: Conversation) {
        activeConversation = conversation
        pendingIntake = nil
        phase = conversation.phase
        transcript = rebuildTranscript(for: conversation.id)
    }

    /// On launch, reopen the most recent conversation so the user sees where they left off.
    func loadMostRecentConversation() {
        var descriptor = FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        if let latest = (try? modelContext.fetch(descriptor))?.first {
            loadConversation(latest)
        }
    }

    private func rebuildTranscript(for conversationID: UUID) -> [TranscriptItem] {
        rag.fetchMessages(conversationID: conversationID).map { message in
            if message.isUser {
                return .user(id: message.id, text: message.text)
            }
            let cards = rag.documents(withIDs: message.citedDocumentIDs).map(ProductCardInfo.init(document:))
            return .assistant(id: message.id, answer: message.text, cards: cards)
        }
    }

    // MARK: - Internals

    private func startNewConversation(title: String) {
        transcript = [] // fresh screen per conversation
        let conversation = Conversation(phase: .intake, title: title)
        modelContext.insert(conversation)
        try? modelContext.save()
        activeConversation = conversation
        phase = .intake
    }

    /// Intake: classify the category (via retrieval), then generate the minimal quiz.
    /// If no quiz is needed, answer immediately.
    private func runIntake(for query: String) async {
        guard let conversation = activeConversation else { return }
        isResponding = true

        let category = await rag.classifyCategory(for: query)
        conversation.category = category
        try? modelContext.save()

        let quiz = await rag.generateIntakeQuiz(for: query, category: category)
        isResponding = false

        if quiz.isEmpty {
            await answer(for: query, intakeContext: nil)
        } else {
            pendingIntake = PendingIntake(query: query, category: category, questions: quiz)
        }
    }

    /// Loop: retrieve + generate the answer, persist it, and advance to the loop phase.
    private func answer(for query: String, intakeContext: String?) async {
        guard let conversation = activeConversation else { return }
        isResponding = true
        defer { isResponding = false }

        do {
            let result = try await rag.generateResponse(
                for: query,
                conversationID: conversation.id,
                intakeContext: intakeContext
            )
            transcript.append(.assistant(id: UUID(), answer: result.aiAnswer, cards: result.productCards))
            conversation.phase = .loop
            phase = .loop
            try? modelContext.save()
        } catch {
            transcript.append(
                .assistant(id: UUID(), answer: "Sorry, something went wrong: \(error.localizedDescription)", cards: [])
            )
        }
    }
}
