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

/// The distilled text the vector index embeds: what the product IS and WHO it's for.
/// The full pipe-delimited chunk shares its label boilerplate ("Product Name:",
/// "Fee Structure & Hidden Charges:", "Not specified", …) across all products, which
/// mean-pools every vector toward one centroid and compresses exactly the cosine
/// gaps that distinguish semantically similar banking products. BM25 and the LLM
/// context still use the full chunk — only the embedding input is distilled.
/// Bump `ContextualEmbedder.indexedTextVersion` when changing this scheme.
func buildEmbeddingText(from row: RawRow) -> String {
    [row.name, row.category, row.description, row.benefitsAndFeatures]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: ". ")
}

/// Uses Apple Intelligence to parse messy text fields into standardized numerical variables on-device.
/// Guards first: called 47x in a row during first-launch seeding (one per product), so on a device
/// where the model is unavailable (ineligible hardware, Apple Intelligence off, or assets still
/// downloading) this must fail INSTANTLY rather than attempt — and await the failure of — every
/// single call, which is what made early seeding feel hung on those devices.
func extractNumericalMetadata(from rawText: String) async -> (minIncome: Double, annualFee: Double, maxLimit: Double) {
    guard SystemLanguageModel.default.isAvailable else { return (0.0, 0.0, 0.0) }

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
