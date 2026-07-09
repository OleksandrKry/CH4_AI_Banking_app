//
//  Headless retrieval-quality benchmark. Build & run: scripts/retrieval-eval.sh
//
//  Compiles the app's ACTUAL retrieval sources (HybridRetriever, BM25Search,
//  ContextualEmbedder, VectorMath, IngestionTools) plus the shared
//  RetrievalEvaluator, so what's measured here is what ships. Reports the full
//  ablation matrix: embedding backend × embedded-text variant × fusion weights.
//

import Foundation
import NaturalLanguage

// MARK: - Locate the corpus relative to this file (scripts/retrieval-eval/main.swift)

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // retrieval-eval
    .deletingLastPathComponent()  // scripts
    .deletingLastPathComponent()  // repo root
let jsonURL = repoRoot.appendingPathComponent("CH4_AI_Banking_app/CH4_AI_Banking_app/Data/bca-products.json")

let rows = try RetrievalEvaluator.loadRows(from: jsonURL)
let uniqueNames = Set(rows.map(\.name))
print("📦 corpus: \(rows.count) products, \(uniqueNames.count) unique names, " +
      "\(Set(rows.map(\.category)).count) categories — one chunk per product")
precondition(rows.count == uniqueNames.count, "duplicate product names in corpus")

// MARK: - Embedding backend diagnostics (what models/revisions exist on this host)

if let contextual = NLContextualEmbedding(language: .english) {
    print("🧠 NLContextualEmbedding: \(contextual.modelIdentifier) | revision \(contextual.revision) " +
          "| dim \(contextual.dimension) | maxSeq \(contextual.maximumSequenceLength) " +
          "| assets on device: \(contextual.hasAvailableAssets)")
    print("   scripts: \(contextual.scripts.map(\.rawValue).joined(separator: ", "))")
    print("   languages (\(contextual.languages.count)): " +
          contextual.languages.map(\.rawValue).sorted().joined(separator: " "))
}
let sentenceRevision = NLEmbedding.currentSentenceEmbeddingRevision(for: .english)
let supportedRevisions = Array(NLEmbedding.supportedSentenceEmbeddingRevisions(for: .english))
print("🧠 NLEmbedding.sentenceEmbedding(en): revision \(sentenceRevision) " +
      "(supported: \(supportedRevisions)) | dim \(NLEmbedding.sentenceEmbedding(for: .english)?.dimension ?? -1)")

// MARK: - Backends under evaluation

await ContextualEmbedder.shared.prepare()
print("🔌 active production embedder: \(ContextualEmbedder.shared.modelTag)\n")

var backends: [(name: String, embed: (String) -> [Double]?)] = []
if ContextualEmbedder.shared.modelTag.hasPrefix("contextual") {
    backends.append(("ctx", { ContextualEmbedder.shared.vector(for: $0) }))
} else {
    print("⚠️ contextual assets unavailable on this host — evaluating the fallback only\n")
}
if let sentence = NLEmbedding.sentenceEmbedding(for: .english) {
    backends.append(("sent", { sentence.vector(for: $0) }))
}

// MARK: - Ablation matrix

let textVariants: [(name: String, build: (RawRow) -> String)] = [
    ("full-chunk", buildContextualChunk(from:)),
    ("distilled", buildEmbeddingText(from:)),
]
let weightVariants: [(name: String, weights: HybridRetriever.Weights)] = [
    ("vec-only", .init(vector: 1, bm25: 0)),
    ("hyb 0.4/1", .init(vector: 0.4, bm25: 1)),   // pre-change production weights
    ("hyb 1/1", .init(vector: 1, bm25: 1)),
    ("hyb 1/0.4", .init(vector: 1, bm25: 0.4)),
]

var reports: [RetrievalEvaluator.Report] = []
print(RetrievalEvaluator.header())

// BM25 alone ignores embeddings entirely — one run covers every backend/text combo.
let bm25Corpus = RetrievalEvaluator.buildCorpus(rows: rows, tag: "none",
                                                embedText: { _ in "" }, embed: { _ in nil })
let bm25Report = RetrievalEvaluator.evaluate(label: "bm25-only", corpus: bm25Corpus,
                                             weights: .init(vector: 0, bm25: 1),
                                             tag: "none", embedQuery: { _ in nil })
reports.append(bm25Report)
print(RetrievalEvaluator.summaryLine(bm25Report))

