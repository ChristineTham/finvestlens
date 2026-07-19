//
//  StatementExtractor.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensInterchange
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Extracts transactions from PDF bank/card statements using the on-device
/// model (`FR-AI-01`).
///
/// PDFs have no machine-readable transaction structure, so this is where a
/// language model earns its keep: each page of extracted text becomes one
/// guided-generation request (the on-device context window is small, and
/// statements are naturally page-structured), and the typed results merge
/// into the same ``StagedTransaction`` rows the CSV/QIF/OFX importers emit —
/// so matching, rules, and review all work unchanged downstream.
@available(macOS 26.0, iOS 26.0, *)
public enum StatementExtractor {

    #if canImport(FoundationModels)
    @Generable
    struct ModelTransaction {
        @Guide(description: "Transaction date in yyyy-MM-dd format")
        var date: String
        @Guide(description: "Signed amount: negative for money out (withdrawals, purchases, fees, amounts in a Debit column), positive for money in (deposits, salary, refunds, amounts in a Credit column)")
        var amount: String
        @Guide(description: "Merchant or payee name, cleaned up")
        var payee: String
        @Guide(description: "Reference or receipt number if shown, else empty")
        var reference: String
        @Guide(description: "The running balance printed at the end of this row, empty if the statement has no balance column")
        var balanceAfter: String
    }

    @Generable
    struct ModelPage {
        @Guide(description: "Opening or brought-forward balance printed on this page, empty if none")
        var openingBalance: String
        @Guide(description: "Every transaction row on this statement page. Exclude opening/closing balance lines, subtotals, and marketing text.")
        var transactions: [ModelTransaction]
    }
    #endif

    /// Extracts staged transactions from statement pages.
    ///
    /// - Parameter onProgress: called on completion of each page with
    ///   (pagesDone, pageCount) — drive a progress indicator from this.
    public static func extract(
        pages: [DocumentText.Page],
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [StagedTransaction] {
        #if canImport(FoundationModels)
        guard IntelligenceAvailability.current().isAvailable else {
            if case .unavailable(let reason) = IntelligenceAvailability.current() {
                throw IntelligenceError.unavailable(reason)
            }
            throw IntelligenceError.unavailable("Apple Intelligence is not available.")
        }

        var staged: [StagedTransaction] = []
        var seen = Set<String>()
        // Running balance carried across rows (and pages) for sign correction.
        var previousBalance: Decimal?
        for (index, page) in pages.enumerated() {
            // Fresh session per page: statements easily exceed the on-device
            // context window if accumulated in one transcript.
            let session = LanguageModelSession(instructions: """
                You extract transaction rows from bank and credit card statement text.
                Report amounts exactly as printed, signed from the account holder's \
                perspective: purchases, withdrawals and fees are negative; deposits, \
                salary and refunds are positive. Never invent transactions that are \
                not in the text.
                """)
            do {
                let response = try await session.respond(
                    to: "Statement page:\n\n\(String(page.text.prefix(6000)))",
                    generating: ModelPage.self,
                    options: GenerationOptions(sampling: .greedy)
                )
                if let opening = IntelligenceParsing.amount(response.content.openingBalance) {
                    previousBalance = opening
                }
                for row in response.content.transactions {
                    guard let date = IntelligenceParsing.date(row.date),
                          var amount = IntelligenceParsing.amount(row.amount),
                          amount != 0
                    else { continue }
                    // The model can't reliably tell Debit from Credit columns in
                    // flattened PDF text, so when the statement shows a running
                    // balance the sign is fixed deterministically: the balance
                    // falls after money out and rises after money in.
                    let balance = IntelligenceParsing.amount(row.balanceAfter)
                    if let previous = previousBalance, let balance {
                        let magnitude = abs(amount)
                        if previous - magnitude == balance {
                            amount = -magnitude
                        } else if previous + magnitude == balance {
                            amount = magnitude
                        }
                    }
                    if let balance { previousBalance = balance }
                    // Dedupe across pages (carried-over rows, repeated headers).
                    // Include the running balance and reference so two genuinely
                    // distinct same-day/amount/payee rows (e.g. two identical
                    // coffees) aren't collapsed — only a truly repeated row, which
                    // shares its balance and reference too, is dropped.
                    let key = "\(row.date)|\(abs(amount))|\(row.payee.lowercased())|\(row.reference)|\(row.balanceAfter)"
                    guard seen.insert(key).inserted else { continue }
                    staged.append(StagedTransaction(
                        date: date,
                        amount: amount,
                        payee: row.payee,
                        reference: row.reference
                    ))
                }
            } catch {
                throw IntelligenceError.wrap(error)
            }
            onProgress?(index + 1, pages.count)
        }
        return staged.sorted { $0.date < $1.date }
        #else
        throw IntelligenceError.unavailable("Apple Intelligence is not available on this platform.")
        #endif
    }
}
