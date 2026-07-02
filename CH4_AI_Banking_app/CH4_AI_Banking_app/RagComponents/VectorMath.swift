//
//  VectorMath.swift
//  CH4_AI_Banking_app
//
//  Created by I Gusti Ngurah Bagus Ferry Mahayudha on 02/07/26.
//

import Foundation
import Accelerate

/// Pure, dependency-free linear algebra helpers for dense-vector retrieval.
///
/// Kept separate from `VectorSearch` so the math can be unit tested in isolation,
/// without needing SwiftData, the embedding model, or the running app.
enum VectorMath {

    /// Cosine similarity between two equally-sized vectors, in the range `-1...1`.
    ///
    /// Uses Accelerate's `vDSP` for the dot product and squared magnitudes so the
    /// work runs on the CPU's vector units instead of a scalar Swift loop.
    /// Returns `0` for mismatched, empty, or zero-magnitude inputs (no division by zero).
    static func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }

        let dotProduct = vDSP.dot(a, b)
        let magnitudeA = sqrt(vDSP.sumOfSquares(a))
        let magnitudeB = sqrt(vDSP.sumOfSquares(b))

        guard magnitudeA > 0, magnitudeB > 0 else { return 0 }
        return dotProduct / (magnitudeA * magnitudeB)
    }
}