for backend in backends {
    for textVariant in textVariants {
        let tag = "\(backend.name)+\(textVariant.name)"
        let corpus = RetrievalEvaluator.buildCorpus(rows: rows, tag: tag,
                                                    embedText: textVariant.build,
                                                    embed: backend.embed)
        for weightVariant in weightVariants {
            let label = "\(backend.name) | \(textVariant.name) | \(weightVariant.name)"
            let report = RetrievalEvaluator.evaluate(label: label, corpus: corpus,
                                                     weights: weightVariant.weights,
                                                     tag: tag, embedQuery: backend.embed)
            reports.append(report)
            print(RetrievalEvaluator.summaryLine(report))
        }
    }
}

// MARK: - Winner details + confidence calibration

guard let best = reports.max(by: { ($0.mrr, $0.hitRate(at: 1)) < ($1.mrr, $1.hitRate(at: 1)) }) else {
    fatalError("no reports produced")
}
print("\n🏆 best by MRR: \(best.label)\n")
print(RetrievalEvaluator.details(best))

let positives = best.positiveTopConfidences.sorted()
let negativeMax = best.negativeTopConfidences.max() ?? 0
let positiveP10 = RetrievalEvaluator.percentile(positives, 0.10)
print(String(format: """

🎯 confidence calibration (winner config):
   positives: min %.3f | p10 %.3f | median %.3f
   negatives: max %.3f
   suggested minimumConfidence ≈ %.2f (midpoint of neg-max and pos-p10)
""",
             positives.first ?? 0, positiveP10,
             RetrievalEvaluator.percentile(positives, 0.5),
             negativeMax, (negativeMax + positiveP10) / 2))

// Edge cases (typos / vague one-worders / code-switching): category steering
// with a looser bar than the core set.
print("\n— edge set (typos, vague, code-switching) —")
print(RetrievalEvaluator.header())
let edgeBM25 = RetrievalEvaluator.evaluate(label: "edge | bm25-only", corpus: bm25Corpus,
                                           weights: .init(vector: 0, bm25: 1), tag: "none",
                                           queries: RetrievalEvaluator.edgeSet, embedQuery: { _ in nil })
print(RetrievalEvaluator.summaryLine(edgeBM25))
if let ctx = backends.first(where: { $0.name == "ctx" }) {
    let tag = "ctx+distilled"
    let corpus = RetrievalEvaluator.buildCorpus(rows: rows, tag: tag,
                                                embedText: buildEmbeddingText(from:), embed: ctx.embed)
    let edgeCtx = RetrievalEvaluator.evaluate(label: "edge | ctx | distilled | hyb 0.4/1",
                                              corpus: corpus, weights: .current, tag: tag,
                                              queries: RetrievalEvaluator.edgeSet, embedQuery: ctx.embed)
    print(RetrievalEvaluator.summaryLine(edgeCtx))
    print("\n" + RetrievalEvaluator.details(edgeCtx))
}

// Card display policy sweep: how aggressively to suppress the weaker second
// card (margin = max confidence gap to the top hit; 99 disables the margin).
if let ctx = backends.first(where: { $0.name == "ctx" }) {
    let tag = "ctx+distilled"
    let corpus = RetrievalEvaluator.buildCorpus(rows: rows, tag: tag,
                                                embedText: buildEmbeddingText(from:), embed: ctx.embed)
    print("\n— card policy sweep (core set, floor 0.35) —")
    for margin in [0.10, 0.15, 0.20, 99.0] {
        let report = RetrievalEvaluator.evaluateCardPolicy(
            label: "", corpus: corpus, weights: .current, tag: tag,
            floor: HybridRetriever.cardConfidence, margin: margin, embedQuery: ctx.embed)
        print(String(format: "margin %5.2f → precision %.2f | recall %.2f | avg cards %.2f",
                     margin, report.precision, report.recall, report.averageCards))
    }
}

// Raw signal table for the production configuration (contextual + distilled +
// current weights) — the data behind the confidence formula and its floor.
if let ctx = backends.first(where: { $0.name == "ctx" }) {
    let tag = "ctx+distilled"
    let corpus = RetrievalEvaluator.buildCorpus(rows: rows, tag: tag,
                                                embedText: buildEmbeddingText(from:),
                                                embed: ctx.embed)
    print("\n" + RetrievalEvaluator.calibrationDump(corpus: corpus, weights: .current,
                                                    tag: tag, embedQuery: ctx.embed))
}

// Detail dumps for runner-up configs worth comparing by eye.
for report in reports where report.label != best.label && report.mrr >= best.mrr - 0.05 {
    print("\n" + RetrievalEvaluator.details(report))
}
