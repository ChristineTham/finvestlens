//
//  AccountSummary.swift
//  FinvestLens — Reports
//
//  GnuCash's Account Summary (`FR-RPT-01`, named in the PRD): the whole chart
//  of accounts with a balance against each, to a chosen depth. The depth limit
//  is the point of the report — "show me where I stand, in five lines" — and
//  the rule that makes it trustworthy is that cutting the tree never loses
//  money: an account deeper than the limit rolls into its ancestor at the
//  limit, so every depth sums to the same totals, and those totals are the
//  balance sheet's.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

public struct AccountSummaryRow: Identifiable, Hashable, Sendable {
    public let id: GncGUID
    public var name: String
    public var fullName: String
    /// 1 for a top-level account; drives indentation.
    public var depth: Int
    /// Converted, presentation-signed. At the depth limit this includes
    /// everything rolled up from beneath.
    public var balance: Decimal
}

public struct AccountSummarySection: Identifiable, Sendable {
    public var id: String { title }
    public var title: String
    public var rows: [AccountSummaryRow]
    public var total: Decimal
}

public struct AccountSummaryReport: Sendable {
    public var asOf: Date
    public var currencyCode: String
    public var depthLimit: Int
    public var sections: [AccountSummarySection]
}

public extension FinancialReports {

    /// The chart of accounts with balances as of `asOf`, cut at `depthLimit`
    /// (`FR-RPT-01`).
    ///
    /// Income and expense balances here are lifetime-to-date, as GnuCash shows
    /// them in this report: an account summary answers "what does each account
    /// hold as of this date", and what an income account holds is everything
    /// it has ever recorded.
    static func accountSummary(_ book: Book, asOf: Date, currency: Commodity,
                               depthLimit: Int) -> AccountSummaryReport {
        let limit = max(1, depthLimit)

        /// The account's own converted balance — zero for a placeholder, which
        /// holds structure, not money.
        func own(_ account: Account) -> Decimal {
            guard !account.isPlaceholder else { return 0 }
            let native = displayBalance(of: account, in: book, from: nil, to: asOf)
            guard let amount = convert(native, of: account, in: book,
                                       to: currency, on: asOf) else { return 0 }
            return amount
        }

        /// Own plus everything beneath — what a row at the depth limit shows.
        func rolled(_ account: Account) -> Decimal {
            account.children.reduce(own(account)) { $0 + rolled($1) }
        }

        func rows(_ account: Account, depth: Int) -> [AccountSummaryRow] {
            let balance = depth == limit ? rolled(account) : own(account)
            let children = depth < limit
                ? account.children
                    .sorted { $0.name < $1.name }
                    .flatMap { rows($0, depth: depth + 1) }
                : []
            // A row earns its place by carrying money somewhere: itself, or a
            // child that does. Pruning empties is what keeps a 559-account
            // book readable at depth 3.
            let visible = currency.round(balance) != 0 || !children.isEmpty
            guard visible else { return [] }
            return [AccountSummaryRow(id: account.guid, name: account.name,
                                      fullName: account.fullName, depth: depth,
                                      balance: currency.round(balance))] + children
        }

        func section(_ title: String, _ types: Set<AccountType>) -> AccountSummarySection {
            let tops = book.rootAccount.children
                .filter { types.contains($0.type) }
                .sorted { $0.name < $1.name }
            let allRows = tops.flatMap { rows($0, depth: 1) }
            // The section total is the fully-rolled total of its top accounts —
            // by construction the same number at every depth limit.
            let total = tops.reduce(Decimal(0)) { $0 + rolled($1) }
            return AccountSummarySection(title: title, rows: allRows,
                                         total: currency.round(total))
        }

        let sections = [
            section("Assets", assetTypes),
            section("Liabilities", liabilityTypes),
            section("Equity", [.equity]),
            section("Income", [.income]),
            section("Expenses", [.expense]),
        ].filter { !$0.rows.isEmpty }

        return AccountSummaryReport(asOf: asOf, currencyCode: currency.mnemonic,
                                    depthLimit: limit, sections: sections)
    }
}
