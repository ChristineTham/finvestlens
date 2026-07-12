//
//  TransactionReport.swift
//  FinvestLens — Reports
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// One posting to the reported account (`FR-RPT-04`).
public struct TransactionReportRow: Identifiable, Hashable, Sendable {
    public let id: GncGUID
    public var date: Date
    public var description: String
    /// The account(s) on the other side of the transaction.
    public var transfer: String
    /// Signed amount posted to the reported account (in its commodity).
    public var amount: Decimal
    /// Running balance of the reported account after this posting.
    public var balance: Decimal
}

/// A Transaction Report: an account's postings over a period with a running
/// balance and a period total (`FR-RPT-04`).
public struct TransactionReport: Sendable {
    public var accountName: String
    public var from: Date
    public var to: Date
    public var currencyCode: String
    public var rows: [TransactionReportRow]
    /// Net change over the period.
    public var total: Decimal
    /// Opening balance carried into the period.
    public var opening: Decimal
    /// Closing balance at the end of the period.
    public var closing: Decimal
}

public extension FinancialReports {

    /// Lists the postings of `accountID` within `[from, to]`, with a running
    /// balance seeded by the opening balance up to `from` (`FR-RPT-04`).
    static func transactionReport(_ book: Book, accountID: GncGUID,
                                  from: Date, to: Date) -> TransactionReport? {
        guard let account = book.account(with: accountID) else { return nil }

        // Postings sorted by date; opening balance is everything strictly before `from`.
        var opening = Decimal(0)
        var inPeriod: [(Split, Transaction)] = []
        for transaction in book.transactions {
            for split in transaction.splits
            where split.account === account && split.reconcileState != .voided {
                if transaction.datePosted < from {
                    opening += split.quantity
                } else if transaction.datePosted <= to {
                    inPeriod.append((split, transaction))
                }
            }
        }
        inPeriod.sort { $0.1.datePosted < $1.1.datePosted }

        let commodity = account.commodity
        var running = opening
        var total = Decimal(0)
        var rows: [TransactionReportRow] = []
        for (split, transaction) in inPeriod {
            running += split.quantity
            total += split.quantity
            let others = transaction.splits
                .filter { $0 !== split }
                .compactMap { $0.account?.name }
            rows.append(TransactionReportRow(
                id: split.guid, date: transaction.datePosted,
                description: transaction.transactionDescription,
                transfer: others.isEmpty ? "—" : Set(others).sorted().joined(separator: ", "),
                amount: commodity.round(split.quantity),
                balance: commodity.round(running)))
        }

        return TransactionReport(
            accountName: account.name, from: from, to: to, currencyCode: commodity.mnemonic,
            rows: rows, total: commodity.round(total),
            opening: commodity.round(opening), closing: commodity.round(running))
    }
}
