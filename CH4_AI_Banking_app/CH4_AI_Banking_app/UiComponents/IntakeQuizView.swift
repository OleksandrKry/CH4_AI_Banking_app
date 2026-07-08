//
//  IntakeQuizView.swift
//  CH4_AI_Banking_app
//
//  The dynamic intake quiz shown during the `intake` phase: 3–6 AI-generated,
//  category-specific questions the user answers *before* getting recommendations.
//  Mirrors the reference interaction pattern on mobile: numbered questions with
//  tappable options, a free-text "own answer" row (pencil) per question, and a
//  per-question Skip. Typing in the main input instead answers directly.
//

import SwiftUI

struct IntakeQuizView: View {
    let intake: PendingIntake
    var onSelect: (_ question: String, _ option: String) -> Void
    var onCustom: (_ question: String, _ text: String) -> Void
    var onToggleSkip: (_ question: String) -> Void
    var onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            ForEach(Array(intake.questions.enumerated()), id: \.element.question) { index, question in
                questionCard(number: index + 1, question: question)
            }

            Button(action: onSubmit) {
                Text("Get recommendations")
                    .font(.headline)
                    .foregroundStyle(Theme.base)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Capsule().fill(intake.allResolved ? Theme.accent : Theme.textTertiary))
            }
            .buttonStyle(.plain)
            .disabled(!intake.allResolved)

            Text("…or just type your answer in the box below.")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
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

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("A few quick questions")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Text("\(intake.answeredCount)/\(intake.questions.count)")
                .font(.caption).monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: - One question: options + own answer + skip

    private func questionCard(number: Int, question: FollowUpQuestion) -> some View {
        let key = question.question
        let isSkipped = intake.skipped.contains(key)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number)")
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Theme.hairline))

                Text(key)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)

                Spacer(minLength: 8)

                Button(isSkipped ? "Skipped" : "Skip") { onToggleSkip(key) }
                    .font(.caption)
                    .foregroundStyle(isSkipped ? Theme.accent : Theme.textTertiary)
                    .buttonStyle(.plain)
                    .frame(minHeight: 28)
            }

            if !isSkipped {
                FlowLayout(spacing: 8) {
                    ForEach(question.options, id: \.self) { option in
                        SelectableChip(
                            title: option,
                            isSelected: intake.answers[key] == option
                        ) {
                            onSelect(key, option)
                        }
                    }
                }

                customAnswerField(for: question)
            }
        }
        .opacity(isSkipped ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.15), value: isSkipped)
    }

    /// The "own version" row: a pencil-marked free-text field whose committed
    /// text becomes the answer (and deselects the chips). Single source of truth
    /// is PendingIntake — the binding reads/writes through the view model.
    private func customAnswerField(for question: FollowUpQuestion) -> some View {
        let key = question.question
        let isCustom = intake.isCustomAnswer(for: key)
        let text = Binding<String>(
            get: { intake.isCustomAnswer(for: key) ? (intake.answers[key] ?? "") : "" },
            set: { onCustom(key, $0) }
        )

        return HStack(spacing: 8) {
            Image(systemName: "pencil")
                .font(.footnote)
                .foregroundStyle(isCustom ? Theme.accent : Theme.textTertiary)
            TextField("Your own answer…", text: text)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.accent)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
        .background(
            Capsule()
                .fill(Theme.base)
                .overlay(
                    Capsule().stroke(isCustom ? Theme.accent.opacity(0.5) : Theme.hairline, lineWidth: 1)
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
                FollowUpQuestion(question: "Preferred tenure?", options: ["≤10 years", "10–20 years"]),
                FollowUpQuestion(question: "Roughly how much?", options: ["< IDR 1B", "IDR 1–5B", "> IDR 5B"])
            ],
            answers: [
                "What's the loan for?": "Renovation",
                "Preferred tenure?": "about 15 years"   // custom "own answer"
            ],
            skipped: ["Roughly how much?"]
        ),
        onSelect: { _, _ in },
        onCustom: { _, _ in },
        onToggleSkip: { _ in },
        onSubmit: {}
    )
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Theme.base)
}
