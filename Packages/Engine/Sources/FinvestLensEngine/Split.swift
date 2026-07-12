//
//  Split.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// One leg of a ``Transaction``: an amount posted to a single ``Account``.
///
/// A split carries two figures, mirroring GnuCash:
/// - ``value`` is expressed in the **transaction's** currency and is what the
///   double-entry balance check sums to zero.
/// - ``quantity`` is expressed in the **account's** commodity. For same-currency
///   postings the two are equal; they differ for multi-currency transactions and
///   for security accounts (where quantity is a number of shares).
public final class Split {

    /// Stable identity, preserved across GnuCash round-trips.
    public let guid: GncGUID

    /// The owning transaction. Weak to keep ownership acyclic
    /// (`Transaction` owns its splits strongly).
    public internal(set) weak var transaction: Transaction?

    /// The account this leg posts to.
    public var account: Account?

    /// Amount in the transaction's currency (drives balancing).
    public var value: Decimal
    /// Amount in the account's commodity (shares, or foreign-currency units).
    public var quantity: Decimal

    public var reconcileState: ReconcileState
    public var reconcileDate: Date?
    public var memo: String
    public var action: String

    /// Preserved key-value slots.
    public var kvp: KvpFrame

    public init(
        guid: GncGUID = .random(),
        account: Account? = nil,
        value: Decimal,
        quantity: Decimal? = nil,
        reconcileState: ReconcileState = .notReconciled,
        reconcileDate: Date? = nil,
        memo: String = "",
        action: String = "",
        kvp: KvpFrame = KvpFrame()
    ) {
        self.guid = guid
        self.account = account
        self.value = value
        // Default quantity to value (correct for same-currency postings).
        self.quantity = quantity ?? value
        self.reconcileState = reconcileState
        self.reconcileDate = reconcileDate
        self.memo = memo
        self.action = action
        self.kvp = kvp
    }

    /// The split's value as ``Money`` in the transaction currency, if attached.
    public var valueMoney: Money? {
        guard let currency = transaction?.currency else { return nil }
        return Money(value, currency)
    }

    /// The split's quantity as ``Money`` in the account commodity, if attached.
    public var quantityMoney: Money? {
        guard let commodity = account?.commodity else { return nil }
        return Money(quantity, commodity)
    }
}

extension Split: Identifiable {
    public var id: GncGUID { guid }
}

extension Split: Equatable, Hashable {
    public static func == (lhs: Split, rhs: Split) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
