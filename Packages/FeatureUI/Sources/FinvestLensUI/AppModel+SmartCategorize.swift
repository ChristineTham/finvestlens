//
//  AppModel+SmartCategorize.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Rule-based auto-categorisation: reuse the categorisation of an existing,
//  very similar transaction — including its full split structure. This is what
//  makes recurring salary and dividend payments (usually split across gross
//  income, tax, super, franking credits, …) categorise correctly without the
//  on-device model, which only ever proposes a single category.
//

import Foundation
import FinvestLensEngine

@MainActor
extension AppModel {

    /// A proposed categorisation for one uncategorised transaction, copied from a
    /// similar existing transaction. Replaces the transaction's Imbalance/Orphan
    /// leg(s) with `legs`, scaled so the whole transaction still balances.
    public struct CategoryPlan: Sendable, Identifiable {
        public var id: GncGUID { transactionID }
        public let transactionID: GncGUID
        public let date: Date
        /// The transaction's current description (usually the raw bank narrative).
        public let transactionDescription: String
        public let currencyCode: String
        /// The categorised legs to post (in place of the uncategorised legs).
        public let legs: [PlannedLeg]
        /// The description of the transaction this plan was learned from.
        public let templateDescription: String
        /// How closely the descriptions matched (0…1), for surfacing confidence.
        public let confidence: Double
        /// The friendly description to rename the transaction to (the template's),
        /// when the template is a cleaner label than the raw narrative. `nil`
        /// leaves the description untouched.
        public let newDescription: String?
        /// The anchor (bank) legs whose memo should receive the raw narrative when
        /// renaming, so the imported detail is preserved rather than lost.
        public let anchorSplitIDs: [GncGUID]

        /// What the transaction will read as after applying: the friendly rename
        /// if any, else its current description.
        public var displayDescription: String { newDescription ?? transactionDescription }

        public struct PlannedLeg: Sendable, Identifiable {
            public let id = UUID()
            public let accountID: GncGUID
            public let accountName: String
            public let value: Decimal
            public let memo: String
        }
    }

    /// For each uncategorised transaction among `items`, finds the most similar
    /// fully-categorised transaction and, if the match is confident, returns a
    /// plan that reproduces its split structure (scaled to this transaction's
    /// amount). Keyed by transaction GUID. Transactions with no confident match
    /// are absent — those fall through to the on-device model or manual choice.
    public func smartCategoryPlans(for items: [UncategorizedItem]) -> [GncGUID: CategoryPlan] {
        guard let book else { return [:] }

        // The transactions needing a home, de-duplicated (an item is per split).
        let targetIDs = Set(items.map(\.transactionID))
        let targets = targetIDs.compactMap { book.transaction(with: $0) }
        guard !targets.isEmpty else { return [:] }

        // Build a per-account corpus of "how this payee was categorised before".
        // Each money leg of a categorised transaction contributes an entry under
        // its account, tokenised from its memo — where the original bank/card
        // narrative is preserved — so a raw import can be matched raw-to-raw
        // rather than against the friendly label (which often shares no words with
        // it, e.g. "Digidirect" ← "…PAYPAL AUSTRALIA…"). Within an account we also
        // count how many entries each token appears in, to weight a distinctive
        // token (a payee name) far above a ubiquitous one ("direct", "australia").
        var corpus: [GncGUID: AccountCorpus] = [:]
        for transaction in book.transactions where Self.isTemplate(transaction) {
            for split in transaction.splits {
                guard let account = split.account, Self.isMoneyAnchor(account.type) else { continue }
                let raw = split.memo.isEmpty ? transaction.transactionDescription : split.memo
                let tokens = Self.significantTokens(raw)
                guard !tokens.isEmpty else { continue }
                corpus[account.guid, default: AccountCorpus()].add(Entry(
                    transaction: transaction, rawTokens: tokens,
                    friendly: transaction.transactionDescription,
                    cleaned: !split.memo.isEmpty && split.memo != transaction.transactionDescription))
            }
        }
        guard !corpus.isEmpty else { return [:] }

        var plans: [GncGUID: CategoryPlan] = [:]
        for target in targets {
            if let plan = bestPlan(for: target, corpus: corpus, book: book) {
                plans[target.guid] = plan
            }
        }
        return plans
    }

