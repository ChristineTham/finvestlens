//
//  TrialBalance.swift
//  FinvestLens — Reports
//
//  GnuCash's Trial Balance (`FR-RPT-01`): every account's balance as of a date,
//  laid out in debit and credit columns, and the two columns must agree.
//
//  In a single-currency book they agree by double entry alone: every
//  transaction sums to zero, so every account balance is some slice of zero.
//  Valuing securities at market and foreign currencies at today's rate breaks
//  that — deliberately, since a balance sheet at cost would be a fiction — and
//  the exact amount by which it breaks *is* the unrealised gain. GnuCash prints
//  that amount as an adjustment row rather than hiding it, and so does this:
//  the report balances by construction, and the plug it balances with is a
//  number worth reading.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// One account's line: its balance, sitting in one column or the other.
public struct TrialBalanceRow: Identifiable, Hashable, Sendable {
    public let id: GncGUID
    public var name: String
    public var fullName: String
    /// Exactly one of these is non-nil: a balance is a debit or a credit, and
    /// zero-balance accounts are not listed at all.
    public var debit: Decimal?
    public var credit: Decimal?
}

public struct TrialBalanceReport: Sendable {
    public var asOf: Date
    public var currencyCode: String
    public var rows: [TrialBalanceRow]
    /// The unrealised gain (or loss) that valuation at market introduced —
    /// zero in a single-currency book, and the number that makes the columns
    /// equal otherwise. Positive sits with the credits, as gains do.
    public var unrealisedAdjustment: Decimal
    /// Column totals, adjustment included.
    public var totalDebits: Decimal
    public var totalCredits: Decimal

    /// The property the report exists to state. It holds by construction; a
    /// false value here means the arithmetic itself is broken.
    public var isBalanced: Bool { totalDebits == totalCredits }
}

public extension FinancialReports {

    /// Every account's balance as of `asOf`, in debit/credit columns, converted
    /// into `currency` at that date's rates (`FR-RPT-01`).
    static func trialBalance(_ book: Book, asOf: Date, currency: Commodity) -> TrialBalanceReport {
        var rows: [TrialBalanceRow] = []
        var debits = Decimal(0)
        var credits = Decimal(0)

        for account in book.accounts where !account.isPlaceholder {
            // The *raw* signed balance — debit positive, credit negative — not
            // the presentation sign the other statements use. A trial balance
            // is the one report that wants the bookkeeping sign convention.
            let native = rawBalance(of: account, in: book, to: asOf)
            guard let converted = convert(native, of: account, in: book,
                                          to: currency, on: asOf),
                  currency.round(converted) != 0 else { continue }

            let amount = currency.round(converted)
            if amount > 0 {
                rows.append(TrialBalanceRow(id: account.guid, name: account.name,
                                            fullName: account.fullName,
                                            debit: amount, credit: nil))
                debits += amount
            } else {
                rows.append(TrialBalanceRow(id: account.guid, name: account.name,
                                            fullName: account.fullName,
                                            debit: nil, credit: -amount))
                credits += -amount
            }
        }
        rows.sort { $0.fullName < $1.fullName }

        // What market valuation added: with every balance at cost the columns
        // are equal by double entry, so the gap is precisely the unrealised
        // gain (debits exceed credits when holdings are worth more than they
        // cost). It joins the credit column, as a gain would.
        let adjustment = debits - credits
        return TrialBalanceReport(
            asOf: asOf,
            currencyCode: currency.mnemonic,
            rows: rows,
            unrealisedAdjustment: adjustment,
            totalDebits: debits,
            totalCredits: credits + adjustment)
    }

    /// The sum of an account's split quantities up to `date` — the raw
    /// double-entry balance, before any presentation sign flip.
    private static func rawBalance(of account: Account, in book: Book, to date: Date) -> Decimal {
        var total = Decimal(0)
        for transaction in book.transactions where transaction.datePosted <= date {
            for split in transaction.splits
            where split.account === account && split.reconcileState != .voided {
                total += split.quantity
            }
        }
        return total
    }
}
