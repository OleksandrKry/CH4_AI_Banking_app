//
//  IngestionTools.swift
//  CH4_AI_Banking_app
//
//  Created by I Gusti Ngurah Bagus Ferry Mahayudha on 03/07/26.
//

import Foundation
import FoundationModels

/// Turns a single spreadsheet row dictionary into an explicit, contextually rich sentence block.
func buildContextualChunk(from row: RawRow) -> String {
    return """
    Product Name: \(row.name) | \
    Product Category: \(row.category) | \
    Description: \(row.description ?? "Not specified") | \
    Price & Annual Cost: \(row.price ?? "Not specified") | \
    Fee Structure & Hidden Charges: \(row.fees ?? "Not specified") | \
    Transaction, Credit, & Cash Withdrawal Limits: \(row.limits ?? "Not specified") | \
    Requirements to Apply & Eligibility Criteria: \(row.requirements ?? "Not specified") | \
    Product Benefits & Key Features: \(row.benefitsAndFeatures ?? "Not specified") | \
    Minimum Income Requirement to Apply: \(row.minApply ?? "Not specified")
    """
}

/// Uses Apple Intelligence to parse messy text fields into standardized numerical variables on-device
func extractNumericalMetadata(from rawText: String) async -> (minIncome: Double, annualFee: Double, maxLimit: Double) {
    let extractionPrompt = """
    Analyze the unstructured banking product specifications provided below. 
    Extract the following three fields as pure numbers (integers or doubles) with no currency symbols or commas.
    
    1. minIncome: The absolute minimum monthly income required to apply. Convert shortcuts like "3M" to 3000000. If invitation-only or not stated, return 0.
    2. annualFee: The basic yearly price or fee. Extract only the baseline digit (e.g., convert "IDR 125,000/year" to 125000). If free, return 0.
    3. maxLimit: The baseline minimum or maximum transaction/credit card limit if explicitly mentioned (e.g., "Min limit IDR 3M" to 3000000). If variable or based on approval, return 0.
    
    CRITICAL FORMATTING RULES:
    - Respond ONLY with a valid, clean JSON block matching the keys exactly.
    - Do not write any explanations or Markdown formatting blocks.
    
    Target Text:
    \(rawText)
    
    JSON Output:
    """
    
    do {
        let session = LanguageModelSession()
        let result = try await session.respond(to: extractionPrompt)
        let cleanJSONString = result.content.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if let data = cleanJSONString.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            
            let income = json["minIncome"] as? Double ?? (json["minIncome"] as? Int).map { Double($0) } ?? 0.0
            let fee = json["annualFee"] as? Double ?? (json["annualFee"] as? Int).map { Double($0) } ?? 0.0
            let limit = json["maxLimit"] as? Double ?? (json["maxLimit"] as? Int).map { Double($0) } ?? 0.0
            
            return (income, fee, limit)
        }
    } catch {
        print("⚠️ Apple Intelligence data extraction parser error: \(error.localizedDescription)")
    }
    
    // Fail-safe default fallback state if extraction fails
    return (0.0, 0.0, 0.0)
}
