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
    /// The existing split in the target account this row matched, when
    /// `isDuplicate` — lets reconciliation mark that split cleared instead
    /// of merely skipping the row.
    public var matchedSplitID: GncGUID?
    /// Suggested counter-account for the other leg, from payee history.
    public var suggestedAccountID: GncGUID?
    /// When set, this row is the missing side of a **cross-account transfer**:
    /// another account's statement already created the transaction, with this
    /// side still posted to a wash account (Imbalance/Unspecified). This is
    /// that wash split — import re-points it at the target account instead of
    /// posting a mirror-image duplicate. `suggestedAccountID` then names the
    /// account on the other side.
    public var transferSplitID: GncGUID?

    public init(staged: StagedTransaction, isDuplicate: Bool,
                matchedSplitID: GncGUID? = nil, suggestedAccountID: GncGUID?,
                transferSplitID: GncGUID? = nil) {
        self.id = staged.id
        self.staged = staged
        self.isDuplicate = isDuplicate
        self.matchedSplitID = matchedSplitID
        self.suggestedAccountID = suggestedAccountID
        self.transferSplitID = transferSplitID
    }
}

/// Matches imported rows against the target account: flags likely duplicates and
/// suggests a destination account from payee history (`FR-XIO-05`).
///
/// Ports the intent of GnuCash's generic import matcher — duplicate detection by
/// amount/date proximity or reference, and account guessing by how the same
/// payee was categorised before — and goes one step further on transfers
/// between the user's own accounts: when the other account's statement was
/// imported first, this side's row completes that transaction rather than
/// duplicating it.
public enum ImportMatcher {

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    /// A wash account — a posting that still needs a real home. GnuCash's own
    /// `Imbalance-*`/`Orphan-*`, plus the placeholder names books accumulate
    /// from years of hand-imports.
    public static func isWash(_ account: Account) -> Bool {
        if account.isImbalanceOrOrphan { return true }
        let name = account.name.trimmingCharacters(in: .whitespaces).lowercased()
        return name == "unspecified" || name == "uncategorised"
            || name == "uncategorized" || name == "unknown"
    }

    /// An account that can be the other side of a cash transfer — a real
    /// balance-sheet account statements are drawn on.
    private static func isTransferSide(_ type: AccountType) -> Bool {
        switch type {
        case .bank, .cash, .credit, .asset, .liability: return true
        default: return false
        }
    }

    /// An account a credit-card payment is funded from.
    private static func isFundingSource(_ type: AccountType) -> Bool {
        switch type {
        case .bank, .cash, .asset: return true
        default: return false
        }
    }

    /// One healable transfer counterpart: an existing transaction with a leg of
    /// the opposite amount in another real account, whose remaining side still
    /// sits in a wash account.
    private struct TransferCandidate {
        let otherAccount: Account
        let washSplit: Split
        let transaction: Transaction
        /// Narrative tokens (description + leg memos) for the agreement gate.
        let tokens: Set<String>
    }

