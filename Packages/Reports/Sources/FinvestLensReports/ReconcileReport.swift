//
//  ReconcileReport.swift
//  FinvestLens — Reports
//
//  GnuCash's Reconciliation Report (`FR-RPT-05`).
//
//  Answers the question a reconciled account raises: of what is in here, how
//  much has the bank agreed to? It splits an account's postings by reconcile
//  state — reconciled, cleared, neither — and the three totals have to add back
//  up to the account's balance, because every posting is in exactly one of them.
//  That identity is what the report is for; a reconcile report whose parts do
//  not sum to the whole is worse than no report.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// One posting in a reconcile report.
public struct ReconcileReportRow: Identifiable, Hashable, Sendable {
    /// The split's GUID.
    public let id: GncGUID
    public var date: Date
    /// When it was reconciled, for the rows that have been.
    public var reconcileDate: Date?
    public var number: String
    public var description: String
    public var memo: String
    /// Signed amount in the account's own commodity.
    public var amount: Decimal
    public var state: ReconcileState
}

/// An account's postings grouped by how far through reconciliation they are
/// (`FR-RPT-05`).
public struct ReconcileReport: Sendable {
    public var accountName: String
    public var asOf: Date
    public var currencyCode: String

    /// Reconciled (`y`) money coming in, and going out. GnuCash's report splits
    /// these because a statement does: deposits and withdrawals are checked off
    /// against different columns of it.
    public var fundsIn: [ReconcileReportRow]
    public var fundsOut: [ReconcileReportRow]
    public var totalIn: Decimal
    public var totalOut: Decimal
    /// What the bank has agreed to. Equals `Book.balance(of:filter:.reconciled)`.
    public var reconciledBalance: Decimal

    /// Seen on a statement but not yet reconciled (`c`).
    public var cleared: [ReconcileReportRow]
    public var clearedTotal: Decimal
    /// Reconciled plus cleared — the reconcile window's Cleared figure.
    public var clearedBalance: Decimal

    /// Neither (`n`): what the bank has not seen, or you have not checked.
    public var outstanding: [ReconcileReportRow]
    public var outstandingTotal: Decimal

    /// The account's balance over everything that counts. Voided postings are
    /// excluded here exactly as they are from every balance in the book.
    public var endingBalance: Decimal

    /// Every posting is reconciled, cleared or outstanding — never two of them,
    /// never none — so the three totals must be the balance. If this is ever
    /// false the report is lying about somebody's money.
    public var isConsistent: Bool {
        reconciledBalance + clearedTotal + outstandingTotal == endingBalance
    }
}

public extension FinancialReports {

    /// Groups `accountID`'s postings up to `asOf` by reconcile state
    /// (`FR-RPT-05`).
    ///
    /// Frozen (`f`) counts as outstanding. It is a hold placed on a posting, not
    /// a statement having cleared it — the bank has not agreed to it, so it
    /// cannot sit with the money that has been agreed.
    static func reconcileReport(_ book: Book, accountID: GncGUID,
                                asOf: Date) -> ReconcileReport? {
        guard let account = book.account(with: accountID) else { return nil }

        var rows: [ReconcileReportRow] = []
        for transaction in book.transactions where transaction.datePosted <= asOf {
            for split in transaction.splits
            where split.account === account && split.reconcileState != .voided {
                rows.append(ReconcileReportRow(
                    id: split.guid,
                    date: transaction.datePosted,
                    reconcileDate: split.reconcileDate,
                    number: transaction.number,
                    description: transaction.transactionDescription,
                    memo: split.memo,
                    amount: split.quantity,
                    state: split.reconcileState))
            }
        }
        rows.sort { $0.date < $1.date }

        // Frozen (f) is a locked-reconciled state — GnuCash folds it into the
        // reconciled balance, so it belongs with reconciled, not outstanding.
        let reconciled = rows.filter { $0.state == .reconciled || $0.state == .frozen }
        let cleared = rows.filter { $0.state == .cleared }
        let outstanding = rows.filter { $0.state == .notReconciled }

        // Zero goes with funds in rather than being dropped: a posting that
        // exists has to appear somewhere, or the rows stop accounting for the
        // totals.
        let fundsIn = reconciled.filter { $0.amount >= 0 }
        let fundsOut = reconciled.filter { $0.amount < 0 }
        let totalIn = fundsIn.reduce(Decimal(0)) { $0 + $1.amount }
        let totalOut = fundsOut.reduce(Decimal(0)) { $0 + $1.amount }
        let clearedTotal = cleared.reduce(Decimal(0)) { $0 + $1.amount }
        let outstandingTotal = outstanding.reduce(Decimal(0)) { $0 + $1.amount }

        return ReconcileReport(
            accountName: account.fullName,
            asOf: asOf,
            currencyCode: account.commodity.mnemonic,
            fundsIn: fundsIn,
            fundsOut: fundsOut,
            totalIn: totalIn,
            totalOut: totalOut,
            reconciledBalance: totalIn + totalOut,
            cleared: cleared,
            clearedTotal: clearedTotal,
            clearedBalance: totalIn + totalOut + clearedTotal,
            outstanding: outstanding,
            outstandingTotal: outstandingTotal,
            endingBalance: totalIn + totalOut + clearedTotal + outstandingTotal)
    }
}
