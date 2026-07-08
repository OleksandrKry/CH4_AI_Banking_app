//
//  InputBar.swift
//  CH4_AI_Banking_app
//
//  Section 04: the input bar, always visible at the bottom of the chat. The
//  microphone and send controls each hold a 44pt hit target (Section 03).
//

import SwiftUI

struct InputBar: View {
    @Binding var text: String
    var isResponding: Bool
    var placeholder: String = "Ask follow-up…"
    var onSend: () -> Void

    @State private var speechRecognizer = SpeechRecognizer()

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isResponding
    }

    var body: some View {
        VStack(spacing: 6) {
            // Error banner for speech issues
            if let error = speechRecognizer.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button {
                        speechRecognizer.errorMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(.horizontal, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(spacing: 10) {
                // Microphone button
                Button {
                    speechRecognizer.toggleListening()
                } label: {
                    ZStack {
                        Image(systemName: speechRecognizer.isListening ? "mic.fill" : "microphone")
                            .font(.body)
                            .foregroundStyle(speechRecognizer.isListening ? .white : Theme.textSecondary)
                            .frame(width: 44, height: 44)
                            .background(
                                Circle()
                                    .fill(speechRecognizer.isListening ? Color.red : .clear)
                            )
                            .background(
                                Circle()
                                    .stroke(
                                        speechRecognizer.isListening ? Color.red.opacity(0.4) : Theme.hairline,
                                        lineWidth: speechRecognizer.isListening ? 2 : 1
                                    )
                                    .scaleEffect(speechRecognizer.isListening ? 1.25 : 1.0)
                                    .opacity(speechRecognizer.isListening ? 0.6 : 1.0)
                                    .animation(
                                        speechRecognizer.isListening
                                            ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true)
                                            : .default,
                                        value: speechRecognizer.isListening
                                    )
                            )
                    }
                }
                .disabled(isResponding)

                TextField(placeholder, text: $text, axis: .vertical)
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
        .animation(.easeInOut(duration: 0.2), value: speechRecognizer.errorMessage != nil)
        .onAppear {
            speechRecognizer.requestAuthorization()
        }
        // Stream recognized speech into the text field
        .onChange(of: speechRecognizer.transcript) { _, newValue in
            if !newValue.isEmpty {
                text = newValue
            }
        }
        // When user stops recording, auto-stop and keep the transcribed text
        .onChange(of: speechRecognizer.isListening) { _, isListening in
            if !isListening && !speechRecognizer.transcript.isEmpty {
                text = speechRecognizer.transcript
            }
        }
    }
}

#Preview {
    InputBar(text: .constant(""), isResponding: false) {}
        .padding()
        .background(Theme.base)
}

