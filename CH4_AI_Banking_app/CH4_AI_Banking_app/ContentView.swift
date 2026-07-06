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
    @State private var model: ChatViewModel?

    var body: some View {
        ZStack {
            Theme.base.ignoresSafeArea()

            if let model {
                ChatScreen(model: model)
            } else {
                ProgressView().tint(Theme.accent)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            // Build the view model once the SwiftData context is available.
            if model == nil {
                model = ChatViewModel(modelContext: modelContext)
            }
        }
    }
}

private struct ChatScreen: View {
    @Bindable var model: ChatViewModel
    @State private var selectedProduct: ProductCardInfo?

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

                        if model.isResponding {
                            ReasoningRow().id(Self.reasoningRowID)
                        }
                    }
                    .padding()
                }
                .onChange(of: model.transcript.count) { scrollToBottom(proxy) }
                .onChange(of: model.isResponding) { scrollToBottom(proxy) }
            }

            InputBar(text: $model.draft, isResponding: model.isResponding) {
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
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .frame(width: 50, height: 50).foregroundColor(Theme.brandSurface)
                    
                    Image(systemName: "apple.intelligence")
                        .font(.subheadline)
                }
                
                VStack(alignment: .leading) {
                    Text("Assistant")
                        .font(.title2)
                        .bold()
                    Text("Always here to help")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button(
                    action: {
                        // TODO: add new chat
                    },
                    label: {
                        Image(systemName: "plus")
                            .foregroundStyle(.white)
                    }
                )
                .frame(width: 50, height: 50)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(Theme.textTertiary, lineWidth: 1)
                )
            }
            .padding(.horizontal)
            
            Divider()
                .background(Theme.hairline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
//        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var greeting: some View {
        AssistantText(text: "Hi! I'm your BCA assistant. Ask me about loans, accounts, or cards — or start with one of these:")
    }

    @ViewBuilder
    private func transcriptRow(_ item: TranscriptItem) -> some View {
        switch item {
        case .user(_, let text):
            UserBubble(text: text)

        case .assistant(_, let answer, let cards, let followUps):
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

                ForEach(followUps, id: \.question) { followUp in
                    QuizChipsView(followUp: followUp) { send($0) }
                }
            }
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
        .modelContainer(for: [LocalDocument.self, ChatMessage.self], inMemory: true)
}
