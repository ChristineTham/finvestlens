//
//  TransactionCategorizer.swift
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

/// A transaction (staged or posted) awaiting a category suggestion.
public struct CategorizationItem: Sendable, Identifiable {
    public let id: UUID
    public let payee: String
    public let memo: String
    public let amount: Decimal

    public init(id: UUID = UUID(), payee: String, memo: String = "", amount: Decimal) {
        self.id = id
        self.payee = payee
        self.memo = memo
        self.amount = amount
    }
}

/// Suggests destination accounts for transactions using the on-device model
/// (`FR-AI-02`).
///
/// This is the semantic layer above the existing deterministic ladder
/// (user rules → payee history → keyword heuristics): it reads payee, memo,
/// and sign together and picks from the book's *actual* chart of accounts,
/// so "TRANSPORT FOR NSW TRAVEL" can land in `Expenses:Transport:Public
/// Transport` without a rule ever having been written. Deterministic
/// sources still take precedence at the call site — the model only fills
/// gaps, and every suggestion is reviewed before posting.
@available(macOS 26.0, iOS 26.0, *)
public enum TransactionCategorizer {

    #if canImport(FoundationModels)
    @Generable
    struct ModelSuggestion {
        @Guide(description: "The number of the transaction being categorised, from the input list")
        var number: Int
        @Guide(description: "The chosen category, copied EXACTLY from the category list")
        var category: String
    }

    @Generable
    struct ModelSuggestions {
        @Guide(description: "One suggestion per input transaction, in order")
        var suggestions: [ModelSuggestion]
    }
    #endif

    /// How many transactions to categorise per model request. The candidate
    /// list is repeated in each session, so batches keep the context small.
    static let batchSize = 8

    /// Maximum candidate accounts offered to the model per request.
    static let candidateLimit = 80

    /// Returns suggested account IDs keyed by item ID. Items the model could
    /// not confidently map (or whose answer matched no candidate) are absent.
    public static func suggest(
        items: [CategorizationItem],
        candidates: [CategoryCandidate],
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [UUID: GncGUID] {
        #if canImport(FoundationModels)
        guard case .available = IntelligenceAvailability.current() else {
            if case .unavailable(let reason) = IntelligenceAvailability.current() {
                throw IntelligenceError.unavailable(reason)
            }
            throw IntelligenceError.unavailable("Apple Intelligence is not available.")
        }
        guard !items.isEmpty, !candidates.isEmpty else { return [:] }

        let offered = Array(candidates.prefix(candidateLimit))
        let categoryList = offered.map { "- \($0.fullName)" }.joined(separator: "\n")
        let instructions = """
            You categorise personal finance transactions. Choose the single best \
            category for each transaction from this list (copy the name exactly):

            \(categoryList)

            Negative amounts are spending, positive amounts are income or refunds.
            """

        var result: [UUID: GncGUID] = [:]
        let batches = stride(from: 0, to: items.count, by: batchSize).map {
            Array(items[$0..<min($0 + batchSize, items.count)])
        }
        for (batchIndex, batch) in batches.enumerated() {
            let listing = batch.enumerated().map { index, item in
                let memo = item.memo.isEmpty ? "" : " — \(item.memo)"
                return "\(index + 1). \(item.payee)\(memo) (\(item.amount))"
            }.joined(separator: "\n")

            let session = LanguageModelSession(instructions: instructions)
            do {
                let response = try await session.respond(
                    to: "Categorise these transactions:\n\(listing)",
                    generating: ModelSuggestions.self,
                    options: GenerationOptions(sampling: .greedy)
                )
                for suggestion in response.content.suggestions {
                    let index = suggestion.number - 1
                    guard batch.indices.contains(index),
                          let hit = AccountNameMatcher.match(suggestion.category, in: offered)
                    else { continue }
                    result[batch[index].id] = hit.id
                }
            } catch {
                throw IntelligenceError.wrap(error)
            }
            onProgress?(batchIndex + 1, batches.count)
        }
        return result
        #else
        throw IntelligenceError.unavailable("Apple Intelligence is not available on this platform.")
        #endif
    }
}
