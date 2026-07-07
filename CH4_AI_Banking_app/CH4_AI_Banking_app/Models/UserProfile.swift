//
//  UserProfile.swift
//  CH4_AI_Banking_app
//
//  Persisted user profile collected by the onboarding quiz *before* the first
//  AI answer. RAGSystem reads it each turn so the model can personalize and
//  pre-qualify product recommendations (student vs. business owner, income,
//  travel needs, foreigner status, mortgage intent).
//

import Foundation
import SwiftData

@Model
final class UserProfile {
    var occupation: String          // e.g. "Student", "Business owner"
    var incomeBracket: String       // Human label, e.g. "IDR 10M–25M"
    var monthlyIncome: Double        // Representative value used for salary pre-filtering
    var travelsAbroad: Bool
    var isForeigner: Bool
    var hasForeignBankAccount: Bool
    var wantsHouseMortgage: Bool
    var isComplete: Bool             // True once the onboarding quiz is submitted
    var updatedAt: Date

    init(
        occupation: String = "",
        incomeBracket: String = "",
        monthlyIncome: Double = 0,
        travelsAbroad: Bool = false,
        isForeigner: Bool = false,
        hasForeignBankAccount: Bool = false,
        wantsHouseMortgage: Bool = false,
        isComplete: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.occupation = occupation
        self.incomeBracket = incomeBracket
        self.monthlyIncome = monthlyIncome
        self.travelsAbroad = travelsAbroad
        self.isForeigner = isForeigner
        self.hasForeignBankAccount = hasForeignBankAccount
        self.wantsHouseMortgage = wantsHouseMortgage
        self.isComplete = isComplete
        self.updatedAt = updatedAt
    }

    /// A compact block the LLM reads to tailor its answer. Computed, so it isn't persisted.
    var promptSummary: String {
        """
        - Occupation: \(occupation.isEmpty ? "Unknown" : occupation)
        - Monthly income: \(incomeBracket.isEmpty ? "Unknown" : incomeBracket)
        - Travels abroad: \(travelsAbroad ? "Yes" : "No")
        - Foreign national (non-Indonesian): \(isForeigner ? "Yes" : "No")
        - Holds a foreign bank account: \(hasForeignBankAccount ? "Yes" : "No")
        - Interested in a house mortgage: \(wantsHouseMortgage ? "Yes" : "No")
        """
    }
}
