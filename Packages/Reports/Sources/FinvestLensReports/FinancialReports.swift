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

    private static let assetTypes: Set<AccountType> =
        [.asset, .bank, .cash, .stock, .mutualFund, .receivable]
    private static let liabilityTypes: Set<AccountType> = [.liability, .credit, .payable]
    private static let equityTypes: Set<AccountType> = [.equity]

    // MARK: Balance Sheet

    public static func balanceSheet(_ book: Book, asOf: Date, currency: Commodity) -> BalanceSheet {
        let accounts = book.accounts.filter { !$0.isPlaceholder }

        func lines(_ types: Set<AccountType>) -> ([ReportLine], Decimal) {
            var result: [ReportLine] = []
            var total = Decimal(0)
            for account in accounts where types.contains(account.type) {
                guard let amount = convertedDisplayBalance(of: account, in: book, from: nil, to: asOf,
                                                           currency: currency, rateDate: asOf),
                      amount != 0 else { continue }
                result.append(ReportLine(id: account.guid, name: account.name,
                                         fullName: account.fullName, amount: currency.round(amount)))
                total += amount
            }
            return (result.sorted { $0.fullName < $1.fullName }, total)
        }

        let (assets, totalAssets) = lines(assetTypes)
        let (liabilities, totalLiabilities) = lines(liabilityTypes)
        let (equityAccounts, equityFromAccounts) = lines(equityTypes)

        // Retained earnings = income − expenses to date, folded into equity so
        // the sheet balances.
        let income = periodTotal(book, types: [.income], from: nil, to: asOf, currency: currency, rateDate: asOf)
        let expenses = periodTotal(book, types: [.expense], from: nil, to: asOf, currency: currency, rateDate: asOf)
        let retained = income - expenses

        // Trading accounts (multi-currency FX): their net value at current rates
        // is the unrealised FX gain. They are debit-normal, so subtract to fold
        // that gain into equity and keep the sheet balanced (`FR-REG-07`).
        var equityLines = equityAccounts
        let trading = periodTotal(book, types: [.trading], from: nil, to: asOf, currency: currency, rateDate: asOf)
        let tradingEquity = -trading
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
        let accounts = book.accounts.filter { !$0.isPlaceholder }

        func lines(_ type: AccountType) -> ([ReportLine], Decimal) {
            var result: [ReportLine] = []
            var total = Decimal(0)
            for account in accounts where account.type == type {
                guard let amount = convertedDisplayBalance(of: account, in: book, from: from, to: to,
                                                           currency: currency, rateDate: to),
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

    public static func netWorthSeries(_ book: Book, dates: [Date],
                                      currency: Commodity) -> [NetWorthPoint] {
        dates.sorted().map { date in
            let assets = periodTotal(book, types: assetTypes, from: nil, to: date, currency: currency, rateDate: date)
            let liabilities = periodTotal(book, types: liabilityTypes, from: nil, to: date, currency: currency, rateDate: date)
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
        let native = displayBalance(of: account, in: book, from: from, to: to)
        if account.commodity == currency || native == 0 { return native }
        if account.commodity.namespace == .currency {
            return book.convert(native, from: account.commodity, to: currency, on: rateDate)
        }
        // Security (stock/fund): value the holding at market — shares × the
        // latest unit price in `currency` (`FR-INV-06`).
        guard let unit = book.securityUnitValue(account.commodity, in: currency, on: rateDate) else { return nil }
        return native * unit
    }

    private static func periodTotal(_ book: Book, types: Set<AccountType>,
                                    from: Date?, to: Date?, currency: Commodity,
                                    rateDate: Date?) -> Decimal {
        var total = Decimal(0)
        for account in book.accounts
        where types.contains(account.type) && !account.isPlaceholder {
            if let amount = convertedDisplayBalance(of: account, in: book, from: from, to: to,
                                                    currency: currency, rateDate: rateDate) {
                total += amount
            }
        }
        return total
    }
}
