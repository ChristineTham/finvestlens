//
//  FinancialReports.swift
//  FinvestLens — Reports
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// One account's contribution to a report, sign-adjusted for presentation.
public struct ReportLine: Identifiable, Hashable, Sendable {
    public let id: GncGUID
    public var name: String
    public var fullName: String
    public var amount: Decimal
}

/// A Balance Sheet as of a date (`FR-RPT-01`).
public struct BalanceSheet: Sendable {
    public var asOf: Date
    public var currencyCode: String
    public var assets: [ReportLine]
    public var liabilities: [ReportLine]
    public var equity: [ReportLine]
    public var totalAssets: Decimal
    public var totalLiabilities: Decimal
    /// Equity from equity accounts plus retained earnings (income − expenses).
    public var totalEquity: Decimal
    public var retainedEarnings: Decimal

    /// A well-formed balance sheet balances: assets = liabilities + equity.
    public var isBalanced: Bool { totalAssets == totalLiabilities + totalEquity }
}

/// An Income Statement (Profit & Loss) over a period (`FR-RPT-01`).
public struct IncomeStatement: Sendable {
    public var from: Date
    public var to: Date
    public var currencyCode: String
    public var income: [ReportLine]
    public var expenses: [ReportLine]
    public var totalIncome: Decimal
    public var totalExpenses: Decimal
    public var netIncome: Decimal
}

/// A net-worth data point (for a trend chart, `FR-RPT-03`).
public struct NetWorthPoint: Identifiable, Hashable, Sendable {
    public var id: Date { date }
    public var date: Date
    public var assets: Decimal
    public var liabilities: Decimal
    public var netWorth: Decimal
}

/// Computes the core financial reports over an engine ``Book``.
///
/// Reports are multi-currency: every account is included and converted into
/// the report `currency` using the price DB at the report date — foreign
/// currencies at the FX rate, **security holdings at market** (shares × unit
/// price, `FR-INV-06`/`FR-CUR-03`). Accounts with no available rate/price are
/// omitted. Amounts are sign-adjusted so credit-normal accounts (liabilities,
/// equity, income) read as positive.
public enum FinancialReports {

    static let assetTypes: Set<AccountType> =
        [.asset, .bank, .cash, .stock, .mutualFund, .receivable]
    static let liabilityTypes: Set<AccountType> = [.liability, .credit, .payable]
    private static let equityTypes: Set<AccountType> = [.equity]

    // MARK: One-pass balances

    /// Every account's balance over a window, in one walk of the book.
    ///
    /// The statement reports each want all ~559 balances at once, and asking
    /// per account walks the whole book per account — 26 million split visits
    /// on the reference book, measured at 7.9s for a balance sheet and 15.6s
    /// for an account summary. Reading the one-walk map instead is 46k visits;
    /// the same rewrite took `netWorthSeries` from 32s to 0.066s.
    ///
    /// Raw double-entry sign (debit positive); use ``displayBalance(in:of:)``
    /// for the presentation sign.
    static func balanceMap(_ book: Book, from: Date?, to: Date?) -> [ObjectIdentifier: Decimal] {
        book.balancesByAccount(from: from, to: to)
    }

    /// The presentation-signed balance an account has in `map` — the same
    /// number ``displayBalance(of:in:from:to:)`` computes by walking, without
    /// the walk.
    static func displayBalance(in map: [ObjectIdentifier: Decimal], of account: Account) -> Decimal {
        let raw = map[ObjectIdentifier(account)] ?? 0
        return account.type.normalBalanceIsDebit ? raw : -raw
    }

    // MARK: Balance Sheet

