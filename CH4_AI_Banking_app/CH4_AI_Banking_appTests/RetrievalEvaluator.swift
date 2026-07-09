//
//  RetrievalEvaluator.swift
//  CH4_AI_Banking_appTests
//
//  Golden-set benchmark for the hybrid retrieval pipeline: 20 realistic banking
//  queries (+2 Indonesian, +3 out-of-scope negatives), each labeled with the
//  product(s) that must be retrieved. Produces the metrics that make retrieval
//  quality visible — Hit@1/2/3, MRR@5, per-query latency — plus the confidence
//  separation used to calibrate `HybridRetriever.minimumConfidence`.
//
//  Compiled in two places on purpose:
//   - by the test target (RetrievalAccuracyTests) via @testable import
//   - by scripts/retrieval-eval.sh together with the RagComponents sources,
//     for headless calibration runs on macOS (no simulator required).
//

#if canImport(CH4_AI_Banking_app)
@testable import CH4_AI_Banking_app
#endif
import Foundation

/// One labeled query. Retrieval scores a hit when ANY expected product appears;
/// several sets contain siblings that are all legitimately correct answers.
struct GoldenQuery {
    let text: String
    let expected: Set<String> // exact "Name" values from bca-products.json
    let language: String

    init(_ text: String, _ expected: Set<String>, language: String = "en") {
        self.text = text
        self.expected = expected
        self.language = language
    }
}

enum RetrievalEvaluator {

    // MARK: - Golden set

    /// 20 core queries + 2 Indonesian. Deliberately weighted toward confusable
    /// clusters — the KPR variants, the transfer rails, the savings tiers, the
    /// Singapore Airlines cards — where banking products are semantically close.
    static let goldenSet: [GoldenQuery] = [
        // Cards: premium/travel cluster
        GoldenQuery("Which credit card gives me airport lounge access?",
                    ["BCA Mastercard World", "BCA American Express Platinum", "BCA JCB Black"]),
        GoldenQuery("I want to earn Singapore Airlines miles when I spend",
                    ["BCA Singapore Airlines KrisFlyer Visa Signature",
                     "BCA Singapore Airlines KrisFlyer Visa Infinite",
                     "BCA Singapore Airlines PPS Club Visa Infinite"]),
        GoldenQuery("Card with discounts for booking flights and hotels on tiket.com",
                    ["BCA tiket.com Mastercard"]),
        GoldenQuery("Is there a credit card with a Batman design?",
                    ["BCA Visa Batman"]),
        GoldenQuery("Entry level credit card for daily shopping and paying bills",
                    ["BCA Everyday Card"]),
        // Loans: the KPR cluster is the hardest confusable group in the corpus
        GoldenQuery("I want to buy my first house, which loan should I take?",
                    ["KPR Pembelian"]),
        GoldenQuery("Move my existing home loan from another bank to BCA for a lower rate",
                    ["KPR BCA Take Over"]),
        GoldenQuery("I need a loan to renovate and expand my house",
                    ["KPR Renovasi"]),
        GoldenQuery("I need cash and can use my house as collateral",
                    ["KPR Refinancing"]),
        GoldenQuery("Quick personal loan without any collateral",
                    ["BCA Personal Loan"]),
        GoldenQuery("Financing to buy a new car",
                    ["KKB BCA"]),
        GoldenQuery("Installment loan for a new motorcycle",
                    ["KSM BCA"]),
        // Savings & investments
        GoldenQuery("Savings account for a student just starting to save",
                    ["Tahapan Xpresi"]),
        GoldenQuery("I want to keep US dollars in a bank account",
                    ["BCA Dollar Account"]),
        GoldenQuery("Lock my money for a fixed guaranteed interest rate",
                    ["Deposito Berjangka (Time Deposit)"]),
        GoldenQuery("Low risk investment backed by the government",
                    ["ORI / SBN (Government Bonds)"]),
        // Transfers & payments: BI-FAST vs RTGS vs SWIFT is rank-order sensitive
        GoldenQuery("How do I send money to a bank account in Singapore?",
                    ["SWIFT International Transfer"]),
        GoldenQuery("Cheapest way to instantly transfer money to another Indonesian bank",
                    ["BI-FAST Transfer"]),
        GoldenQuery("I need to transfer five billion rupiah today, a very large amount",
                    ["RTGS Transfer"]),
        // Debit cluster: GPN is local-only, the Mastercard debit works abroad
        GoldenQuery("Debit card I can use for online shopping on international websites",
                    ["BCA Mastercard Debit"]),
        // Indonesian queries — the contextual model is script-level multilingual,
        // the NLEmbedding fallback is English-only; these measure that gap.
        GoldenQuery("Kartu kredit untuk mengumpulkan miles Singapore Airlines",
                    ["BCA Singapore Airlines KrisFlyer Visa Signature",
                     "BCA Singapore Airlines KrisFlyer Visa Infinite",
                     "BCA Singapore Airlines PPS Club Visa Infinite"],
                    language: "id"),
        GoldenQuery("Pinjaman untuk renovasi rumah",
                    ["KPR Renovasi"],
                    language: "id"),
    ]

