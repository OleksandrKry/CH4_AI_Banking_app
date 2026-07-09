//
//  QuestionCardView.swift
//  CH4_AI_Banking_app
//
//  One decision-tree qualifying question, asked one turn at a time (never a
//  batch). Mirrors the reference interaction: numbered full-width option rows,
//  a pencil "own answer" row, and a Skip action. Every choice is sent as the
//  user's next chat message, so the conversation stays a plain chatbot flow.
//

import SwiftUI

struct QuestionCardView: View {
    let question: FollowUpQuestion
    /// "2/4" while walking the intake flow; nil for one-off clarifications.
    var progress: String? = nil
    /// Called with the text to send as the user's answer.
    var onAnswer: (String) -> Void
    /// Skip action; falls back to answering "no preference" when unset.
    var onSkip: (() -> Void)? = nil

    @State private var customAnswer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(question.options.enumerated()), id: \.element) { index, option in
                Button {
                    onAnswer(option)
                } label: {
                    HStack(spacing: 12) {
                        numberBadge("\(index + 1)")
                        Text(option)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textPrimary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Rectangle().fill(Theme.hairline).frame(height: 1)
            }

            // "Own answer" row (pencil) + progress + Skip, like the reference design.
            HStack(spacing: 12) {
                numberBadge(nil)
                TextField("Your own answer…", text: $customAnswer)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .tint(Theme.accent)
                    .onSubmit(submitCustomAnswer)

                if let progress {
                    Text(progress)
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                }

                Button("Skip") {
                    if let onSkip {
                        onSkip()
                    } else {
                        onAnswer("No preference — please just continue.")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .frame(minHeight: 34)
                .background(Capsule().fill(Theme.hairline))
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.surface1)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Theme.hairline, lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func submitCustomAnswer() {
        let trimmed = customAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onAnswer(trimmed)
    }

    /// Numbered badge for options; pencil badge for the own-answer row.
    @ViewBuilder
    private func numberBadge(_ number: String?) -> some View {
        Group {
            if let number {
                Text(number).font(.caption).monospacedDigit()
            } else {
                Image(systemName: "pencil").font(.caption)
            }
        }
        .foregroundStyle(Theme.textSecondary)
        .frame(width: 26, height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.hairline))
    }
}

#Preview {
    QuestionCardView(
        question: FollowUpQuestion(
            question: "What will you mostly use the card for?",
            options: ["Everyday spending", "Travel & miles", "Online shopping", "Premium perks"]
        ),
        onAnswer: { _ in }
    )
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Theme.base)
}
