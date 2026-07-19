//
//  BookClosing.swift
//  FinvestLens — Engine
//
//  Period-end "Close Book" (GnuCash's Tools ▸ Close Book): move the balances of
//  the income and expense accounts into an equity account as of a closing date,
//  so the profit-and-loss accounts start the next period at zero and the period
//  result lands in equity.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Builds the closing transactions for a period-end book close.
///
/// One closing transaction is produced per currency, containing a zeroing split
/// for every income/expense account with a non-zero balance in that currency
/// and a single balancing split to the equity account. The transaction balances
/// by construction (the equity split is the negated sum of the others), so the
/// book's totals are unchanged — the period result simply moves from P&L into
/// equity, exactly as a manual closing entry would.
public enum BookClosing {

    /// A per-currency closing transaction, ready to add to the book. Not
    /// `Sendable` — `Transaction` is a reference into the book's object graph.
    public struct Result {
        public var transactions: [Transaction]
        /// Accounts that were zeroed, for the confirmation summary.
        public var closedAccountCount: Int
    }

    /// Builds closing transactions as of `date` (inclusive), moving income and
    /// expense balances into `equity`. Returns an empty result when nothing has
    /// a balance to close.
    ///
    /// - Parameters:
    ///   - date: the closing date; only postings on or before it are counted.
    ///   - equity: the equity account the period result lands in.
    ///   - description: the closing transactions' description.
    public static func build(in book: Book, asOf date: Date, into equity: Account,
                             description: String = "Closing Entries") -> Result {
        // Every account's balance as of the date, in one pass.
        let balances = book.balancesByAccount(to: date)

        // Group the P&L accounts by their currency, so each closing transaction
        // is single-currency and balances without an exchange rate.
        var byCurrency: [Commodity: [(account: Account, balance: Decimal)]] = [:]
        for account in book.accounts where account.type == .income || account.type == .expense {
            let balance = balances[ObjectIdentifier(account)] ?? 0
            guard balance != 0 else { continue }
            byCurrency[account.commodity, default: []].append((account, balance))
        }

        var transactions: [Transaction] = []
        var closed = 0
        // Deterministic order: the currency the equity account is in first, then
        // by mnemonic, so a rerun produces the same shape.
        for currency in byCurrency.keys.sorted(by: { $0.mnemonic < $1.mnemonic }) {
            guard let entries = byCurrency[currency], !entries.isEmpty else { continue }
            let txn = Transaction(currency: currency, datePosted: date, description: description)
            var equityQuantity = Decimal(0)
            for entry in entries {
                // Zero the account: post the negative of its balance.
                txn.addSplit(Split(account: entry.account, value: -entry.balance))
                equityQuantity += entry.balance
                closed += 1
            }
            // The balancing leg into equity carries the period result. Its value
            // is in the transaction (P&L) currency; when equity is denominated in
            // a different commodity the quantity must be converted, or the equity
            // balance would read the foreign value as if it were its own currency.
            let equityQty = equity.commodity == currency
                ? equityQuantity
                : (book.convert(equityQuantity, from: currency, to: equity.commodity, on: date) ?? equityQuantity)
            txn.addSplit(Split(account: equity, value: equityQuantity, quantity: equityQty))
            transactions.append(txn)
        }
        return Result(transactions: transactions, closedAccountCount: closed)
    }
}
