//
//  StatusIndicators.swift
//  CH4_AI_Banking_app
//
//  Section 09: lightweight, native-feeling feedback — a three-dot typing rhythm
//  and an accent "reasoning" row while the assistant is working.
//

import SwiftUI

/// Three dots with a staggered pulse.
struct TypingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Theme.textSecondary)
                    .frame(width: 6, height: 6)
                    .opacity(animating ? 1 : 0.3)
                    .animation(
                        .easeInOut(duration: 0.6).repeatForever().delay(Double(index) * 0.2),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}

/// Accent status row shown while a search + generation is in flight.
struct ReasoningRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Theme.accent).frame(width: 6, height: 6)
            Text("Searching products")
                .font(.footnote)
                .foregroundStyle(Theme.accent)
            TypingIndicator()
        }
    }
}

#Preview {
    ReasoningRow()
        .padding()
        .background(Theme.base)
}
