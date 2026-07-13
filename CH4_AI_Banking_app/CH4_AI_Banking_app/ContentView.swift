//
//  ContentView.swift
//  CH4_AI_Banking_app
//
//  The Banking Assistant chat screen. Assembles the UiComponents into the
//  transcript + input flow described by the design system.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [UserProfile]
    @State private var model: ChatViewModel?

    private var hasCompletedProfile: Bool {
        profiles.contains { $0.isComplete }
    }

    var body: some View {
        ZStack {
            Theme.base.ignoresSafeArea()

            if !hasCompletedProfile {
                // Quiz first: learn who the user is before any AI answer.
                UserProfileFormView()
            } else if let model {
                ChatScreen(model: model)
            } else {
                ProgressView().tint(Theme.accent)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            // Build the view model once the SwiftData context is available,
            // then reopen the most recent conversation so the user sees where they left off.
            if model == nil {
                let viewModel = ChatViewModel(modelContext: modelContext)
                viewModel.loadMostRecentConversation()
                model = viewModel
            }
        }
    }
}

private struct ChatScreen: View {
    @Bindable var model: ChatViewModel
    @State private var selectedProduct: ProductCardInfo?
    @State private var showingHistory = false

    var body: some View {
        VStack(spacing: 0) {
            header
            availabilityBanner

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if model.transcript.isEmpty {
                            greeting
                            StarterChipsView { send($0) }
                        }

                        ForEach(model.transcript) { item in
                            transcriptRow(item)
                                .id(item.id)
                        }

                        if model.isResponding {
                            ReasoningRow().id(Self.reasoningRowID)
                        }
                    }
                    .padding()
                }
                .onChange(of: model.transcript.count) { scrollToBottom(proxy) }
                .onChange(of: model.isResponding) { scrollToBottom(proxy) }
                // Native chat behavior: dragging the transcript slides the
                // keyboard away with the gesture (reverse the drag to cancel).
                .scrollDismissesKeyboard(.interactively)
            }

            InputBar(text: $model.draft, isResponding: model.isResponding) {
                Task { await model.sendDraft() }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .sheet(item: $selectedProduct) { product in
            // "This works for me" inside the sheet closes the loop (flow: user
            // checks the products, finds the right one, taps continue → Finish).
            ProductSheetView(
                product: product,
                onChoose: model.canFinish ? {
                    selectedProduct = nil
                    Task { await model.finishConversation() }
                } : nil
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingHistory) {
            ConversationHistoryView { conversation in
                model.loadConversation(conversation)
                showingHistory = false
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .center) {
            Text("Banking Assistant")
                .font(.largeTitle).fontWeight(.bold)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button { showingHistory = true } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.body).foregroundStyle(Theme.textSecondary)
                    .frame(width: 44, height: 44)
            }
            Button { model.newConversation() } label: {
                Image(systemName: "square.and.pencil")
                    .font(.body).foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var greeting: some View {
        AssistantText(text: "Hi! I'm your BCA assistant. Ask me about loans, accounts, or cards — or start with one of these:")
    }

    /// Persistent, non-blocking notice when Apple Intelligence can't answer on
    /// this device (ineligible hardware, disabled in Settings, or still
    /// downloading) — explained once up front instead of only after a failed
    /// send. Reads `RAGSystem.unavailabilityNotice` directly in `body`, so it
    /// updates live if the user enables Apple Intelligence and comes back.
    @ViewBuilder
    private var availabilityBanner: some View {
        if let notice = RAGSystem.unavailabilityNotice {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Theme.textSecondary)
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface1, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline, lineWidth: 1))
            .padding(.horizontal)
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func transcriptRow(_ item: TranscriptItem) -> some View {
        switch item {
        case .user(_, let text):
            UserBubble(text: text)

        case .assistant(let id, let answer, let cards, let question):
            VStack(alignment: .leading, spacing: 12) {
                AssistantText(text: answer)

                if !cards.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            // The first card is the highest-confidence hit —
                            // highlighted as the recommendation.
                            ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                                ProductCardView(product: card, isRecommended: index == 0) {
                                    selectedProduct = card
                                }
                            }
                        }
                        .padding(.vertical, 10)
                    }
                    // Let the card glow bleed instead of clipping into a hard
                    // rectangle behind the carousel.
                    .scrollClipDisabled()
                }

                // The current question (intake flow or one-off clarification):
                // tappable only while it's the latest message and idle.
                if let question,
                   id == model.transcript.last?.id,
                   !model.isResponding {
                    QuestionCardView(
                        question: question,
                        progress: model.intakeFlow?.progress,
                        onAnswer: { answer in Task { await model.handleQuestionAnswer(answer) } },
                        onSkip: { Task { await model.skipCurrentQuestion() } }
                    )
                }
            }

        case .notice(_, let text):
            Text(text)
                .font(.footnote)
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - Helpers

    private static let reasoningRowID = "reasoning-row"

    private func send(_ text: String) {
        Task { await model.send(text) }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.25)) {
            if model.isResponding {
                proxy.scrollTo(Self.reasoningRowID, anchor: .bottom)
            } else if let lastID = model.transcript.last?.id {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [LocalDocument.self, ChatMessage.self, UserProfile.self, Conversation.self], inMemory: true)
}