    public static func balanceSheet(_ book: Book, asOf: Date, currency: Commodity) -> BalanceSheet {
        // Everything below — the three sections, retained earnings, the FX
        // fold — reads this one map: one walk, one conversion per account.
        let map = balanceMap(book, from: nil, to: asOf)
        let accounts = book.accounts.filter { !$0.isPlaceholder }

        func lines(_ types: Set<AccountType>) -> ([ReportLine], Decimal) {
            var result: [ReportLine] = []
            var total = Decimal(0)
            for account in accounts where types.contains(account.type) {
                let native = displayBalance(in: map, of: account)
                guard let amount = convert(native, of: account, in: book,
                                           to: currency, on: asOf),
                      amount != 0 else { continue }
                result.append(ReportLine(id: account.guid, name: account.name,
                                         fullName: account.fullName, amount: currency.round(amount)))
                total += amount
            }
            return (result.sorted { $0.fullName < $1.fullName }, total)
        }

        func typeTotal(_ types: Set<AccountType>) -> Decimal {
            var total = Decimal(0)
            for account in accounts where types.contains(account.type) {
                let native = displayBalance(in: map, of: account)
                guard let amount = convert(native, of: account, in: book,
                                           to: currency, on: asOf) else { continue }
                total += amount
            }
            return total
        }

        let (assets, totalAssets) = lines(assetTypes)
        let (liabilities, totalLiabilities) = lines(liabilityTypes)
        let (equityAccounts, equityFromAccounts) = lines(equityTypes)

        // Retained earnings = income − expenses to date, folded into equity so
        // the sheet balances.
        let retained = typeTotal([.income]) - typeTotal([.expense])

        // Trading accounts (multi-currency FX): their net value at current rates
        // is the unrealised FX gain. They are debit-normal, so subtract to fold
        // that gain into equity and keep the sheet balanced (`FR-REG-07`).
        var equityLines = equityAccounts
        let tradingEquity = -typeTotal([.trading])
        if tradingEquity != 0 {
            equityLines.append(ReportLine(id: .random(), name: "Unrealised FX", fullName: "Trading",
                                          amount: currency.round(tradingEquity)))
        }

        return BalanceSheet(
            asOf: asOf,
            currencyCode: currency.mnemonic,
            assets: assets,
            liabilities: liabilities,
            equity: equityLines,
            totalAssets: currency.round(totalAssets),
            totalLiabilities: currency.round(totalLiabilities),
            totalEquity: currency.round(equityFromAccounts + retained + tradingEquity),
            retainedEarnings: currency.round(retained)
        )
    }

    // MARK: Income Statement

    public static func incomeStatement(_ book: Book, from: Date, to: Date,
                                       currency: Commodity) -> IncomeStatement {
        let map = balanceMap(book, from: from, to: to)
        let accounts = book.accounts.filter { !$0.isPlaceholder }

        func lines(_ type: AccountType) -> ([ReportLine], Decimal) {
            var result: [ReportLine] = []
            var total = Decimal(0)
            for account in accounts where account.type == type {
                let native = displayBalance(in: map, of: account)
                guard let amount = convert(native, of: account, in: book,
                                           to: currency, on: to),
                      amount != 0 else { continue }
                result.append(ReportLine(id: account.guid, name: account.name,
                                         fullName: account.fullName, amount: currency.round(amount)))
                total += amount
            }
            return (result.sorted { $0.fullName < $1.fullName }, total)
        }

        let (income, totalIncome) = lines(.income)
        let (expenses, totalExpenses) = lines(.expense)
        return IncomeStatement(
            from: from, to: to, currencyCode: currency.mnemonic,
            income: income, expenses: expenses,
            totalIncome: currency.round(totalIncome),
            totalExpenses: currency.round(totalExpenses),
            netIncome: currency.round(totalIncome - totalExpenses)
        )
    }

    // MARK: Net Worth series

