//
//  TurnRoute.swift
//  CH4_AI_Banking_app
//
//  The intent gate that sits in front of product retrieval. Each user turn is
//  routed by the on-device model (guided generation — no CoreML) into one of
//  three actions, so the app only surfaces products once the user actually wants
//  one. Until then it keeps conversing or asks a clarifying question.
//

import Foundation
import FoundationModels

@Generable
enum RouteDecision {
    case converse   // Not clearly product-seeking yet — reply and keep the conversation open
    case clarify    // Heading toward a product, but one detail is needed first
    case recommend  // User clearly wants a banking product now — run retrieval
}

@Generable
struct TurnRoute {
    @Guide(description: "How to handle the user's latest message: converse, clarify, or recommend.")
    let decision: RouteDecision

    @Guide(description: "A short, friendly reply to show the user for converse/clarify. May be empty when recommending.")
    let reply: String
}
