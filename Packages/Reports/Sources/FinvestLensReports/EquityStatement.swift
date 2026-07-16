//
//  EquityStatement.swift
//  FinvestLens — Reports
//
//  GnuCash's Equity Statement (`FR-RPT-01`): where the owner's stake moved over
//  a period, and why. It completes the statement trio — the balance sheet says
//  where you stand, the income statement says what the period earned, and this
//  is the bridge between two balance sheets: opening capital, plus what was
//  earned, plus what the owner put in or took out, plus what the market did,
//  equals closing capital.
//
//  The last term is computed as the residual, and that is not a fudge: with
//  every price standing still it is exactly zero (the tests pin that), so
//  whatever it reads *is* the valuation change — unrealised gains, FX
//  revaluation — the period's postings cannot account for.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

public struct EquityStatement: Sendable {
    public var from: Date
    public var to: Date
    public var currencyCode: String

    /// Net worth (assets − liabilities) the moment the period opens, valued at
    /// opening-date rates.
    public var openingCapital: Decimal
    /// Income less expenses over the period — the income statement's bottom line.
    public var netIncome: Decimal
    /// Posted *into* equity accounts during the period: owner contributions,
    /// opening balances entered during it.
    public var contributions: Decimal
    /// Posted out of equity accounts during the period: draws.
    public var withdrawals: Decimal
    /// The valuation change the postings cannot account for — unrealised gains
    /// and FX movement. Zero when every price stood still.
    public var unrealisedChange: Decimal
    /// Net worth at the period's close, valued at closing-date rates.
    public var closingCapital: Decimal

    /// The bridge itself. It holds by construction — `unrealisedChange` is the
    /// residual — so a false value means broken arithmetic, not a bad book.
    public var isConsistent: Bool {
        openingCapital + netIncome + contributions - withdrawals + unrealisedChange
            == closingCapital
    }
}

public extension FinancialReports {

    /// The movement of capital over `[from, to]` (`FR-RPT-01`).
    static func equityStatement(_ book: Book, from: Date, to: Date,
                                currency: Commodity) -> EquityStatement {
        // Opening is the world *before* the period: strictly earlier postings,
        // valued at the opening date. `justBefore` keeps day-granularity books
        // exact — a posting dated `from` belongs to the period, not the opening.
        let justBefore = from.addingTimeInterval(-1)
        let opening = netWorth(book, upTo: justBefore, currency: currency)
        let closing = netWorth(book, upTo: to, currency: currency)

        let income = periodTotal(book, types: [.income], from: from, to: to,
                                 currency: currency, rateDate: to)
        let expenses = periodTotal(book, types: [.expense], from: from, to: to,
                                   currency: currency, rateDate: to)
        let netIncome = income - expenses

        // Equity postings in the raw bookkeeping sign: credits (negative) are
        // money into equity — contributions — and debits are draws.
        var contributions = Decimal(0)
        var withdrawals = Decimal(0)
        for transaction in book.transactions
        where transaction.datePosted >= from && transaction.datePosted <= to {
            for split in transaction.splits
            where split.account?.type == .equity && split.reconcileState != .voided {
                guard let account = split.account,
                      let amount = convert(split.quantity, of: account, in: book,
                                           to: currency, on: to) else { continue }
                if amount < 0 { contributions += -amount } else { withdrawals += amount }
            }
        }

        let residual = closing - opening - netIncome - contributions + withdrawals
        return EquityStatement(
            from: from, to: to, currencyCode: currency.mnemonic,
            openingCapital: currency.round(opening),
            netIncome: currency.round(netIncome),
            contributions: currency.round(contributions),
            withdrawals: currency.round(withdrawals),
            unrealisedChange: currency.round(residual),
            closingCapital: currency.round(closing))
    }

    /// Assets minus liabilities from postings up to and including `date`,
    /// valued at `date` — the same convention as the balance sheet, so the
    /// bridge lands on figures the other statements agree with.
    private static func netWorth(_ book: Book, upTo date: Date, currency: Commodity) -> Decimal {
        var total = Decimal(0)
        for account in book.accounts where !account.isPlaceholder {
            let isAsset = assetTypes.contains(account.type)
            let isLiability = liabilityTypes.contains(account.type)
            guard isAsset || isLiability else { continue }
            let native = displayBalance(of: account, in: book, from: nil, to: date)
            guard let amount = convert(native, of: account, in: book,
                                       to: currency, on: date) else { continue }
            total += isAsset ? amount : -amount
        }
        return total
    }
}
