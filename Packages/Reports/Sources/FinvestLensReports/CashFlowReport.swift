//
//  CashFlowReport.swift
//  FinvestLens — Reports
//
//  GnuCash's Cash Flow (`FR-RPT-01`): over a period, where did the money that
//  entered these accounts come from, and where did what left them go? Distinct
//  from the forecast that used to wear this name — that projects a balance
//  forward; this accounts for a period that already happened.
//
//  The attribution rule is double entry itself. Every transaction sums to
//  zero, so whatever its splits inside the chosen set add up to, the splits
//  outside add up to the exact negative — each external split is a flow of
//  −(its value), attributed to its own account. Transfers wholly inside the
//  set have no external splits and vanish, as internal shuffles should. The
//  identity falls straight out: money in minus money out equals the set's net
//  change over the period, to the cent.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

public struct CashFlowReport: Sendable {
    public var from: Date
    public var to: Date
    public var currencyCode: String
    /// The names of the chosen accounts, for the heading.
    public var accountNames: [String]
    /// Where the money came from, by external account, largest first.
    public var inflows: [ReportLine]
    /// Where it went, by external account, largest first.
    public var outflows: [ReportLine]
    public var totalIn: Decimal
    public var totalOut: Decimal
    /// `totalIn − totalOut` — by double entry, the chosen accounts' net change
    /// over the period.
    public var netChange: Decimal
}

public extension FinancialReports {

    /// The flows into and out of `accountIDs` over `[from, to]` (`FR-RPT-01`).
    static func cashFlow(_ book: Book, accountIDs: Set<GncGUID>,
                         from: Date, to: Date, currency: Commodity) -> CashFlowReport {
        var flow: [GncGUID: (account: Account, amount: Decimal)] = [:]

        for transaction in book.transactions
        where transaction.datePosted >= from && transaction.datePosted <= to {
            let touchesSet = transaction.splits.contains {
                guard let id = $0.account?.guid else { return false }
                return accountIDs.contains(id) && $0.reconcileState != .voided
            }
            guard touchesSet else { continue }

            for split in transaction.splits where split.reconcileState != .voided {
                guard let account = split.account, !accountIDs.contains(account.guid) else {
                    continue
                }
                // Values are in the transaction's currency; convert at the
                // posting date, when the money actually moved. −value because
                // an external credit (negative) is money that left there for
                // here.
                guard let amount = book.convert(-split.value, from: transaction.currency,
                                                to: currency, on: transaction.datePosted)
                else { continue }
                flow[account.guid, default: (account, 0)].amount += amount
            }
        }

        // An account is a source or a destination by where it ended up net —
        // GnuCash's report does the same, rather than splitting one account
        // across both columns.
        var inflows: [ReportLine] = []
        var outflows: [ReportLine] = []
        var totalIn = Decimal(0)
        var totalOut = Decimal(0)
        for (id, entry) in flow {
            let rounded = currency.round(entry.amount)
            guard rounded != 0 else { continue }
            let line = ReportLine(id: id, name: entry.account.name,
                                  fullName: entry.account.fullName,
                                  amount: abs(rounded))
            if rounded > 0 { inflows.append(line); totalIn += rounded }
            else { outflows.append(line); totalOut += -rounded }
        }
        inflows.sort { $0.amount == $1.amount ? $0.fullName < $1.fullName : $0.amount > $1.amount }
        outflows.sort { $0.amount == $1.amount ? $0.fullName < $1.fullName : $0.amount > $1.amount }

        let names = accountIDs
            .compactMap { book.account(with: $0)?.name }
            .sorted()

        return CashFlowReport(
            from: from, to: to, currencyCode: currency.mnemonic,
            accountNames: names,
            inflows: inflows, outflows: outflows,
            totalIn: currency.round(totalIn),
            totalOut: currency.round(totalOut),
            netChange: currency.round(totalIn - totalOut))
    }
}