    /// Out-of-scope queries: nothing in the corpus answers these. Their top-hit
    /// confidence must sit BELOW the positives' — that separation calibrates
    /// `HybridRetriever.minimumConfidence`. ("visa requirements" is a deliberate
    /// hard negative: both words appear all over the corpus.)
    static let negativeSet: [String] = [
        "How do I buy bitcoin and other cryptocurrency?",
        "What will the weather be like in Jakarta tomorrow?",
        "What are the visa requirements for studying in Australia?",
        "Can you write me a poem about cats?",
        "How do I cook beef rendang?",
    ]

    // MARK: - Edge-case set (typos, vague "dummy" queries, code-switching)

    private static let travelCards: Set<String> = [
        "BCA Mastercard World",
        "BCA Singapore Airlines KrisFlyer Visa Signature",
        "BCA Singapore Airlines KrisFlyer Visa Infinite",
        "BCA Singapore Airlines PPS Club Visa Infinite",
    ]
    private static let allCards: Set<String> = travelCards.union([
        "BCA Everyday Card", "BCA Card Platinum", "BCA Visa Batman", "BCA Visa Black",
        "BCA Mastercard Globe", "BCA Mastercard Black", "BCA JCB Black", "BCA UnionPay",
        "BCA tiket.com Mastercard", "BCA Blibli Mastercard", "BCA American Express Platinum",
        "BCA Debit Card (GPN)", "BCA Mastercard Debit", "BCA Gold Debit (Tahapan Gold)",
        "BCA Xpresi Debit Card",
    ])
    private static let allLoans: Set<String> = [
        "KPR Pembelian", "KPR Refinancing", "KPR Renovasi", "KPR BCA Take Over",
        "KKB BCA", "KSM BCA", "BCA Personal Loan", "BCA Secured Personal Loan",
    ]
    private static let savingsProducts: Set<String> = [
        "Tahapan BCA", "Tahapan Xpresi", "Tahapan Gold", "BCA Dollar Account",
        "Deposito Berjangka (Time Deposit)",
    ]
    private static let investments: Set<String> = [
        "ORI / SBN (Government Bonds)", "Deposito Berjangka (Time Deposit)", "Bancassurance BCA",
    ]

    /// Edge cases for the "dummy user": sloppy spelling, one-word queries (ANY
    /// product of the right branch counts — these measure category steering, not
    /// pinpointing), and Indonesian/English code-switching. Evaluated separately
    /// from the core set with looser floors.
    static let edgeSet: [GoldenQuery] = [
        // typos / sloppy input
        GoldenQuery("kredit card for trvel miles", travelCards),
        GoldenQuery("hoem loan to buy a huose", ["KPR Pembelian"]),
        GoldenQuery("motorcyle lone", ["KSM BCA"]),
        // code-switching
        GoldenQuery("mau kartu kredit buat travel ke luar negeri", travelCards, language: "mix"),
        GoldenQuery("transfer uang cepat dan murah antar bank", ["BI-FAST Transfer"], language: "id"),
        // vague one-worders / dummy asks → right branch is a hit
        GoldenQuery("card", allCards),
        GoldenQuery("loan", allLoans),
        GoldenQuery("savings", savingsProducts),
        GoldenQuery("i need money", allLoans),
        GoldenQuery("invest", investments),
    ]

    // MARK: - Corpus construction (mirrors app seeding, minus the LLM extraction)

    /// Condition-trait helper for embedding-dependent tests: prepares the shared
    /// embedder and reports availability, so hosts without NL assets (e.g. fresh
    /// simulators) SKIP those tests instead of failing them.
    @MainActor static func embedderAvailable() async -> Bool {
        await ContextualEmbedder.shared.prepare()
        return ContextualEmbedder.shared.isReady
    }

