//
//  FollowUpQuestion.swift
//  CH4_AI_Banking_app
//
//  The "questions to users" output — the design's inline quiz chips: a short
//  clarifying question paired with a few tappable answer options. These are
//  `@Generable` so the on-device model fills them in via guided generation,
//  guaranteeing well-formed output with no manual string parsing.
//

import Foundation
import FoundationModels

/// A single clarifying question the assistant can ask, with tappable chip options.
@Generable
struct FollowUpQuestion: Equatable {
    @Guide(description: "A short clarifying question to refine the user's needs, at most about ten words.")
    let question: String

    @Guide(description: "Two to four short tappable answer options, one to three words each.", .minimumCount(2), .maximumCount(4))
    var options: [String]
}

/// Container the model fills in — the intake questions asked BEFORE the first
/// recommendation. Constrained decoding guarantees the 3–6 shape; the UI adds a
/// free-text "own answer" and a skip affordance per question on top.
@Generable
struct FollowUpSuggestions: Equatable {
    @Guide(description: "Three to six clarifying questions, ordered most important first.", .minimumCount(3), .maximumCount(6))
    var questions: [FollowUpQuestion]
}
