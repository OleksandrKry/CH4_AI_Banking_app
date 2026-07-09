//
//  BankingDecisionTree.swift
//  CH4_AI_Banking_app
//
//  The whiteboard decision tree, verified against bca-products.json (52
//  products, all covered). It is the BACKBONE of the chat: the session
//  instructions embed it so the model can locate the user's need, ask the
//  branch's basic qualifying question conversationally (one per turn — there is
//  no pre-chat quiz), and only then call the catalog tool for the leaf products.
//
//  Whiteboard scope decisions: personal banking only — business services and
//  student loans are explicitly out of scope. Income qualifier for cards:
//  entry credit cards from IDR 3M/month; ~IDR 10M/month is the whiteboard's
//  line between entry-level and premium tiers / higher credit lines.
//

import FoundationModels

/// The intent categories the AI classifier chooses from — the decision tree's
/// branches. Raw values overlap the corpus vocabulary ("loan"/"account"/"card"
/// substrings) so `CategoryStyle` badges keep working. Constrained decoding
/// guarantees the classifier always returns one of these.
@Generable
enum IntentCategory: String, CaseIterable {
    case creditCard = "Credit Card"
    case debitCard = "Debit Card"
    case savingsAccount = "Savings Account"
    case investment = "Investment"
    case housingLoan = "Housing Loan"
    case vehicleLoan = "Vehicle Loan"
    case personalLoan = "Personal Loan"
    case transfersAndPayments = "Transfers & Payments"
    case digitalServices = "Digital Services"
    case general = "General"
}

enum BankingDecisionTree {

    /// Embedded once per session in the instructions (see RAGSystem).
    static let instructionsBlock = """
    DECISION TREE — the backbone for every recommendation. Locate the user's need in \
    this tree. If the branch is ambiguous, ask exactly ONE short qualifying question \
    (offer 2-3 brief options) per turn before recommending. Once a leaf is clear, call \
    searchProductCatalog with the qualified need.

    1. CARDS — qualify: spend your own money (debit) or on a credit line (credit)?
       - Debit — qualify: local-only or online/international use?
         local ATM/QRIS -> BCA Debit Card (GPN); online/abroad -> BCA Mastercard Debit;
         student/custom design -> BCA Xpresi Debit Card; high balance/priority -> BCA Gold Debit (Tahapan Gold).
       - Credit — qualify: monthly income (entry cards from IDR 3M/month; under about IDR 10M \
    stay entry-level, above it premium tiers and higher credit lines) and the main use.
         everyday -> BCA Everyday Card, BCA Visa Batman, BCA Mastercard Globe, BCA UnionPay (Asia/China);
         travel & miles -> BCA Mastercard World, BCA Singapore Airlines KrisFlyer Visa Signature / Visa Infinite / PPS Club Visa Infinite, BCA JCB Black (Japan);
         online shopping -> BCA tiket.com Mastercard (travel bookings), BCA Blibli Mastercard;
         premium -> BCA Card Platinum, BCA Visa Black, BCA Mastercard Black, BCA American Express Platinum (invitation only).

    2. ACCOUNTS — qualify: everyday account, growing your money, or foreign currency?
       - everyday saving/checking -> Tahapan BCA; student/youth -> Tahapan Xpresi; premium/priority -> Tahapan Gold.
       - locked + interest / investing — qualify: can the money stay locked, and how much risk?
         fixed & guaranteed -> Deposito Berjangka (Time Deposit); low-risk government-backed -> ORI / SBN (Government Bonds);
         managed & diversified -> Reksa Dana BCA (Mutual Funds); protection + investment -> Bancassurance BCA.
       - foreign currency (USD/SGD) -> BCA Dollar Account.

    3. LOANS — qualify: for a vehicle, a home, or cash?
       - vehicle -> car: KKB BCA; motorcycle: KSM BCA.
       - home (KPR) — qualify: buying, renovating, moving an existing mortgage, or cash against your house?
         buy -> KPR Pembelian; renovate -> KPR Renovasi; move from another bank -> KPR BCA Take Over;
         cash with house as collateral -> KPR Refinancing.
       - cash — qualify: any collateral? none -> BCA Personal Loan; investments as collateral -> BCA Secured Personal Loan.

    4. EVERYDAY SERVICES — informational, answer directly without qualifying.
       transfers: BI-FAST (instant, cheap), RTGS (large amounts, same day), SWIFT International Transfer, Virtual Account Payment;
       payments: QRIS Payment, QRIS Scanner, Bill Payment (PLN/Telco/Internet), Top-Up E-Wallet, Cash Withdrawal (ATM network);
       digital: myBCA, BCA Mobile, KlikBCA, BCA Mobile Authentication, Card Control (block/unblock), Limit Management, e-Statement, Push Notifications.

    Only PERSONAL banking is offered: no business services and no student loans — if asked, say so politely.
    """
}