    static func loadRows(from url: URL) throws -> [RawRow] {
        try JSONDecoder().decode([RawRow].self, from: Data(contentsOf: url))
    }

    /// Builds the eval corpus exactly like app seeding builds documents, except
    /// `id == product name` so golden expectations match directly, and the
    /// embedding text + backend are injectable for A/B runs.
    static func buildCorpus(
        rows: [RawRow],
        tag: String,
        embedText: (RawRow) -> String,
        embed: (String) -> [Double]?
    ) -> [LocalDocument] {
        rows.map { row in
            LocalDocument(
                id: row.name,
                chunk: buildContextualChunk(from: row),
                category: row.category,
                source: "bca-products.json",
                embedding: embed(embedText(row)) ?? [],
                minIncome: 0, annualFee: 0, maxLimit: 0,
                officialLink: row.officialLink ?? "",
                embeddingModel: tag
            )
        }
    }

    // MARK: - Evaluation

    struct QueryOutcome {
        let query: GoldenQuery
        let hits: [RetrievalHit]      // top 5
        let firstExpectedRank: Int?   // 1-based rank of the first expected product
        var topConfidence: Double { hits.first?.confidence ?? 0 }
    }

    struct Report {
        let label: String
        let outcomes: [QueryOutcome]
        let negativeTopConfidences: [Double]
        let meanQueryMillis: Double

        func hitRate(at k: Int) -> Double {
            let hits = outcomes.filter { ($0.firstExpectedRank ?? Int.max) <= k }
            return Double(hits.count) / Double(outcomes.count)
        }

        /// Mean reciprocal rank over the top 5 (missed queries contribute 0).
        var mrr: Double {
            let sum = outcomes.reduce(0.0) { $0 + ($1.firstExpectedRank.map { 1.0 / Double($0) } ?? 0) }
            return sum / Double(outcomes.count)
        }

        var positiveTopConfidences: [Double] { outcomes.map(\.topConfidence) }
    }

    static func evaluate(
        label: String,
        corpus: [LocalDocument],
        weights: HybridRetriever.Weights,
        tag: String,
        queries: [GoldenQuery] = goldenSet,
        embedQuery: (String) -> [Double]?
    ) -> Report {
        let start = Date()

        let outcomes = queries.map { query -> QueryOutcome in
            let hits = Array(
                HybridRetriever.rank(query: query.text, documents: corpus, weights: weights,
                                     activeEmbeddingTag: tag, embedQuery: embedQuery)
                    .prefix(5)
            )
            let rank = hits.firstIndex { query.expected.contains($0.document.id) }.map { $0 + 1 }
            return QueryOutcome(query: query, hits: hits, firstExpectedRank: rank)
        }

        let negatives = negativeSet.map { negative in
            HybridRetriever.rank(query: negative, documents: corpus, weights: weights,
                                 activeEmbeddingTag: tag, embedQuery: embedQuery)
                .first?.confidence ?? 0
        }

        let totalQueries = queries.count + negativeSet.count
        let millis = Date().timeIntervalSince(start) * 1000 / Double(totalQueries)
        return Report(label: label, outcomes: outcomes,
                      negativeTopConfidences: negatives, meanQueryMillis: millis)
    }

    // MARK: - Card display policy (which trailing hits deserve a card?)

    struct CardPolicyReport {
        let label: String
        let precision: Double     // shown cards that are expected products
        let recall: Double        // queries whose expected product is among the cards
        let averageCards: Double
    }

    /// Measures the card policy over a query set: floored top-2 hits, top always
    /// kept, trailing hits kept per (floor, margin). Sweeping margin answers
    /// "when should the second product card be suppressed?" with data.
    static func evaluateCardPolicy(
        label: String,
        corpus: [LocalDocument],
        weights: HybridRetriever.Weights,
        tag: String,
        floor: Double,
        margin: Double,
        queries: [GoldenQuery] = goldenSet,
        embedQuery: (String) -> [Double]?
    ) -> CardPolicyReport {
        var precisions: [Double] = []
        var recalls: [Double] = []
        var counts: [Double] = []

        for query in queries {
            let floored = Array(
                HybridRetriever.rank(query: query.text, documents: corpus, weights: weights,
                                     activeEmbeddingTag: tag, embedQuery: embedQuery)
                    .prefix(2)
            ).filter { $0.confidence >= HybridRetriever.minimumConfidence }

            let shown = HybridRetriever.cardworthyHits(floored, floor: floor, margin: margin)
            guard !shown.isEmpty else {
                precisions.append(0); recalls.append(0); counts.append(0)
                continue
            }
            let names = shown.map(\.document.id)
            let relevant = names.filter { query.expected.contains($0) }
            precisions.append(Double(relevant.count) / Double(names.count))
            recalls.append(relevant.isEmpty ? 0 : 1)
            counts.append(Double(names.count))
        }

        func mean(_ values: [Double]) -> Double {
            values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        }
        return CardPolicyReport(label: label, precision: mean(precisions),
                                recall: mean(recalls), averageCards: mean(counts))
    }

