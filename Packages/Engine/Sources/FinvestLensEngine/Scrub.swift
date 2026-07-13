//
//  Scrub.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Integrity checks and repairs over a ``Book``.
///
/// Ports the intent of GnuCash's `Scrub*` routines: find and (optionally) fix
/// structural problems such as unbalanced transactions and orphaned splits.
/// Run after import (`FR-IMP-08`) and before committing edits (`FR-ENG-06`).
/// All logic is pure model manipulation — no UI.
public enum Scrub {

    /// A structural problem found in a book.
    public enum Issue: Equatable, Sendable, CustomStringConvertible {
        /// A transaction whose splits do not sum to zero.
        case unbalancedTransaction(GncGUID, imbalance: Decimal)
        /// A split with no account assigned.
        case orphanSplit(GncGUID)
        /// A transaction with fewer than two splits.
        case degenerateTransaction(GncGUID, splitCount: Int)

        public var description: String {
            switch self {
            case let .unbalancedTransaction(guid, imbalance):
                return "Unbalanced transaction \(guid) (imbalance \(imbalance))"
            case let .orphanSplit(guid):
                return "Orphan split \(guid) (no account)"
            case let .degenerateTransaction(guid, count):
                return "Transaction \(guid) has \(count) split(s)"
            }
        }
    }

    /// Scans the book and returns all issues found (does not mutate).
    public static func check(_ book: Book) -> [Issue] {
        var issues: [Issue] = []
        for transaction in book.transactions {
            if transaction.splits.count < 2 {
                // A lone zero-value split is GnuCash's "no opening balance"
                // stub — balanced by definition, not a structural problem.
                let isZeroStub = transaction.splits.count == 1
                    && transaction.splits[0].value == 0
                    && transaction.splits[0].quantity == 0
                if !isZeroStub {
                    issues.append(.degenerateTransaction(transaction.guid, splitCount: transaction.splits.count))
                }
            }
            if !transaction.isBalanced {
                issues.append(.unbalancedTransaction(
                    transaction.guid,
                    imbalance: transaction.imbalance.rounded.amount
                ))
            }
            for split in transaction.splits where split.account == nil {
                issues.append(.orphanSplit(split.guid))
            }
        }
        return issues
    }

    /// `true` when the book has no structural issues.
    public static func isClean(_ book: Book) -> Bool {
        check(book).isEmpty
    }

    // MARK: Repair

    /// Balances every unbalanced transaction by posting the residual to an
    /// `Imbalance-<CUR>` account (created under the root if needed), matching
    /// GnuCash's imbalance-scrub behaviour.
    ///
    /// - Returns: the transactions that were adjusted.
    @discardableResult
    public static func balanceTransactions(in book: Book) -> [Transaction] {
        var adjusted: [Transaction] = []
        for transaction in book.transactions where !transaction.isBalanced {
            let residual = transaction.imbalance.rounded.amount
            guard residual != 0 else { continue }
            let account = imbalanceAccount(for: transaction.currency, in: book)
            // Post the negative of the residual so the transaction sums to zero.
            transaction.addSplit(account: account, value: -residual)
            adjusted.append(transaction)
        }
        return adjusted
    }

    /// Finds or creates the `Imbalance-<CUR>` account for a currency.
    public static func imbalanceAccount(for currency: Commodity, in book: Book) -> Account {
        let name = "Imbalance-\(currency.mnemonic)"
        if let existing = book.accounts.first(where: { $0.name == name && $0.commodity == currency }) {
            return existing
        }
        let account = Account(name: name, type: .bank, commodity: currency)
        book.addAccount(account)
        return account
    }
}
