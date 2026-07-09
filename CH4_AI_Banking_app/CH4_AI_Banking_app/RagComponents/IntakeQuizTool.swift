//
//  IntakeQuizTool.swift
//  CH4_AI_Banking_app
//
//  Makes the qualification questionnaire a TOOL the session model calls, so the
//  model itself routes every turn: greetings/identity/general questions answer
//  directly (no tool), product-seeking turns with unknown preferences call this,
//  and qualified needs call the catalog tool. No brittle pre-routing in the app.
//
//  The tool only FLAGS the request (the questions are generated after the turn
//  completes — nesting a guided-generation session inside a tool call would race
//  the in-flight respond()). The view model reads `requestedNeed` and starts the
//  sequential question flow.
//

import Foundation
import FoundationModels

final class IntakeQuizTool: Tool {
    let name = "askQualifyingQuestions"
    let description = """
        Starts a short in-app questionnaire (3-6 questions, shown one at a time) \
        about the user's needs before recommending products. Call ONLY when the \
        user wants to find, compare, get, or apply for a banking product or \
        service AND their preferences are not yet known in this conversation. \
        NEVER call it for greetings, chit-chat, or questions about you or the bank.
        """

    @Generable
    struct Arguments {
        @Guide(description: "The product need in the user's own words, e.g. 'credit card for travel'.")
        var need: String
    }

    /// Set when the model requested the questionnaire this turn.
    @MainActor private(set) var requestedNeed: String?

    @MainActor func beginTurn() {
        requestedNeed = nil
    }

    func call(arguments: Arguments) async throws -> String {
        await MainActor.run {
            requestedNeed = arguments.need
            return "Questionnaire prepared — the app will show the questions now. Reply with ONE short friendly sentence asking the user to answer them. Do not list any questions yourself."
        }
    }
}