    // MARK: - Formatting

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let position = p * Double(sorted.count - 1)
        let lower = Int(position)
        let upper = min(lower + 1, sorted.count - 1)
        let fraction = position - Double(lower)
        return sorted[lower] * (1 - fraction) + sorted[upper] * fraction
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    static func header() -> String {
        pad("configuration", 46) + "  H@1   H@2   H@3   MRR   pos-p10  neg-max  ms/q"
    }

    static func summaryLine(_ report: Report) -> String {
        pad(report.label, 46) + String(
            format: "  %.2f  %.2f  %.2f  %.2f  %7.2f  %7.2f  %4.0f",
            report.hitRate(at: 1), report.hitRate(at: 2), report.hitRate(at: 3),
            report.mrr,
            percentile(report.positiveTopConfidences, 0.10),
            report.negativeTopConfidences.max() ?? 0,
            report.meanQueryMillis)
    }

    /// Raw signal table used to (re)calibrate the confidence formula and
    /// `HybridRetriever.minimumConfidence`: per query, the top-RRF hit's cosine,
    /// the corpus-mean cosine (anisotropy baseline), their gap, and BM25 evidence.
    static func calibrationDump(
        corpus: [LocalDocument],
        weights: HybridRetriever.Weights,
        tag: String,
        embedQuery: (String) -> [Double]?
    ) -> String {
        func line(_ text: String, positive: Bool) -> String {
            let hits = HybridRetriever.rank(query: text, documents: corpus, weights: weights,
                                            activeEmbeddingTag: tag, embedQuery: embedQuery)
            let cosines = hits.compactMap(\.vectorScore)
            let mean = cosines.isEmpty ? 0 : cosines.reduce(0, +) / Double(cosines.count)
            let top = hits.first
            let topCos = top?.vectorScore ?? 0
            let gap = topCos - mean
            return String(format: "%@ cos %.3f | mean %.3f | gap %+.3f | maxcos %.3f | bm25 %5.2f | conf %.2f | %@",
                          positive ? "POS" : "NEG", topCos, mean, gap, cosines.max() ?? 0,
                          top?.bm25Score ?? 0, top?.confidence ?? 0, text)
        }
        var lines = ["── confidence signals ──"]
        lines.append(contentsOf: goldenSet.map { line($0.text, positive: true) })
        lines.append(contentsOf: negativeSet.map { line($0, positive: false) })
        return lines.joined(separator: "\n")
    }

    /// Per-query breakdown; misses show what outranked the expected product.
    static func details(_ report: Report) -> String {
        var lines: [String] = ["── \(report.label) ──"]
        for outcome in report.outcomes {
            let mark = outcome.firstExpectedRank == 1 ? "✓"
                     : outcome.firstExpectedRank != nil ? "~" : "✗"
            let rank = outcome.firstExpectedRank.map(String.init) ?? "-"
            let flag = outcome.query.language == "id" ? " [id]" : ""
            lines.append(String(format: "%@ rank %@ conf %.2f | %@%@",
                                mark, rank, outcome.topConfidence, outcome.query.text, flag))
            if outcome.firstExpectedRank != 1 {
                let top = outcome.hits.prefix(3)
                    .map { String(format: "%@ (%.2f)", $0.document.id, $0.confidence) }
                    .joined(separator: ", ")
                lines.append("    top: \(top)")
            }
        }
        let negatives = zip(negativeSet, report.negativeTopConfidences)
            .map { String(format: "conf %.2f | %@", $1, $0) }
        lines.append("── negatives (want LOW confidence) ──")
        lines.append(contentsOf: negatives)
        return lines.joined(separator: "\n")
    }
}