    /// Applies accepted plans and single-account assignments as one undoable edit.
    /// Plans replace a transaction's uncategorised legs with categorised ones;
    /// assignments simply move a single leg. A split belonging to a planned
    /// transaction is skipped by the assignment pass so the two never collide.
    @discardableResult
    public func applyCategorization(plans: [CategoryPlan],
                                    assignments: [GncGUID: GncGUID]) -> Int {
        guard let book else { return 0 }
        let plannedTxns = Set(plans.map(\.transactionID))

        let validPlans = plans.filter { book.transaction(with: $0.transactionID) != nil }
        let moves = assignments.compactMap { splitID, accountID -> (split: Split, account: Account)? in
            guard let split = book.split(with: splitID),
                  let account = book.account(with: accountID),
                  let txn = split.transaction, !plannedTxns.contains(txn.guid)
            else { return nil }
            return (split, account)
        }

        var touched = Set<GncGUID>()
        for plan in validPlans { touched.insert(plan.transactionID) }
        for move in moves { if let id = move.split.transaction?.guid { touched.insert(id) } }
        guard !touched.isEmpty else { return 0 }

        var applied = 0
        editing(Array(touched), named: "Categorise Transactions") {
            for plan in validPlans {
                guard let txn = book.transaction(with: plan.transactionID) else { continue }
                // Rename to the friendly description, moving the raw narrative into
                // the bank leg's memo (only when that memo is empty, so nothing the
                // user typed is overwritten).
                if let friendly = plan.newDescription, friendly != txn.transactionDescription {
                    let narrative = txn.transactionDescription
                    for id in plan.anchorSplitIDs {
                        guard let split = book.split(with: id),
                              split.memo.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                        split.memo = narrative
                    }
                    txn.transactionDescription = friendly
                }
                for split in txn.splits where split.account?.isImbalanceOrOrphan ?? false {
                    txn.removeSplit(split)
                }
                for leg in plan.legs {
                    guard let account = book.account(with: leg.accountID) else { continue }
                    txn.addSplit(account: account, value: leg.value, memo: leg.memo)
                }
                applied += 1
            }
            for move in moves { move.split.account = move.account; applied += 1 }
        }
        return applied
    }

    // MARK: - Matching internals

    /// One learned example: a categorised transaction seen through the money leg
    /// posted to a particular account.
    private struct Entry {
        let transaction: Transaction
        /// Tokens of the raw narrative (the money-leg memo, or the description
        /// when there is no memo yet).
        let rawTokens: Set<String>
        /// The transaction's description — the friendly label to adopt.
        let friendly: String
        /// Whether this example carries a distinct raw narrative in its memo, i.e.
        /// the label really is a cleaned-up rename (so adopting it is meaningful).
        let cleaned: Bool
    }

    /// Every learned example for one account, with token document-frequencies for
    /// weighting distinctive tokens over ubiquitous ones.
    private struct AccountCorpus {
        var entries: [Entry] = []
        var documentFrequency: [String: Int] = [:]

        mutating func add(_ entry: Entry) {
            entries.append(entry)
            for token in entry.rawTokens { documentFrequency[token, default: 0] += 1 }
        }

        /// Inverse document frequency: ~0 for a token in most entries, larger for
        /// a rare, distinctive one.
        func idf(_ token: String) -> Double {
            let df = documentFrequency[token] ?? 0
            return max(0, log(Double(entries.count + 1) / Double(df + 1)))
        }
    }

    /// A balance-sheet account a register is opened on — the kind that carries the
    /// bank/card narrative — as opposed to an income/expense category.
    private static func isMoneyAnchor(_ type: AccountType) -> Bool {
        switch type {
        case .bank, .cash, .credit, .asset, .liability, .receivable, .payable, .stock, .mutualFund:
            return true
        case .income, .expense, .equity, .trading, .root:
            return false
        }
    }

