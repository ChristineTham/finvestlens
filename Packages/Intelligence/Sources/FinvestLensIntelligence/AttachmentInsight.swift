//
//  AttachmentInsight.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Reads an attachment's extracted text and answers two things at once for its
/// transaction: the best category from the book's chart, and a short friendly
/// payee ("Sydney Water") to replace the raw bank narrative — the same
/// convention the smart categoriser learns from hand-categorised transactions
/// (`FR-AI-02`/`FR-AI-08`).
@available(macOS 26.0, iOS 26.0, *)
public enum AttachmentInsight {

    public struct Insight: Sendable {
        public let accountID: GncGUID
        public let friendlyDescription: String
    }

    #if canImport(FoundationModels)
    @Generable
    struct ModelAnswer {
        @Guide(description: "The chosen category, copied EXACTLY from the category list")
        var category: String
        @Guide(description: "A short friendly payee for the transaction — the merchant or counterparty the document names, e.g. 'Sydney Water'. At most five words; no reference numbers or dates.")
        var payee: String
    }
    #endif

    /// One transaction, one document. Returns `nil` when the model's category
    /// matches nothing in the chart.
    public static func analyze(
        documentText: String,
        currentDescription: String,
        amount: Decimal,
        candidates: [CategoryCandidate]
    ) async throws -> Insight? {
        #if canImport(FoundationModels)
        guard case .available = IntelligenceAvailability.current() else {
            if case .unavailable(let reason) = IntelligenceAvailability.current() {
                throw IntelligenceError.unavailable(reason)
            }
            throw IntelligenceError.unavailable("Apple Intelligence is not available.")
        }
        guard !candidates.isEmpty else { return nil }

        let offered = Array(candidates.prefix(80))
        let categoryList = offered.map { "- \($0.fullName)" }.joined(separator: "\n")
        let instructions = """
            You categorise a personal finance transaction using the document \
            attached to it (a receipt, invoice or statement). Choose the single \
            best category from this list (copy the name exactly):

            \(categoryList)

            Also give a short friendly payee name for the transaction — the \
            merchant or counterparty the document names, not the bank's raw \
            narrative. Negative amounts are spending, positive amounts are \
            income or refunds.
            """
        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(
                to: """
                    Transaction: \(currentDescription) (\(amount))
                    Document text:
                    \(documentText)
                    """,
                generating: ModelAnswer.self,
                options: GenerationOptions(sampling: .greedy)
            )
            guard let hit = AccountNameMatcher.match(response.content.category, in: offered) else {
                return nil
            }
            let payee = response.content.payee.trimmingCharacters(in: .whitespaces)
            return Insight(accountID: hit.id, friendlyDescription: payee)
        } catch {
            throw IntelligenceError.wrap(error)
        }
        #else
        throw IntelligenceError.unavailable("Apple Intelligence is not available on this platform.")
        #endif
    }
}
