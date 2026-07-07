//
//  ConversationHistoryView.swift
//  CH4_AI_Banking_app
//
//  Browsable list of past conversations (most recent first, capped at 10). Tapping
//  a row reopens that conversation in the chat. A new query always starts fresh.
//

import SwiftUI
import SwiftData

struct ConversationHistoryView: View {
    /// Called with the conversation the user tapped.
    var onSelect: (Conversation) -> Void

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Conversation.startedAt, order: .reverse) private var conversations: [Conversation]

    private var recent: [Conversation] { Array(conversations.prefix(10)) }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.base.ignoresSafeArea()

                if recent.isEmpty {
                    Text("No conversations yet.")
                        .font(.body)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(recent) { conversation in
                                Button { onSelect(conversation) } label: {
                                    row(conversation)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .tint(Theme.accent)
                }
            }
            .toolbarBackground(Theme.base, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ conversation: Conversation) -> some View {
        HStack(spacing: 12) {
            CategoryAvatar(category: conversation.category, size: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text(conversation.title.isEmpty ? "Conversation" : conversation.title)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(conversation.startedAt.formatted(.relative(presentation: .named)))
                    .font(.footnote)
                    .foregroundStyle(Theme.textTertiary)
            }

            Spacer(minLength: 0)

            phaseBadge(conversation.phase)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.surface1)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Theme.hairline, lineWidth: 1)
                )
        )
    }

    private func phaseBadge(_ phase: ConversationPhase) -> some View {
        let (label, color): (String, Color) = switch phase {
        case .intake:   ("Intake", Theme.accent)
        case .loop:     ("Active", Theme.accent)
        case .finished: ("Finished", Theme.textTertiary)
        }
        return Text(label)
            .font(.caption).fontWeight(.semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

#Preview {
    ConversationHistoryView { _ in }
        .modelContainer(for: [Conversation.self], inMemory: true)
}
