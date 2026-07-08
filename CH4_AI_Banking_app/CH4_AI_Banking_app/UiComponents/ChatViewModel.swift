//
//  ChatViewModel.swift
//  CH4_AI_Banking_app
//
//  Drives the chat screen through the conversation state machine:
//    intake (classify → 3–6-question quiz with options / own answer / skip;
//    typing instead of finishing the quiz answers directly)
//    → loop (answer directly, no quiz) → finished (user tap).
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

/// A dynamic intake quiz awaiting the user's answers. Each question can be
/// answered with a provided option, with the user's own typed text, or skipped.
struct PendingIntake {
    let query: String
    let category: String
    let questions: [FollowUpQuestion]
    var answers: [String: String] = [:]   // question -> selected option / custom text
    var skipped: Set<String> = []         // questions the user chose not to answer

    /// Every question is either answered or deliberately skipped.
    var allResolved: Bool {
        questions.allSatisfy { answers[$0.question] != nil || skipped.contains($0.question) }
    }

    var answeredCount: Int { questions.filter { answers[$0.question] != nil }.count }

    /// True when the stored answer is the user's own text rather than an option.
    func isCustomAnswer(for key: String) -> Bool {
        guard let answer = answers[key],
              let question = questions.first(where: { $0.question == key }) else { return false }
        return !question.options.contains(answer)
    }

    /// Compiled answers injected into the answer prompt (skipped questions omitted).
    func summary() -> String {
        questions.compactMap { question in
            answers[question.question].map {
                "- \(question.question): \($0.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
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
        guard !trimmed.isEmpty, !isResponding else { return }

        // Typing while the quiz is on screen means "answer directly": dismiss the
        // quiz and fold the message plus any answers so far into the context,
        // instead of silently dropping the message (matches the input's hint).
        if pendingIntake != nil {
            transcript.append(.user(id: UUID(), text: trimmed))
            await answerBypassingIntake(with: trimmed)
            return
        }

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

    /// Tapping an option selects it (tapping the selected one deselects).
    func selectIntakeOption(question: String, option: String) {
        if pendingIntake?.answers[question] == option {
            pendingIntake?.answers[question] = nil
        } else {
            pendingIntake?.answers[question] = option
            pendingIntake?.skipped.remove(question)
        }
    }

    /// Free-text "own version" of an answer; blank text clears a custom answer
    /// (but never a chip selection, which the field can't represent).
    func setCustomIntakeAnswer(question: String, text: String) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if pendingIntake?.isCustomAnswer(for: question) == true {
                pendingIntake?.answers[question] = nil
            }
        } else {
            pendingIntake?.answers[question] = text
            pendingIntake?.skipped.remove(question)
        }
    }

    /// Marks a question as deliberately unanswered (tap again to restore it).
    func toggleSkipIntakeQuestion(question: String) {
        if pendingIntake?.skipped.contains(question) == true {
            pendingIntake?.skipped.remove(question)
        } else {
            pendingIntake?.skipped.insert(question)
            pendingIntake?.answers[question] = nil
        }
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

    /// The user typed instead of finishing the quiz: answer the ORIGINAL query,
    /// carrying whatever they did answer plus their message as extra context.
    private func answerBypassingIntake(with text: String) async {
        guard let intake = pendingIntake else { return }
        pendingIntake = nil

        activeConversation?.slots = intake.answers
        try? modelContext.save()

        var context = intake.summary()
        context += (context.isEmpty ? "" : "\n") + "- In their own words: \(text)"
        await answer(for: intake.query, intakeContext: context)
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
        rag.discardChatSession(for: conversation.id) // session done with this topic
        activeConversation = nil // next send() starts a new conversation
        transcript.append(.notice(id: UUID(), text: "Conversation finished. Ask something new to start again."))
    }

    // MARK: - History & rehydration

    /// Clears the screen for a brand-new conversation (also used by the "New chat" button).
    func newConversation() {
        rag.discardChatSession(for: activeConversation?.id)
        activeConversation = nil
        pendingIntake = nil
        phase = .intake
        transcript = []
    }

    /// Reopens a stored conversation, rebuilding the transcript (and its product cards).
    /// Sending a new message resumes it (see `send`) on a fresh session that gets
    /// a recap of the stored messages in its instructions.
    func loadConversation(_ conversation: Conversation) {
        rag.discardChatSession(for: activeConversation?.id)
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
            // Build + prewarm the conversation's session while the user fills the
            // quiz, so the first answer starts from a hot KV cache.
            rag.warmChatSession(for: conversation.id, firstQuery: query)
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
