//
//  ChatBubbles.swift
//  CH4_AI_Banking_app
//
//  Section 04: plain text for the assistant, a brand-tinted bubble for the user.
//

import SwiftUI

/// User message — right-aligned, brand-blue-tinted fill.
struct UserBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            Text(text)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Theme.brandSurface.opacity(0.35))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Theme.brandSurface.opacity(0.5), lineWidth: 1)
                        )
                )
        }
    }
}

/// Assistant message — unboxed plain text on the base background, with an identity marker.
/// Renders markdown (bold, italic, etc.) returned by the AI.
struct AssistantText: View {
    let text: String

    /// Parse the raw markdown string once; fall back to plain text if it fails.
    private var attributed: AttributedString {
        (try? AttributedString(markdown: text,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(text)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.footnote)
                .foregroundStyle(Theme.accent)
                .padding(.top, 2)
            Text(attributed)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        UserBubble(text: "I need a loan for a new car, around IDR 200,000,000.")
        AssistantText(text: "Got it. A few quick questions so I can match you with the right products — how long would you like to repay?")
    }
    .padding()
    .frame(maxHeight: .infinity)
    .background(Theme.base)
}