    /// A match must clear this share of a template's distinctive content…
    private static let scoreThreshold = 0.6
    /// …and win by this factor over the next distinct payee, or it is ambiguous…
    private static let ambiguityMargin = 1.25
    /// …and be carried by at least one token this distinctive (roughly: present in
    /// under ~60% of the account's entries)…
    private static let distinctiveIdf = 0.5
    /// …with the shared tokens carrying at least this much total weight, so a lone
    /// weak token can't anchor a match.
    private static let minSharedWeight = 1.0

    /// A candidate to learn from: balanced, at least two legs, every leg posting
    /// to a real (non-Imbalance/Orphan) account, and single-currency throughout
    /// so scaling a value scales its quantity 1:1.
    private static func isTemplate(_ transaction: Transaction) -> Bool {
        guard transaction.splits.count >= 2, transaction.isBalanced else { return false }
        for split in transaction.splits {
            guard let account = split.account, !account.isImbalanceOrOrphan else { return false }
            if account.commodity != transaction.currency { return false }
        }
        return true
    }

    private func bestPlan(for target: Transaction, corpus: [GncGUID: AccountCorpus],
                          book: Book) -> CategoryPlan? {
        // The target's real (anchor) legs — usually the single bank/card leg — and
        // the value they net to. The uncategorised legs will be replaced.
        let anchorSplits = target.splits.filter { !($0.account?.isImbalanceOrOrphan ?? true) }
        let anchorAccounts = Set(anchorSplits.compactMap { $0.account?.guid })
        let anchorValue = anchorSplits.reduce(Decimal(0)) { $0 + $1.value }
        guard !anchorAccounts.isEmpty, anchorValue != 0 else { return nil }
        // Single-currency only, matching the template requirement.
        guard anchorSplits.allSatisfy({ $0.account?.commodity == target.currency }) else { return nil }

        // The target's raw text: its description plus any narrative already sitting
        // in its own money-leg memos.
        var targetTokens = Self.significantTokens(target.transactionDescription)
        for split in anchorSplits { targetTokens.formUnion(Self.significantTokens(split.memo)) }
        guard !targetTokens.isEmpty else { return nil }

        // Score every learned example in the target's anchor account(s): the share
        // of that example's distinctive (idf-weighted) content the target covers.
        // A match must be carried by at least one distinctive token, never by
        // ubiquitous ones alone.
        var scored: [(entry: Entry, score: Double)] = []
        for accountID in anchorAccounts {
            guard let account = corpus[accountID] else { continue }
            for entry in account.entries where entry.transaction !== target {
                guard entry.transaction.currency == target.currency else { continue }
                let shared = targetTokens.intersection(entry.rawTokens)
                guard shared.contains(where: { account.idf($0) >= Self.distinctiveIdf }) else { continue }
                let sharedWeight = shared.reduce(0.0) { $0 + account.idf($1) }
                // An absolute floor as well as the ratio: a single weak shared
                // token (e.g. just "anz") shouldn't carry a match on its own.
                guard sharedWeight >= Self.minSharedWeight else { continue }
                let entryWeight = entry.rawTokens.reduce(0.0) { $0 + account.idf($1) }
                guard entryWeight > 0 else { continue }
                scored.append((entry, sharedWeight / entryWeight))
            }
        }

        // Best score per distinct payee, then the ambiguity guard: only propose
        // when one payee clearly wins. A narrative that fits several payees equally
        // (every PayPal debit reads the same bar the reference) is left to the user.
        var bestByFriendly: [String: (score: Double, entry: Entry)] = [:]
        for item in scored where item.score >= Self.scoreThreshold {
            if let existing = bestByFriendly[item.entry.friendly], existing.score >= item.score { continue }
            bestByFriendly[item.entry.friendly] = (item.score, item.entry)
        }
        let ranked = bestByFriendly.values.sorted { $0.score > $1.score }
        guard let winner = ranked.first else { return nil }
        if ranked.count > 1, ranked[1].score * Self.ambiguityMargin > winner.score { return nil }

        return buildPlan(for: target, from: winner.entry, anchorSplits: anchorSplits,
                         anchorAccounts: anchorAccounts, anchorValue: anchorValue,
                         confidence: winner.score, book: book)
    }

