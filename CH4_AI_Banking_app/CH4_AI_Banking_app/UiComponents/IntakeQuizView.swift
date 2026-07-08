//
//  IntakeQuizView.swift
//  CH4_AI_Banking_app
//
//  The dynamic intake quiz shown during the `intake` phase: the AI-generated,
//  category-specific questions the user answers *before* getting recommendations.
//  Each question offers tappable options; once answered, "Get recommendations"
//  compiles the answers and moves the conversation into the product loop.
//

import SwiftUI

struct IntakeQuizView: View {
    let intake: PendingIntake
    var onSelect: (_ question: String, _ option: String) -> Void
    var onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("A few quick questions")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            ForEach(intake.questions, id: \.question) { question in
                VStack(alignment: .leading, spacing: 8) {
                    Text(question.question)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    FlowLayout(spacing: 8) {
                        ForEach(question.options, id: \.self) { option in
                            SelectableChip(
                                title: option,
                                isSelected: intake.answers[question.question] == option
                            ) {
                                onSelect(question.question, option)
                            }
                        }
                    }
                }
            }

            Button(action: onSubmit) {
                Text("Get recommendations")
                    .font(.headline)
                    .foregroundStyle(Theme.base)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Capsule().fill(intake.allAnswered ? Theme.accent : Theme.textTertiary))
            }
            .buttonStyle(.plain)
            .disabled(!intake.allAnswered)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.surface1)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Theme.hairline, lineWidth: 1)
                )
        )
    }
}

#Preview {
    IntakeQuizView(
        intake: PendingIntake(
            query: "I want a loan",
            category: "Housing Loan",
            questions: [
                FollowUpQuestion(question: "What's the loan for?", options: ["New home", "Renovation", "Take over"]),
                FollowUpQuestion(question: "Preferred tenure?", options: ["≤10 years", "10–20 years"])
            ],
            answers: ["What's the loan for?": "Renovation"]
        ),
        onSelect: { _, _ in },
        onSubmit: {}
    )
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Theme.base)
}
