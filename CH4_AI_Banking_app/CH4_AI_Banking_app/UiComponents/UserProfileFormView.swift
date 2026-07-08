//
//  UserProfileFormView.swift
//  CH4_AI_Banking_app
//
//  Onboarding quiz shown before the first AI answer. Collects who the user is so
//  the assistant can pre-qualify and personalize recommendations. Saved to the
//  UserProfile SwiftData model and reused by RAGSystem on every turn.
//

import SwiftUI
import SwiftData

struct UserProfileFormView: View {
    /// Called after the profile is saved so the parent can move on to the chat.
    var onComplete: () -> Void = {}

    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [UserProfile]

    @State private var occupation = ""
    @State private var incomeBracket = ""
    @State private var travelsAbroad = false
    @State private var isForeigner = false
    @State private var hasForeignBankAccount = false
    @State private var wantsHouseMortgage = false

    private let occupations = ["Student", "Salaried employee", "Business owner", "Professional", "Retired", "Other"]

    // Representative monthly income (IDR) per bracket, used for salary pre-filtering.
    private let incomeBrackets: [(label: String, value: Double)] = [
        ("Below IDR 3M", 2_000_000),
        ("IDR 3M–10M", 3_000_000),
        ("IDR 10M–25M", 10_000_000),
        ("IDR 25M–50M", 25_000_000),
        ("Above IDR 50M", 50_000_000)
    ]

    private var canContinue: Bool { !occupation.isEmpty && !incomeBracket.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                chipSection(title: "What's your current occupation?", options: occupations, selection: $occupation)
                chipSection(title: "What's your monthly income?", options: incomeBrackets.map(\.label), selection: $incomeBracket)

                VStack(spacing: 4) {
                    ToggleRow(title: "Do you travel abroad often?", isOn: $travelsAbroad)
                    ToggleRow(title: "Are you a foreign national (non-Indonesian)?", isOn: $isForeigner)
                    ToggleRow(title: "Do you hold a foreign bank account?", isOn: $hasForeignBankAccount)
                    ToggleRow(title: "Planning to apply for a house mortgage?", isOn: $wantsHouseMortgage)
                }

                continueButton
            }
            .padding(24)
        }
        .background(Theme.base)
        .onAppear(perform: loadExistingProfile)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tell us about you")
                .font(.largeTitle).fontWeight(.bold)
                .foregroundStyle(Theme.textPrimary)
            Text("A few quick questions so I can match you with the right BCA products.")
                .font(.body)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func chipSection(title: String, options: [String], selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            FlowLayout(spacing: 8) {
                ForEach(options, id: \.self) { option in
                    SelectableChip(title: option, isSelected: selection.wrappedValue == option) {
                        selection.wrappedValue = option
                    }
                }
            }
        }
    }

    private var continueButton: some View {
        Button(action: save) {
            Text("Continue")
                .font(.headline)
                .foregroundStyle(Theme.base)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Capsule().fill(canContinue ? Theme.accent : Theme.textTertiary))
        }
        .buttonStyle(.plain)
        .disabled(!canContinue)
        .padding(.top, 8)
    }

    // MARK: - Persistence

    private func loadExistingProfile() {
        guard let profile = profiles.first else { return }
        occupation = profile.occupation
        incomeBracket = profile.incomeBracket
        travelsAbroad = profile.travelsAbroad
        isForeigner = profile.isForeigner
        hasForeignBankAccount = profile.hasForeignBankAccount
        wantsHouseMortgage = profile.wantsHouseMortgage
    }

    private func save() {
        let income = incomeBrackets.first { $0.label == incomeBracket }?.value ?? 0

        let profile = profiles.first ?? {
            let new = UserProfile()
            modelContext.insert(new)
            return new
        }()

        profile.occupation = occupation
        profile.incomeBracket = incomeBracket
        profile.monthlyIncome = income
        profile.travelsAbroad = travelsAbroad
        profile.isForeigner = isForeigner
        profile.hasForeignBankAccount = hasForeignBankAccount
        profile.wantsHouseMortgage = wantsHouseMortgage
        profile.isComplete = true
        profile.updatedAt = Date()

        try? modelContext.save()
        onComplete()
    }
}

// MARK: - Small form controls

/// A pill chip with a selected (accent-filled) state.
struct SelectableChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(isSelected ? Theme.base : Theme.textPrimary)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(Capsule().fill(isSelected ? Theme.accent : Theme.hairline))
        }
        .buttonStyle(.plain)
    }
}

/// A labeled yes/no row backed by a Toggle.
struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
        }
        .tint(Theme.accent)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }
}

#Preview {
    UserProfileFormView()
        .preferredColorScheme(.dark)
        .modelContainer(for: UserProfile.self, inMemory: true)
}