    /// Assets, liabilities and net worth as of each of `dates`, in `currency`.
    ///
    /// Computed in one pass over the book. The obvious shape — ask each account
    /// for its balance at each date — costs *dates × accounts × transactions*,
    /// because every balance walks the whole book: on the reference book that is
    /// 12 × 559 × 46,553, about **1.7 billion split visits**, measured at **32s**
    /// for the dashboard's 12-month series (debug). Since the dashboard computes
    /// this inside its `body`, that was the price of every render, and the bulk
    /// of the wait when opening a book.
    ///
    /// The saving is that balances accumulate: walk the transactions in date
    /// order, carry a running total per account, and each date reads off what
    /// has landed so far. That is one visit per split, plus one conversion per
    /// account per date — measured at **0.066s** for the same series, and it
    /// still lands on $3,964,362.15 to the cent.
    public static func netWorthSeries(_ book: Book, dates: [Date],
                                      currency: Commodity) -> [NetWorthPoint] {
        let sortedDates = dates.sorted()
        guard !sortedDates.isEmpty else { return [] }

        // Every account the series can count, indexed by identity so a split can
        // find its slot without searching.
        let accounts = book.accounts.filter {
            !$0.isPlaceholder
                && (assetTypes.contains($0.type) || liabilityTypes.contains($0.type))
        }
        var slot = [ObjectIdentifier: Int](minimumCapacity: accounts.count)
        for (index, account) in accounts.enumerated() {
            slot[ObjectIdentifier(account)] = index
        }

        // The dates only ever move forward, and a balance "as of" a date is the
        // balance as of the one before it plus what happened in between. So the
        // book is walked once in date order, carrying the running native balance
        // of every account, and each date reads off what has accumulated.
        var running = [Decimal](repeating: 0, count: accounts.count)
        let ordered = book.transactions.sorted { $0.datePosted < $1.datePosted }
        var next = 0

        return sortedDates.map { date in
            while next < ordered.count, ordered[next].datePosted <= date {
                for split in ordered[next].splits where split.reconcileState != .voided {
                    if let account = split.account, let index = slot[ObjectIdentifier(account)] {
                        running[index] += split.quantity
                    }
                }
                next += 1
            }

            // Conversion still happens per account per date: a rate moves even
            // when a balance does not, so a holding's value at each date is its
            // own question. That is 559 × 12 price lookups on the reference
            // book, against the 1.7 billion split visits this used to make.
            var assets = Decimal(0)
            var liabilities = Decimal(0)
            for (index, account) in accounts.enumerated() {
                let native = account.type.normalBalanceIsDebit ? running[index] : -running[index]
                guard let amount = convert(native, of: account, in: book,
                                           to: currency, on: date) else { continue }
                if assetTypes.contains(account.type) { assets += amount }
                if liabilityTypes.contains(account.type) { liabilities += amount }
            }
            return NetWorthPoint(
                date: date,
                assets: currency.round(assets),
                liabilities: currency.round(liabilities),
                netWorth: currency.round(assets - liabilities)
            )
        }
    }

    // MARK: Balances

    /// The presentation balance of an account within an optional date window,
    /// sign-adjusted so credit-normal types read positive.
    static func displayBalance(of account: Account, in book: Book,
                               from: Date?, to: Date?) -> Decimal {
        var total = Decimal(0)
        for transaction in book.transactions {
            if let from, transaction.datePosted < from { continue }
            if let to, transaction.datePosted > to { continue }
            for split in transaction.splits
            where split.account === account && split.reconcileState != .voided {
                total += split.quantity
            }
        }
        return account.type.normalBalanceIsDebit ? total : -total
    }

    /// The sign-adjusted actual for an account over a period (spending positive
    /// for expense accounts) — used by auto-budget.
    public static func periodActual(of account: Account, in book: Book,
                                    from: Date, to: Date) -> Decimal {
        displayBalance(of: account, in: book, from: from, to: to)
    }

    /// The account's sign-adjusted balance converted into `currency` at
    /// `rateDate`, or `nil` when a foreign account cannot be valued.
    static func convertedDisplayBalance(of account: Account, in book: Book,
                                        from: Date?, to: Date?, currency: Commodity,
                                        rateDate: Date?) -> Decimal? {
        convert(displayBalance(of: account, in: book, from: from, to: to),
                of: account, in: book, to: currency, on: rateDate)
    }

    /// An already-computed native balance converted into `currency` at
    /// `rateDate`, or `nil` when a foreign account cannot be valued.
    ///
    /// Split out from ``convertedDisplayBalance(of:in:from:to:currency:rateDate:)``
    /// so a caller that already knows the balance — ``netWorthSeries`` walks the
    /// book once and knows all of them — does not have to walk the book again to
    /// have it converted.
    static func convert(_ native: Decimal, of account: Account, in book: Book,
                        to currency: Commodity, on rateDate: Date?) -> Decimal? {
        if account.commodity == currency || native == 0 { return native }
        if account.commodity.namespace == .currency {
            return book.convert(native, from: account.commodity, to: currency, on: rateDate)
        }
        // Security (stock/fund): value the holding at market — shares × the
        // latest unit price in `currency` (`FR-INV-06`).
        guard let unit = book.securityUnitValue(account.commodity, in: currency, on: rateDate) else { return nil }
        return native * unit
    }

    static func periodTotal(_ book: Book, types: Set<AccountType>,
                                    from: Date?, to: Date?, currency: Commodity,
                                    rateDate: Date?) -> Decimal {
        // One walk for the whole type, not one per account of the type.
        let map = balanceMap(book, from: from, to: to)
        var total = Decimal(0)
        for account in book.accounts
        where types.contains(account.type) && !account.isPlaceholder {
            let native = displayBalance(in: map, of: account)
            if let amount = convert(native, of: account, in: book,
                                    to: currency, on: rateDate) {
                total += amount
            }
        }
        return total
    }
}
