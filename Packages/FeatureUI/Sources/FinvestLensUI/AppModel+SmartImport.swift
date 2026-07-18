//
//  AppModel+SmartImport.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Smart Import (`FR-AI-07`): classify each dropped PDF, then route it —
//  bank statements reconcile through the import review, dividend statements
//  are verified (and fixed) against the register, invoices split and re-date
//  their matching transaction. All matching is deterministic and
//  date-tolerant: bank-posted dates lag the economic date by a few days, and
//  when a date is corrected the original lives on in
//  ``Transaction/statementDate`` so future statement imports still match.
//

import Foundation
import FinvestLensEngine
import FinvestLensIntelligence

@MainActor
extension AppModel {

    // MARK: Dividend verification (FR-AI-07)

    /// The outcome of checking a dividend statement against the register.
    public struct DividendCheckResult: Sendable {
        public enum Verdict: Sendable, Equatable {
            /// A matching transaction exists and its franking components agree.
            case verified
            /// A matching cash deposit exists but the franking credit
            /// gross-up is missing or wrong — offer to fix.
            case missingFrankingCredits
            /// No transaction matches the payment — offer to record it.
            case noMatch
        }
        public var verdict: Verdict
        public var transactionID: GncGUID?
        public var transactionDescription: String = ""
        public var datePosted: Date?
        /// Franking credits found booked on the matched transaction.
        public var foundFrankingCredits: Decimal = 0
    }

    /// Finds the register transaction for a dividend payment (cash amount
    /// within `dayWindow` days of the payment date) and checks that the
    /// franked components and franking credits have been applied.
    public func checkDividendStatement(
        _ details: DividendStatementDetails,
        dayWindow: Int = 10
    ) -> DividendCheckResult {
        guard let book, details.netPayment != 0 else {
            return DividendCheckResult(verdict: .noMatch)
        }
        let candidates = book.transactions.filter { transaction in
            guard transaction.splits.contains(where: { split in
                (split.account?.type.isAssetLike ?? false)
                    && split.value == details.netPayment
                    && split.reconcileState != .voided
            }) else { return false }
            guard let payDate = details.paymentDate else { return true }
            return daysApart(transaction, from: payDate) <= dayWindow
        }
        // Prefer the transaction that mentions the security, then the closest date.
        let tokens = ([details.ticker] + details.securityName.split(separator: " ").map(String.init))
            .filter { $0.count >= 3 }
        let best = candidates.min { a, b in
            let aNamed = mentionsAny(a, tokens: tokens), bNamed = mentionsAny(b, tokens: tokens)
            if aNamed != bNamed { return aNamed }
            guard let payDate = details.paymentDate else { return true }
            return daysApart(a, from: payDate) < daysApart(b, from: payDate)
        }
        guard let match = best else {
            return DividendCheckResult(verdict: .noMatch)
        }

        // Credits actually booked: the income leg of the gross-up.
        let foundCredits = -match.splits
            .filter {
                $0.account?.type == .income
                    && ($0.account?.name.localizedCaseInsensitiveContains("franking") ?? false)
            }
            .reduce(Decimal(0)) { $0 + $1.value }
        let verified = details.frankingCredits == 0 || foundCredits == details.frankingCredits
        return DividendCheckResult(
            verdict: verified ? .verified : .missingFrankingCredits,
            transactionID: match.guid,
            transactionDescription: match.transactionDescription,
            datePosted: match.datePosted,
            foundFrankingCredits: foundCredits
        )
    }

