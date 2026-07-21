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
        public let transactionDescription: String
        public let currencyCode: String
        /// The categorised legs to post (in place of the uncategorised legs).
        public let legs: [PlannedLeg]
        /// The description of the transaction this plan was learned from.
        public let templateDescription: String
        /// How closely the descriptions matched (0…1), for surfacing confidence.
        public let confidence: Double

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

        // Index every categorised transaction by the accounts it touches, so a
        // target only scores against transactions sharing its (bank) account —
        // both a strong signal and a big reduction in comparisons.
        var templates: [Template] = []
        var byAccount: [GncGUID: [Int]] = [:]
        for transaction in book.transactions where Self.isTemplate(transaction) {
            let index = templates.count
            let tokens = Self.significantTokens(transaction.transactionDescription)
            guard !tokens.isEmpty else { continue }
            templates.append(Template(transaction: transaction, tokens: tokens))
            for split in transaction.splits {
                if let id = split.account?.guid { byAccount[id, default: []].append(index) }
            }
        }
        guard !templates.isEmpty else { return [:] }

        var plans: [GncGUID: CategoryPlan] = [:]
        for target in targets {
            if let plan = bestPlan(for: target, templates: templates, byAccount: byAccount, book: book) {
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

    private struct Template {
        let transaction: Transaction
        let tokens: Set<String>
    }

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

    private func bestPlan(for target: Transaction, templates: [Template],
                          byAccount: [GncGUID: [Int]], book: Book) -> CategoryPlan? {
        // The target's real (anchor) legs — usually the single bank/asset leg —
        // and the value they net to. The uncategorised legs will be replaced.
        let anchorSplits = target.splits.filter { !($0.account?.isImbalanceOrOrphan ?? true) }
        let anchorAccounts = Set(anchorSplits.compactMap { $0.account?.guid })
        let anchorValue = anchorSplits.reduce(Decimal(0)) { $0 + $1.value }
        guard !anchorAccounts.isEmpty, anchorValue != 0 else { return nil }
        // Single-currency only, matching the template requirement.
        guard anchorSplits.allSatisfy({ $0.account?.commodity == target.currency }) else { return nil }

        let targetTokens = Self.significantTokens(target.transactionDescription)
        guard !targetTokens.isEmpty else { return nil }

        // Only templates that share one of the target's anchor accounts.
        var candidateIndices = Set<Int>()
        for account in anchorAccounts { candidateIndices.formUnion(byAccount[account] ?? []) }

        var best: (template: Template, score: Double)?
        for index in candidateIndices {
            let template = templates[index]
            guard template.transaction !== target else { continue }
            guard template.transaction.currency == target.currency else { continue }
            let score = Self.overlap(targetTokens, template.tokens)
            guard score >= 0.67 else { continue }
            if best == nil || score > best!.score
                || (score == best!.score && template.transaction.datePosted > best!.template.transaction.datePosted) {
                best = (template, score)
            }
        }
        guard let match = best else { return nil }
        return buildPlan(for: target, from: match.template.transaction,
                         anchorAccounts: anchorAccounts, anchorValue: anchorValue,
                         confidence: match.score, book: book)
    }

    private func buildPlan(for target: Transaction, from template: Transaction,
                           anchorAccounts: Set<GncGUID>, anchorValue: Decimal,
                           confidence: Double, book: Book) -> CategoryPlan? {
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

        return CategoryPlan(
            transactionID: target.guid, date: target.datePosted,
            transactionDescription: target.transactionDescription,
            currencyCode: currency.mnemonic, legs: legs,
            templateDescription: template.transactionDescription, confidence: confidence)
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
            token.count >= 2 && !token.allSatisfy(\.isNumber) && !Self.fillerTokens.contains(token)
        })
    }

    /// Overlap coefficient: shared tokens over the smaller set. Tolerant of one
    /// description carrying extra words the other lacks (e.g. a branch or city).
    static func overlap(_ a: Set<String>, _ b: Set<String>) -> Double {
        let shared = a.intersection(b).count
        guard shared > 0 else { return 0 }
        return Double(shared) / Double(min(a.count, b.count))
    }

    private static let fillerTokens: Set<String> = [
        "the", "and", "pty", "ltd", "inc", "llc", "payment", "pmt", "to", "from",
        "for", "ref", "eftpos", "visa", "purchase", "card", "debit", "credit",
    ]
}
