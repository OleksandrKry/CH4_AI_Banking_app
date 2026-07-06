//
//  InputBar.swift
//  CH4_AI_Banking_app
//
//  Section 04: the input bar, always visible at the bottom of the chat. The "+"
//  and send controls each hold a 44pt hit target (Section 03).
//

import SwiftUI

struct InputBar: View {
    @Binding var text: String
    var isResponding: Bool
    var onSend: () -> Void

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isResponding
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "microphone.fill")
                .font(.body)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 44, height: 44)
                .background(Circle().stroke(Theme.hairline, lineWidth: 1))

            TextField("Ask follow-up…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.accent)
                .lineLimit(1...4)
                .onSubmit(onSend)

            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.headline)
                    .foregroundStyle(Theme.base)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(canSend ? Theme.accent : Theme.textTertiary))
            }
            .disabled(!canSend)
        }
        .padding(6)
        .background(
            Capsule()
                .fill(Theme.surface1)
                .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
        )
    }
}

#Preview {
    InputBar(text: .constant(""), isResponding: false) {}
        .padding()
        .background(Theme.base)
}