    /// Rewrites a matched deposit into the full dividend structure —
    /// franked/unfranked components plus the franking-credit gross-up —
    /// keeping the cash split (and its reconcile state) untouched.
    public func applyDividendFix(
        _ details: DividendStatementDetails,
        to transactionID: GncGUID
    ) throws {
        guard let book,
              let transaction = book.transaction(with: transactionID),
              let cash = transaction.splits.first(where: {
                  ($0.account?.type.isAssetLike ?? false) && $0.value == details.netPayment
              })
        else { throw TransactionEntryError.notFound }

        // Whole-book: the dividend legs land on income accounts that may have to
        // be created, so the chart of accounts can change too.
        var imbalance: Decimal?
        editingWholeBook(named: "Apply Dividend Details") {
            for split in transaction.splits where split !== cash {
                transaction.removeSplit(split)
            }
            if details.frankedAmount != 0,
               let account = ensureAccount(path: ["Income", "Dividends", "Franked Dividends"], type: .income) {
                transaction.addSplit(account: account, value: -details.frankedAmount, memo: details.ticker)
            }
            if details.unfrankedAmount != 0,
               let account = ensureAccount(path: ["Income", "Dividends", "Unfranked Dividends"], type: .income) {
                transaction.addSplit(account: account, value: -details.unfrankedAmount, memo: details.ticker)
            }
            if details.frankingCredits != 0,
               let income = ensureAccount(path: ["Income", "Dividends", "Franking Credits"], type: .income),
               let receivable = ensureAccount(path: ["Assets", "Franking Credits Receivable"], type: .asset) {
                transaction.addSplit(account: income, value: -details.frankingCredits, memo: details.ticker)
                transaction.addSplit(account: receivable, value: details.frankingCredits, memo: details.ticker)
            }
            adoptEconomicDate(of: transaction, to: details.paymentDate)
            if !transaction.tags.contains("dividend") {
                transaction.tags.append("dividend")
            }
            if !transaction.isBalanced { imbalance = transaction.imbalance.amount }
        }
        // As before, an unbalanced result is reported after the rewrite — but
        // now the rewrite is on the undo stack, so it can be backed out.
        if let imbalance { throw TransactionEntryError.unbalanced(imbalance) }
    }

    // MARK: Invoice matching (FR-AI-07)

    /// A register transaction that an invoice appears to explain.
    public struct InvoiceMatch: Sendable {
        public let transactionID: GncGUID
        public let transactionDescription: String
        public let datePosted: Date
        public let fundingAccountName: String
        /// Number of non-funding splits currently on the transaction.
        public let counterSplitCount: Int
        /// The invoice date, when adopting it would change the register date.
        public let proposedDate: Date?
    }

    /// Finds the transaction an invoice belongs to: a spend of exactly the
    /// invoice total from an asset or liability account, dated between
    /// `daysBefore` days before the invoice date and `daysAfter` days after
    /// it (banks post late, rarely early). The transaction's statement date
    /// is considered as well as its posted date.
    public func findInvoiceMatch(
        for analysis: InvoiceAnalysis,
        daysBefore: Int = 3,
        daysAfter: Int = 14
    ) -> InvoiceMatch? {
        guard let book, analysis.total > 0 else { return nil }
        let candidates = book.transactions.filter { transaction in
            guard fundingSplit(of: transaction, total: analysis.total) != nil else { return false }
            guard let invoiceDate = analysis.date else { return true }
            let dates = [transaction.datePosted, transaction.statementDate].compactMap { $0 }
            return dates.contains { date in
                let offset = daysBetween(invoiceDate, date)
                return offset >= -daysBefore && offset <= daysAfter
            }
        }
        let best: Transaction?
        if let invoiceDate = analysis.date {
            best = candidates.min {
                daysApart($0, from: invoiceDate) < daysApart($1, from: invoiceDate)
            }
        } else {
            best = candidates.first
        }
        guard let match = best,
              let funding = fundingSplit(of: match, total: analysis.total)
        else { return nil }

        var proposedDate: Date?
        if let invoiceDate = analysis.date, daysBetween(invoiceDate, match.datePosted) != 0 {
            proposedDate = invoiceDate
        }
        return InvoiceMatch(
            transactionID: match.guid,
            transactionDescription: match.transactionDescription,
            datePosted: match.datePosted,
            fundingAccountName: funding.account?.name ?? "",
            counterSplitCount: match.splits.count - 1,
            proposedDate: proposedDate
        )
    }

