//
//  ImportMatcher.swift
//  FinvestLens — Interchange
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// The result of matching one imported row against the existing book.
public struct MatchResult: Identifiable, Sendable {
    public let id: UUID
    public var staged: StagedTransaction
    /// `true` if this appears to already exist in the target account.
    public var isDuplicate: Bool
    /// Suggested counter-account for the other leg, from payee history.
    public var suggestedAccountID: GncGUID?

    public init(staged: StagedTransaction, isDuplicate: Bool, suggestedAccountID: GncGUID?) {
        self.id = staged.id
        self.staged = staged
        self.isDuplicate = isDuplicate
        self.suggestedAccountID = suggestedAccountID
    }
}

/// Matches imported rows against the target account: flags likely duplicates and
/// suggests a destination account from payee history (`FR-XIO-05`).
///
/// Ports the intent of GnuCash's generic import matcher — duplicate detection by
/// amount/date proximity or reference, and account guessing by how the same
/// payee was categorised before.
public enum ImportMatcher {

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    public static func match(_ staged: [StagedTransaction], into target: Account,
                             book: Book, dayWindow: Int = 4) -> [MatchResult] {
        let targetSplits = book.splits(for: target)
        let calendar = utcCalendar

        // Payee → counter-account frequency, learned from existing history.
        var payeeAccounts: [String: [GncGUID: Int]] = [:]
        for split in targetSplits {
            guard let transaction = split.transaction else { continue }
            let payee = transaction.transactionDescription.lowercased()
            guard !payee.isEmpty else { continue }
            for other in transaction.splits where other !== split {
                if let account = other.account?.guid {
                    payeeAccounts[payee, default: [:]][account, default: 0] += 1
                }
            }
        }

        func suggest(for payee: String) -> GncGUID? {
            let key = payee.lowercased()
            guard !key.isEmpty else { return nil }
            let counts = payeeAccounts[key]
                ?? payeeAccounts.first { key.contains($0.key) || $0.key.contains(key) }?.value
            return counts?.max { $0.value < $1.value }?.key
        }

        func isDuplicate(_ row: StagedTransaction) -> Bool {
            let target = target.commodity.round(row.amount)
            for split in targetSplits {
                guard let transaction = split.transaction else { continue }
                if !row.reference.isEmpty,
                   transaction.number == row.reference
                    || split.action == row.reference
                    || split.memo.contains(row.reference) {
                    return true
                }
                if split.account?.commodity.round(split.quantity) == target {
                    let days = abs(calendar.dateComponents([.day],
                                                           from: transaction.datePosted,
                                                           to: row.date).day ?? .max)
                    if days <= dayWindow { return true }
                }
            }
            return false
        }

        return staged.map { row in
            let hint = row.payee.isEmpty ? row.memo : row.payee
            return MatchResult(staged: row,
                               isDuplicate: isDuplicate(row),
                               suggestedAccountID: suggest(for: hint))
        }
    }
}
