//
//  ChipViews.swift
//  CH4_AI_Banking_app
//
//  Quiz chips (Section 04) and starter suggestion chips (Section 09). Every chip
//  holds a 44pt hit target even when the label is smaller.
//

import SwiftUI

/// A single pill-shaped chip. `accented` gives it the brand-tinted quiz-chip look.
struct ChipButton: View {
    let title: String
    var accented: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(accented ? Theme.tintText : Theme.textPrimary)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(
                    Capsule().fill(accented ? Theme.brandSurface.opacity(0.35) : Theme.hairline)
                )
                .overlay(
                    Capsule().stroke(accented ? Theme.brandSurface.opacity(0.6) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

/// An assistant clarifying question with its tappable answer options.
struct QuizChipsView: View {
    let followUp: FollowUpQuestion
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(followUp.question)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
            FlowLayout(spacing: 8) {
                ForEach(followUp.options, id: \.self) { option in
                    ChipButton(title: option, accented: true) { onSelect(option) }
                }
            }
        }
    }
}

/// Starter suggestions shown before the first message.
struct StarterChipsView: View {
    let onSelect: (String) -> Void
    private let suggestions = ["Find a loan", "Compare accounts", "Which card fits me?"]

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(suggestions, id: \.self) { suggestion in
                ChipButton(title: suggestion) { onSelect(suggestion) }
            }
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 24) {
        QuizChipsView(
            followUp: FollowUpQuestion(question: "What's the loan for?", options: ["New car", "Home renovation", "Something else…"])
        ) { _ in }
        StarterChipsView { _ in }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Theme.base)
}