    /// Replaces the counter-splits of a matched transaction with the
    /// invoice's categorised line items, optionally adopting the invoice
    /// date (the bank's date is preserved in ``Transaction/statementDate``).
    /// The funding split — and its reconcile state — is untouched. Line items
    /// without a category suggestion fall back to the transaction's previous
    /// counter account; any residual against the invoice total is posted
    /// there too, so the transaction always stays balanced.
    public func applyInvoiceSplit(
        _ analysis: InvoiceAnalysis,
        to transactionID: GncGUID,
        adjustDate: Bool = true
    ) throws {
        guard let book,
              let transaction = book.transaction(with: transactionID),
              let funding = fundingSplit(of: transaction, total: analysis.total)
        else { throw TransactionEntryError.notFound }

        let fallback = transaction.splits.first { $0 !== funding && $0.account != nil }?.account
        let resolvable = analysis.lineItems.allSatisfy {
            $0.suggestedCategoryID.flatMap { book.account(with: $0) } != nil || fallback != nil
        }
        guard resolvable, !analysis.lineItems.isEmpty else {
            throw TransactionEntryError.unknownAccount
        }

        var imbalance: Decimal?
        editing([transactionID], named: "Apply Invoice Details") {
            for split in transaction.splits where split !== funding {
                transaction.removeSplit(split)
            }
            var allocated = Decimal(0)
            for item in analysis.lineItems {
                guard let account = item.suggestedCategoryID.flatMap({ book.account(with: $0) }) ?? fallback
                else { continue }
                transaction.addSplit(account: account, value: item.amount, memo: item.itemDescription)
                allocated += item.amount
            }
            // The funding leg is the source of truth for the cash that moved;
            // post any extraction residual rather than leaving an imbalance.
            let residual = -funding.value - allocated
            if residual != 0, let account = fallback
                ?? analysis.lineItems.first?.suggestedCategoryID.flatMap({ book.account(with: $0) }) {
                transaction.addSplit(account: account, value: residual, memo: "Invoice adjustment")
            }
            if !analysis.vendor.isEmpty && transaction.transactionDescription.isEmpty {
                transaction.transactionDescription = analysis.vendor
            }
            if adjustDate {
                adoptEconomicDate(of: transaction, to: analysis.date)
            }
            if !transaction.isBalanced { imbalance = transaction.imbalance.amount }
        }
        if let imbalance { throw TransactionEntryError.unbalanced(imbalance) }
    }

    /// Creates a brand-new transaction from an invoice with no register match
    /// (`FR-AI-07`): the chosen funding account pays the total, and each line
    /// item books to its suggested category (falling back to the first resolved
    /// category, with any line-sum residual posted as an adjustment). Returns the
    /// new transaction's id.
    @discardableResult
    public func createTransactionFromInvoice(
        _ analysis: InvoiceAnalysis,
        fundingAccountID: GncGUID
    ) throws -> GncGUID {
        guard let book, let funding = book.account(with: fundingAccountID) else {
            throw TransactionEntryError.unknownAccount
        }
        let categories = analysis.lineItems.map { $0.suggestedCategoryID.flatMap { book.account(with: $0) } }
        guard !analysis.lineItems.isEmpty, let firstCategory = categories.compactMap({ $0 }).first else {
            throw TransactionEntryError.unknownAccount
        }

        var splits = [SplitInput(accountID: fundingAccountID, value: -analysis.total,
                                 memo: analysis.vendor)]
        var allocated = Decimal(0)
        for (item, account) in zip(analysis.lineItems, categories) {
            splits.append(SplitInput(accountID: (account ?? firstCategory).guid,
                                     value: item.amount, memo: item.itemDescription))
            allocated += item.amount
        }
        // Post any line-sum-vs-total residual so the new transaction balances.
        let residual = analysis.total - allocated
        if residual != 0 {
            splits.append(SplitInput(accountID: firstCategory.guid, value: residual,
                                     memo: "Invoice adjustment"))
        }
        return try addTransaction(date: analysis.date ?? Date(),
                                  description: analysis.vendor,
                                  currency: funding.commodity, splits: splits)
    }

    // MARK: Date helpers

    /// Adopts `newDate` as the economic date, preserving the bank's date in
    /// ``Transaction/statementDate`` (first adjustment only) so statement
    /// re-imports still match.
    private func adoptEconomicDate(of transaction: Transaction, to newDate: Date?) {
        guard let newDate, daysBetween(newDate, transaction.datePosted) != 0 else { return }
        if transaction.statementDate == nil {
            transaction.statementDate = transaction.datePosted
        }
        transaction.datePosted = newDate
    }

    private func fundingSplit(of transaction: Transaction, total: Decimal) -> Split? {
        transaction.splits.first { split in
            guard let type = split.account?.type else { return false }
            return (type.isAssetLike || type.isLiabilityLike)
                && split.value == -total
                && split.reconcileState != .voided
        }
    }

    private func mentionsAny(_ transaction: Transaction, tokens: [String]) -> Bool {
        let haystack = (transaction.transactionDescription + " "
                        + transaction.splits.map(\.memo).joined(separator: " "))
        return tokens.contains { haystack.localizedCaseInsensitiveContains($0) }
    }

    /// Whole days from `from` to `to` (positive when `to` is later), in UTC.
    private func daysBetween(_ from: Date, _ to: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.dateComponents([.day], from: from, to: to).day ?? .max
    }

    /// Closest whole-day distance from either of the transaction's dates.
    private func daysApart(_ transaction: Transaction, from date: Date) -> Int {
        let dates = [transaction.datePosted, transaction.statementDate].compactMap { $0 }
        return dates.map { abs(daysBetween(date, $0)) }.min() ?? .max
    }
}
