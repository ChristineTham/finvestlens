//
//  AppModel+Reconcile.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// One split under review in a reconciliation session.
public struct ReconcileItem: Identifiable, Hashable, Sendable {
    public let id: GncGUID          // split GUID
    public var date: Date
    public var description: String
    public var amount: Decimal      // quantity in the account commodity
    public var isCleared: Bool
}

/// The state of an in-progress reconciliation (`FR-REC-01`).
public struct ReconcileSessionState: Sendable {
    public var accountID: GncGUID
    public var accountName: String
    public var currencyCode: String
    public var fraction: Int
    public var statementDate: Date
    public var statementBalance: Decimal
    /// Balance of already-reconciled splits before this session.
    public var startingBalance: Decimal
    public var items: [ReconcileItem]

    /// Starting balance plus everything marked cleared in this session.
    public var clearedBalance: Decimal {
        startingBalance + items.filter(\.isCleared).reduce(Decimal(0)) { $0 + $1.amount }
    }

    /// Statement balance minus the cleared balance; zero when reconciled.
    public var difference: Decimal { statementBalance - clearedBalance }

    /// `true` when the difference rounds to zero at the account's fraction.
    public var isBalanced: Bool {
        var scaled = difference * Decimal(fraction)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return rounded == 0
    }
}

@MainActor
extension AppModel {

    /// Starts reconciling `accountID` against a statement. Splits dated on or
    /// before `statementDate` that are not yet reconciled become items; those
    /// already cleared (`c`) start checked.
    public func beginReconcile(accountID: GncGUID, statementDate: Date, statementBalance: Decimal) {
        guard let book, let account = book.account(with: accountID) else { return }
        let startingBalance = book.balance(of: account, filter: .reconciled).amount

        let items = book.splits(for: account)
            .filter { $0.reconcileState != .reconciled && $0.reconcileState != .voided }
            .filter { ($0.transaction?.datePosted ?? .distantPast) <= statementDate }
            .sorted { ($0.transaction?.datePosted ?? .distantPast) < ($1.transaction?.datePosted ?? .distantPast) }
            .map { split in
                ReconcileItem(
                    id: split.guid,
                    date: split.transaction?.datePosted ?? Date(timeIntervalSince1970: 0),
                    description: split.transaction?.transactionDescription ?? "",
                    amount: split.quantity,
                    isCleared: split.reconcileState == .cleared
                )
            }

        reconcileSession = ReconcileSessionState(
            accountID: accountID,
            accountName: account.name,
            currencyCode: account.commodity.mnemonic,
            fraction: account.commodity.smallestFraction,
            statementDate: statementDate,
            statementBalance: statementBalance,
            startingBalance: startingBalance,
            items: items
        )
    }

    /// Toggles the cleared flag of one item.
    public func toggleReconcileItem(_ id: GncGUID) {
        guard var session = reconcileSession,
              let index = session.items.firstIndex(where: { $0.id == id })
        else { return }
        session.items[index].isCleared.toggle()
        reconcileSession = session
    }

    /// Finishes the session (only when balanced): checked items become
    /// reconciled (`y`) with the statement date; unchecked cleared items revert
    /// to not-reconciled (`FR-REC-02`).
    @discardableResult
    public func finishReconcile() -> Bool {
        guard let book, let session = reconcileSession, session.isBalanced else { return false }
        let splits = session.items.compactMap { item in
            book.split(with: item.id).map { (item: item, split: $0) }
        }
        let touched = Set(splits.compactMap { $0.split.transaction?.guid })
        editing(Array(touched), named: "Reconcile") {
            for (item, split) in splits {
                if item.isCleared {
                    split.reconcileState = .reconciled
                    split.reconcileDate = session.statementDate
                } else if split.reconcileState == .cleared {
                    split.reconcileState = .notReconciled
                }
            }
        }
        reconcileSession = nil
        return true
    }

    /// Abandons the session without changing any splits.
    public func cancelReconcile() {
        reconcileSession = nil
    }
}
