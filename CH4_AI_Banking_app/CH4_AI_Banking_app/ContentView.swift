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

                        // Dynamic intake quiz (before the answer).
                        if let intake = model.pendingIntake {
                            IntakeQuizView(
                                intake: intake,
                                onSelect: { model.selectIntakeOption(question: $0, option: $1) },
                                onSubmit: { Task { await model.submitIntake() } }
                            )
                            .id(Self.intakeID)
                        }

                        if model.isResponding {
                            ReasoningRow().id(Self.reasoningRowID)
                        }

                        // Let the user close the loop (Finish is a deliberate tap, not AI-guessed).
                        if model.canFinish {
                            finishButton.id(Self.finishID)
                        }
                    }
                    .padding()
                }
                .onChange(of: model.transcript.count) { scrollToBottom(proxy) }
                .onChange(of: model.isResponding) { scrollToBottom(proxy) }
                .onChange(of: model.pendingIntake != nil) { scrollToBottom(proxy) }
            }

            InputBar(text: $model.draft, isResponding: model.isResponding || model.pendingIntake != nil) {
                Task { await model.sendDraft() }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .sheet(item: $selectedProduct) { product in
            ProductSheetView(product: product)
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

    private var finishButton: some View {
        Button { Task { await model.finishConversation() } } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                Text("This works for me — finish")
            }
            .font(.subheadline).fontWeight(.medium)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(Capsule().fill(Theme.hairline))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func transcriptRow(_ item: TranscriptItem) -> some View {
        switch item {
        case .user(_, let text):
            UserBubble(text: text)

        case .assistant(_, let answer, let cards):
            VStack(alignment: .leading, spacing: 12) {
                AssistantText(text: answer)

                if !cards.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(cards) { card in
                                ProductCardView(product: card) { selectedProduct = card }
                            }
                        }
                        .padding(.vertical, 4)
                    }
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
    private static let intakeID = "intake-quiz"
    private static let finishID = "finish-button"

    private func send(_ text: String) {
        Task { await model.send(text) }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.25)) {
            if model.pendingIntake != nil {
                proxy.scrollTo(Self.intakeID, anchor: .bottom)
            } else if model.isResponding {
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