    /// Words worth matching between the two sides of a suspected transfer.
    static func narrativeTokens(_ text: String) -> Set<String> {
        let mapped = text.lowercased().unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : " "
        }
        let filler: Set<String> = ["the", "and", "to", "from", "for", "of", "at"]
        return Set(String(mapped).split(separator: " ").map(String.init).filter {
            $0.count >= 2 && !$0.allSatisfy(\.isNumber) && !filler.contains($0)
        })
    }

    /// Whether the two sides of a suspected transfer tell the same story.
    /// Equal amount + close dates alone can coincide (a card refund against an
    /// unrelated bank debit in the same week); AU banks put the counterparty or
    /// entity name in both narratives ("To/From Cwk … Smsf Pty Ltd"), so a real
    /// pair shares words. Require two shared tokens — or full containment of
    /// one side when it has fewer than two to give.
    static func narrativesAgree(_ lhs: Set<String>, _ rhs: Set<String>) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        let shared = lhs.intersection(rhs)
        if shared.count >= 2 { return true }
        return !shared.isEmpty && (lhs.isSubset(of: rhs) || rhs.isSubset(of: lhs))
    }

    public static func match(_ staged: [StagedTransaction], into target: Account,
                             book: Book, dayWindow: Int = 4) -> [MatchResult] {
        let targetSplits = book.splits(for: target)
        let calendar = utcCalendar

        // Payee → counter-account frequency, learned from existing history.
        // Keyed on the description *and* the target-leg memo: once a
        // transaction is renamed to a friendly label, the raw bank narrative
        // lives on in the money leg's memo, and the next import of the same
        // payee must still find it (raw-to-raw, as the smart categoriser does).
        var payeeAccounts: [String: [GncGUID: Int]] = [:]
        for split in targetSplits {
            guard let transaction = split.transaction else { continue }
            var keys = [transaction.transactionDescription.lowercased()]
            let memo = split.memo.lowercased()
            if !memo.isEmpty, memo != keys[0] { keys.append(memo) }
            for key in keys where !key.isEmpty {
                for other in transaction.splits where other !== split {
                    if let account = other.account?.guid {
                        payeeAccounts[key, default: [:]][account, default: 0] += 1
                    }
                }
            }
        }

        func bestAccount(_ counts: [GncGUID: Int]?) -> GncGUID? {
            counts?.max { lhs, rhs in
                lhs.value == rhs.value ? lhs.key.description > rhs.key.description
                                       : lhs.value < rhs.value
            }?.key
        }

        func suggest(for payee: String) -> GncGUID? {
            let key = payee.lowercased()
            guard !key.isEmpty else { return nil }
            if let exact = payeeAccounts[key] { return bestAccount(exact) }
            // Substring fallback: among history payees that contain (or are
            // contained by) this one, take the most frequent, deterministically.
            let candidates = payeeAccounts.filter { key.contains($0.key) || $0.key.contains(key) }
            let best = candidates.max { lhs, rhs in
                let lhsTotal = lhs.value.values.reduce(0, +)
                let rhsTotal = rhs.value.values.reduce(0, +)
                return lhsTotal == rhsTotal ? lhs.key > rhs.key : lhsTotal < rhsTotal
            }
            return bestAccount(best?.value)
        }

        // Where this card's payments historically come from: the bank-side
        // account most often opposite recent deposits. A statement's own
        // "PAYMENT - THANK YOU" line names no payee history can match, but the
        // account's history knows its funding account.
        func fundingSuggestion(for row: StagedTransaction) -> GncGUID? {
            guard target.type == .credit, row.amount > 0 else { return nil }
            let text = (row.payee + " " + row.memo).lowercased()
            guard text.contains("payment") || text.contains("thank you") else { return nil }
            guard let windowStart = calendar.date(byAdding: .day, value: -730, to: row.date)
            else { return nil }
            var counts: [GncGUID: Int] = [:]
            var latest: [GncGUID: Date] = [:]
            for split in targetSplits where split.value > 0 {
                guard let transaction = split.transaction,
                      transaction.datePosted >= windowStart else { continue }
                for other in transaction.splits where other !== split {
                    guard let account = other.account, isFundingSource(account.type),
                          !isWash(account) else { continue }
                    counts[account.guid, default: 0] += 1
                    latest[account.guid] = max(latest[account.guid] ?? .distantPast,
                                               transaction.datePosted)
                }
            }
            return counts.max { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                let lhsDate = latest[lhs.key] ?? .distantPast
                let rhsDate = latest[rhs.key] ?? .distantPast
                if lhsDate != rhsDate { return lhsDate < rhsDate }
                return lhs.key.description > rhs.key.description
            }?.key
        }

        // Transfer counterparts: every transaction with exactly one wash leg
        // and a leg in another real balance-sheet account of this currency,
        // indexed by that other leg's value. A staged row of amount X heals
        // the candidate whose other leg is −X (so the wash leg is +X — exactly
        // the leg this statement is reporting).
        var transferCandidates: [Decimal: [TransferCandidate]] = [:]
        for transaction in book.transactions {
            guard transaction.currency == target.commodity else { continue }
            let washSplits = transaction.splits.filter { $0.account.map(isWash) ?? false }
            guard washSplits.count == 1, let wash = washSplits.first else { continue }
            guard !transaction.splits.contains(where: { $0.account === target }) else { continue }
            for split in transaction.splits where split !== wash {
                guard let account = split.account, isTransferSide(account.type),
                      !isWash(account), account !== target,
                      account.commodity == target.commodity else { continue }
                let key = target.commodity.round(split.value)
                var tokens = narrativeTokens(transaction.transactionDescription)
                tokens.formUnion(narrativeTokens(split.memo))
                tokens.formUnion(narrativeTokens(wash.memo))
                transferCandidates[key, default: []].append(
                    TransferCandidate(otherAccount: account, washSplit: wash,
                                      transaction: transaction, tokens: tokens))
            }
        }

        func daysBetween(_ transaction: Transaction, and date: Date) -> Int {
            let dates = [transaction.datePosted, transaction.statementDate].compactMap { $0 }
            return dates.map {
                abs(calendar.dateComponents([.day], from: $0, to: date).day ?? .max)
            }.min() ?? .max
        }

        func transferMatch(_ row: StagedTransaction, excluding claimed: Set<GncGUID>) -> TransferCandidate? {
            let amount = target.commodity.round(row.amount)
            guard amount != 0, let candidates = transferCandidates[-amount] else { return nil }
            let rowTokens = narrativeTokens(row.payee + " " + row.memo)
            return candidates
                .filter { candidate in
                    !claimed.contains(candidate.washSplit.guid)
                        && target.commodity.round(candidate.washSplit.value) == amount
                        && daysBetween(candidate.transaction, and: row.date) <= dayWindow
                        && narrativesAgree(rowTokens, candidate.tokens)
                }
                .min { lhs, rhs in
                    let lhsDays = daysBetween(lhs.transaction, and: row.date)
                    let rhsDays = daysBetween(rhs.transaction, and: row.date)
                    return lhsDays == rhsDays
                        ? lhs.washSplit.guid.description < rhs.washSplit.guid.description
                        : lhsDays < rhsDays
                }
        }

        func duplicateMatch(_ row: StagedTransaction, excluding claimed: Set<GncGUID>) -> Split? {
            let target = target.commodity.round(row.amount)
            for split in targetSplits where !claimed.contains(split.guid) {
                guard let transaction = split.transaction else { continue }
                if !row.reference.isEmpty {
                    // The OFX/HBCI FITID GnuCash records in the split's
                    // `online_id` KVP slot is a definitive duplicate match
                    // (xaccSplitGetOnlineID); check it first.
                    if case let .string(onlineID)? = split.kvp["online_id"],
                       onlineID == row.reference {
                        return split
                    }
                    // Match the reference only against fields that hold it
                    // verbatim. A `memo.contains` substring test would treat a
                    // short cheque number ("202") as a duplicate of any memo that
                    // merely embeds it ("Invoice 20205"), silently dropping a real
                    // transaction; require equality. A genuine re-import is still
                    // caught by the amount + date-window check below.
                    if transaction.number == row.reference
                        || split.action == row.reference
                        || split.memo == row.reference {
                        return split
                    }
                }
                if split.account?.commodity.round(split.quantity) == target {
                    // Definitive negative: both sides carry bank references and
                    // they differ — a bank never re-issues an event under a new
                    // FITID, so equal amount and close dates notwithstanding,
                    // these are different transactions (the boundary-week trap:
                    // a new statement's rows against last statement's entries).
                    if !row.reference.isEmpty,
                       case .string? = split.kvp["online_id"] {
                        continue
                    }
                    // Check the statement date too: when a transaction's
                    // posted date was adjusted to its invoice date, the bank's
                    // date lives in `statementDate` — a re-imported statement
                    // must still recognise it.
                    let dates = [transaction.datePosted, transaction.statementDate].compactMap { $0 }
                    let withinWindow = dates.contains { date in
                        let days = abs(calendar.dateComponents([.day], from: date,
                                                               to: row.date).day ?? .max)
                        return days <= dayWindow
                    }
                    if withinWindow { return split }
                }
            }
            return nil
        }

        /// Whether every leg of the matched split's transaction other than the
        /// split itself sits in a wash account — i.e. the book entry is itself
        /// an unfinished import half, weak evidence that this row is old news.
        func counterLegsAllWash(_ split: Split) -> Bool {
            guard let transaction = split.transaction else { return false }
            let others = transaction.splits.filter { $0 !== split }
            return !others.isEmpty && others.allSatisfy { $0.account.map(isWash) ?? false }
        }

        // Each existing split (or pending wash leg) matches at most one row —
        // four identical statement rows against two book entries must import
        // two new transactions, not vanish (GnuCash's matcher claims one-to-one
        // the same way).
        var claimedSplits = Set<GncGUID>()
        var claimedWash = Set<GncGUID>()

        return staged.map { row in
            let hint = row.payee.isEmpty ? row.memo : row.payee
            let duplicate = duplicateMatch(row, excluding: claimedSplits)
            // Prefer completing a pending transfer over "matching" a book entry
            // that is itself only a wash-parked half: the half proves the amount
            // recurs, not that this row is already recorded.
            if duplicate == nil || counterLegsAllWash(duplicate!),
               let transfer = transferMatch(row, excluding: claimedWash) {
                claimedWash.insert(transfer.washSplit.guid)
                return MatchResult(staged: row, isDuplicate: false,
                                   suggestedAccountID: transfer.otherAccount.guid,
                                   transferSplitID: transfer.washSplit.guid)
            }
            if let duplicate {
                claimedSplits.insert(duplicate.guid)
                return MatchResult(staged: row, isDuplicate: true,
                                   matchedSplitID: duplicate.guid,
                                   suggestedAccountID: suggest(for: hint))
            }
            return MatchResult(staged: row, isDuplicate: false,
                               suggestedAccountID: suggest(for: hint)
                                   ?? fundingSuggestion(for: row))
        }
    }
}
