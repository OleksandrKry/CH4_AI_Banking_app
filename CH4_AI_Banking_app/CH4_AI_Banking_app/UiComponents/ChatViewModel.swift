//
//  ChatViewModel.swift
//  CH4_AI_Banking_app
//
//  Drives the chat screen. Pure chatbot: no pre-conversation quiz — the model
//  qualifies the user conversationally along the decision tree in its session
//  instructions (see BankingDecisionTree), then recommends. Finish is a user tap
//  that summarizes the conversation into memory; a new query afterwards starts a
//  fresh Conversation. Uses Observation (no Combine).
//

import Foundation
import SwiftData
import Observation

/// One entry in the on-screen transcript. An assistant entry may carry ONE
/// structured qualifying question (decision-tree step) that the UI renders as
/// tappable option rows — questions arrive one per turn, never as a batch.
enum TranscriptItem: Identifiable {
    case user(id: UUID, text: String)
    case assistant(id: UUID, answer: String, cards: [ProductCardInfo], question: FollowUpQuestion?)
    case notice(id: UUID, text: String)

    var id: UUID {
        switch self {
        case .user(let id, _): return id
        case .assistant(let id, _, _, _): return id
        case .notice(let id, _): return id
        }
    }
}

/// The sequential intake flow: 3–6 questions generated ONCE per conversation,
/// asked one at a time. Answers accumulate locally — zero model calls between
/// questions; the single grounded answer fires after the last one.
struct IntakeFlow {
    let originalQuery: String
    let questions: [FollowUpQuestion]
    private(set) var answers: [(question: String, answer: String?)] = []  // nil = skipped

    var current: FollowUpQuestion? {
        answers.count < questions.count ? questions[answers.count] : nil
    }
    var isComplete: Bool { answers.count == questions.count }
    var progress: String { "\(min(answers.count + 1, questions.count))/\(questions.count)" }

    mutating func record(_ answer: String?) {
        guard let current else { return }
        let trimmed = answer?.trimmingCharacters(in: .whitespacesAndNewlines)
        answers.append((current.question, (trimmed?.isEmpty ?? true) ? nil : trimmed))
    }

    /// Compiled Q/A pairs for the answer prompt (skipped questions omitted).
    func summary() -> String {
        answers.compactMap { pair in
            pair.answer.map { "- \(pair.question): \($0)" }
        }.joined(separator: "\n")
    }
}

@MainActor
@Observable
final class ChatViewModel {
    var transcript: [TranscriptItem] = []
    var draft = ""
    var isResponding = false
    var phase: ConversationPhase = .intake
    var intakeFlow: IntakeFlow?

    /// True while the user is in the product-review loop and can end the conversation.
    var canFinish: Bool { phase == .loop && !isResponding }

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

        // While the intake flow is on screen, a typed message answers the
        // current question — same as tapping an option.
        if intakeFlow != nil {
            await advanceIntake(with: trimmed)
            return
        }

        // Start a fresh conversation only when none is active (Finish clears the active one).
        if activeConversation == nil {
            startNewConversation(title: trimmed)
        }

        transcript.append(.user(id: UUID(), text: trimmed))

        // Label the conversation once — AI intent classification costs ~1s
        // on-device, so it runs OFF the critical path (the answer starts
        // immediately); warming the session keeps the first answer's KV cache hot.
        if let conversation = activeConversation, conversation.category.isEmpty {
            rag.warmChatSession(for: conversation.id, firstQuery: trimmed)
            Task { [weak self] in
                guard let self else { return }
                conversation.category = await self.rag.classifyIntentCategory(for: trimmed)
                try? self.modelContext.save()
            }
        }

        // First message of a fresh conversation: generate the 3–6 intake
        // questions ONCE, then walk them one at a time (no model calls between).
        if activeConversation?.phase == .intake {
            await startIntakeFlow(for: trimmed)
            return
        }

        await answer(for: trimmed) // finished + new message = resume
    }

    // MARK: - Sequential intake flow

    private func startIntakeFlow(for query: String) async {
        isResponding = true
        let questions = await rag.generateIntakeQuestions(for: query)
        isResponding = false

        guard let first = questions.first else {
            await answer(for: query) // generation unavailable → answer directly
            return
        }

        intakeFlow = IntakeFlow(originalQuery: query, questions: questions)
        transcript.append(.assistant(id: UUID(), answer: first.question, cards: [], question: first))
    }

    /// Records the reply (nil = skip), shows the next question, and fires the
    /// single grounded answer once the last question is resolved.
    private func advanceIntake(with reply: String?) async {
        guard var flow = intakeFlow else { return }
        transcript.append(.user(id: UUID(), text: reply ?? "Skip"))
        flow.record(reply)

        if let next = flow.current {
            intakeFlow = flow
            transcript.append(.assistant(id: UUID(), answer: next.question, cards: [], question: next))
            return
        }

        intakeFlow = nil
        activeConversation?.slots = Dictionary(
            flow.answers.compactMap { pair in pair.answer.map { (pair.question, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        try? modelContext.save()

        let summary = flow.summary()
        await answer(for: flow.originalQuery, intakeContext: summary.isEmpty ? nil : summary)
    }

    /// Question-card actions (also used by mid-conversation clarifying cards).
    func handleQuestionAnswer(_ text: String) async {
        if intakeFlow != nil {
            await advanceIntake(with: text)
        } else {
            await send(text)
        }
    }

    func skipCurrentQuestion() async {
        if intakeFlow != nil {
            await advanceIntake(with: nil)
        } else {
            await send("No preference — please continue.")
        }
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
        intakeFlow = nil
        phase = .intake
        transcript = []
    }

    /// Reopens a stored conversation, rebuilding the transcript (and its product cards).
    /// Sending a new message resumes it (see `send`) on a fresh session that gets
    /// a recap of the stored messages in its instructions.
    func loadConversation(_ conversation: Conversation) {
        rag.discardChatSession(for: activeConversation?.id)
        activeConversation = conversation
        intakeFlow = nil
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
            // Reloaded questions aren't interactive — the user answers in chat.
            return .assistant(id: message.id, answer: message.text, cards: cards, question: nil)
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

    /// Generate the answer on the conversation's session (the model calls the
    /// catalog tool itself), persist it, and advance to the loop phase.
    private func answer(for query: String, intakeContext: String? = nil) async {
        guard let conversation = activeConversation else { return }
        isResponding = true
        defer { isResponding = false }

        do {
            let result = try await rag.generateResponse(
                for: query,
                conversationID: conversation.id,
                intakeContext: intakeContext
            )
            transcript.append(.assistant(
                id: UUID(),
                answer: result.aiAnswer,
                cards: result.productCards,
                question: result.suggestedFollowUps.first
            ))
            conversation.phase = .loop
            phase = .loop
            try? modelContext.save()
        } catch {
            // Friendly, actionable text — never a raw framework error dump.
            transcript.append(
                .assistant(id: UUID(),
                           answer: RAGSystem.friendlyFailureMessage(for: error),
                           cards: [], question: nil)
            )
        }
    }
}