    private func buildPlan(for target: Transaction, from entry: Entry,
                           anchorSplits: [Split], anchorAccounts: Set<GncGUID>,
                           anchorValue: Decimal, confidence: Double, book: Book) -> CategoryPlan? {
        let template = entry.transaction
        let templateAnchor = template.splits.filter { anchorAccounts.contains($0.account?.guid ?? .random()) }
        let templateAnchorValue = templateAnchor.reduce(Decimal(0)) { $0 + $1.value }
        // Scale must be positive: a deposit-shaped template shouldn't categorise
        // a withdrawal-shaped transaction (and vice versa).
        guard templateAnchorValue != 0, (templateAnchorValue > 0) == (anchorValue > 0) else { return nil }
        let scale = anchorValue / templateAnchorValue

        let categoryLegs = template.splits.filter { !anchorAccounts.contains($0.account?.guid ?? .random()) }
        guard !categoryLegs.isEmpty else { return nil }

        let currency = target.currency
        var legs: [CategoryPlan.PlannedLeg] = categoryLegs.compactMap { split in
            guard let account = split.account else { return nil }
            return CategoryPlan.PlannedLeg(
                accountID: account.guid, accountName: account.fullName,
                value: currency.round(split.value * scale), memo: split.memo)
        }
        guard legs.count == categoryLegs.count, !legs.isEmpty else { return nil }

        // The categorised legs must net to -anchorValue for the transaction to
        // balance; rounding leaves a residual, which the largest leg absorbs.
        let plannedSum = legs.reduce(Decimal(0)) { $0 + $1.value }
        let residual = -anchorValue - plannedSum
        if residual != 0, let biggest = legs.indices.max(by: { abs(legs[$0].value) < abs(legs[$1].value) }) {
            let leg = legs[biggest]
            legs[biggest] = CategoryPlan.PlannedLeg(accountID: leg.accountID, accountName: leg.accountName,
                                                    value: leg.value + residual, memo: leg.memo)
        }

        // Adopt the learned friendly label when this example is a genuine rename
        // (its raw narrative lives in the money-leg memo, distinct from the label).
        // The target's own raw narrative is then preserved in its money-leg memo
        // rather than discarded, matching how the user hand-categorises these.
        let friendly = entry.friendly.trimmingCharacters(in: .whitespaces)
        let newDescription: String? = (entry.cleaned && !friendly.isEmpty
                                        && friendly != target.transactionDescription) ? friendly : nil

        return CategoryPlan(
            transactionID: target.guid, date: target.datePosted,
            transactionDescription: target.transactionDescription,
            currencyCode: currency.mnemonic, legs: legs,
            templateDescription: entry.friendly, confidence: confidence,
            newDescription: newDescription, anchorSplitIDs: anchorSplits.map(\.guid))
    }

    // MARK: - Description similarity

    /// Alphabetic tokens worth matching on: lowercased, punctuation-split, with
    /// pure numbers (reference/date noise) and common filler dropped.
    static func significantTokens(_ text: String) -> Set<String> {
        let scalars = text.lowercased().unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : " "
        }
        let tokens = String(scalars).split(separator: " ").map(String.init)
        return Set(tokens.filter { token in
            token.count >= 2 && !token.allSatisfy(\.isNumber)
                && !Self.fillerTokens.contains(token) && !Self.isDateToken(token)
        })
    }

    /// A month abbreviation, optionally with a trailing year (`jan`, `jan23`,
    /// `apr2023`). These sit in statement narratives ("VAP DST JAN23") and would
    /// otherwise let same-month payments of different securities cross-match.
    private static func isDateToken(_ token: String) -> Bool {
        guard token.count >= 3, Self.monthPrefixes.contains(String(token.prefix(3))) else { return false }
        return token.dropFirst(3).allSatisfy(\.isNumber)
    }

    private static let monthPrefixes: Set<String> = [
        "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
    ]

    // Only structural stopwords: idf already drives down domain-ubiquitous words
    // ("direct", "debit", "visa", "australia") per account, and an over-eager
    // filler list collapses narratives like "ANZ CREDIT CARD" to a single token.
    private static let fillerTokens: Set<String> = ["the", "and", "to", "from", "for", "of", "at"]
}
