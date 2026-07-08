//
//  ContextualEmbedder.swift
//  CH4_AI_Banking_app
//
//  Produces sentence vectors for the cosine-similarity pipeline. Prefers Apple's
//  transformer-based `NLContextualEmbedding` (richer understanding), but its assets
//  may be unavailable/undownloadable on some hosts — so it falls back to the
//  always-available `NLEmbedding.sentenceEmbedding`. Whichever is active is exposed
//  via `modelTag`, so stored documents can be re-embedded if the model changes.
//
//  Loaded once via `prepare()` at launch; reads are synchronous afterwards.
//

import Foundation
import NaturalLanguage

final class ContextualEmbedder: @unchecked Sendable {
    static let shared = ContextualEmbedder()

    private var contextual: NLContextualEmbedding?
    private let fallback = NLEmbedding.sentenceEmbedding(for: .english)

    private init() {}

    /// True if any embedder (contextual or fallback) can produce vectors.
    var isReady: Bool { contextual != nil || fallback != nil }

    /// Output dimension of the active embedder.
    var dimension: Int? { contextual?.dimension ?? fallback?.dimension }

    /// Identifies the active model, so seeded vectors can be invalidated on a model switch.
    var modelTag: String {
        if let contextual { return "contextual.\(contextual.modelIdentifier)" }
        if fallback != nil { return "nlembedding.sentence.en" }
        return "none"
    }

    /// Version of the *text* the index embeds (see `buildEmbeddingText`). Bump it
    /// whenever the embedded text scheme changes so existing stores re-seed even
    /// though the model itself didn't change.
    static let indexedTextVersion = "etext2"

    /// Tag stored on every seeded document. Query-time vectors are only comparable
    /// with stored vectors carrying this exact tag (same model AND text scheme).
    var indexTag: String { "\(modelTag)+\(Self.indexedTextVersion)" }

    /// Attempts to load the contextual model (downloading assets if possible). If that
    /// fails, the fallback embedder is used. Safe to call repeatedly.
    func prepare() async {
        guard contextual == nil else { return }
        guard let candidate = NLContextualEmbedding(language: .english) else {
            print("ℹ️ No contextual model for English; using NLEmbedding fallback.")
            return
        }

        if !candidate.hasAvailableAssets {
            let available = await withCheckedContinuation { continuation in
                candidate.requestAssets { result, error in
                    if let error {
                        print("⚠️ Contextual asset request failed: \(error.localizedDescription)")
                    }
                    continuation.resume(returning: result == .available)
                }
            }
            guard available else {
                print("ℹ️ Contextual assets unavailable; using NLEmbedding fallback.")
                return
            }
        }

        do {
            try candidate.load()
            contextual = candidate
        } catch {
            print("⚠️ Contextual load failed; using NLEmbedding fallback: \(error.localizedDescription)")
        }
    }

    /// Sentence vector for `text` — mean-pooled contextual vector if available,
    /// otherwise the fallback sentence embedding. Nil only if no model exists.
    func vector(for text: String) -> [Double]? {
        guard !text.isEmpty else { return nil }

        if let contextual, let pooled = Self.meanPooledVector(for: text, using: contextual) {
            return pooled
        }

        return fallback?.vector(for: text)
    }

    /// Mean-pools the subword token vectors into one sentence vector — the pooling
    /// Apple documents for whole-text representations of contextual embeddings.
    /// `language` stays nil so the model auto-detects: the script-level model covers
    /// every Latin-script language, so Indonesian queries embed meaningfully too.
    static func meanPooledVector(for text: String, using model: NLContextualEmbedding) -> [Double]? {
        guard let result = try? model.embeddingResult(for: text, language: nil) else { return nil }

        var sum = [Double](repeating: 0, count: model.dimension)
        var tokenCount = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { tokenVector, _ in
            for index in 0..<min(tokenVector.count, sum.count) {
                sum[index] += tokenVector[index]
            }
            tokenCount += 1
            return true
        }

        guard tokenCount > 0 else { return nil }
        return sum.map { $0 / Double(tokenCount) } // mean pooling
    }
}
