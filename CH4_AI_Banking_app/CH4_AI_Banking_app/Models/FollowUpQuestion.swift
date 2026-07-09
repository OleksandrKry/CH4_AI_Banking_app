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

/// The intake question batch — generated ONCE per conversation (constrained
/// decoding guarantees 3–6), then presented to the user one question at a time
/// with no further model calls between questions.
@Generable
struct FollowUpSuggestions: Equatable {
    @Guide(description: "Three to six short clarifying questions, ordered most important first.", .minimumCount(3), .maximumCount(6))
    var questions: [FollowUpQuestion]
}
