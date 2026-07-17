//
//  Lot.swift
//  FinvestLens — Engine
//
//  A lot groups the splits that settle against one another in an account
//  (GnuCash `GncLot`). Business A/R and A/P rely on it: an invoice's posting
//  split and its later payment splits share a lot, so the lot's balance is the
//  amount still outstanding, and aging walks the account's open lots.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// A collection of splits in one account that offset each other over time.
public final class Lot: Identifiable, @unchecked Sendable {
    public let guid: GncGUID
    /// The account the lot lives in (an A/R or A/P account for business lots).
    public weak var account: Account?
    public var title: String
    public var notes: String
    /// The splits belonging to the lot, in the order added.
    public private(set) var splits: [Split]
    /// A lot is closed once fully settled; kept even at zero balance so history
    /// survives, matching GnuCash.
    public var isClosed: Bool
    public var kvp: KvpFrame

    public init(guid: GncGUID = .random(), account: Account? = nil,
                title: String = "", notes: String = "", isClosed: Bool = false,
                kvp: KvpFrame = KvpFrame()) {
        self.guid = guid; self.account = account; self.title = title
        self.notes = notes; self.splits = []; self.isClosed = isClosed; self.kvp = kvp
    }

    /// Adds a split to the lot (idempotent by identity).
    public func add(_ split: Split) {
        guard !splits.contains(where: { $0 === split }) else { return }
        splits.append(split)
    }

    public func remove(_ split: Split) {
        splits.removeAll { $0 === split }
    }

    /// The net value of the lot's splits — the amount still outstanding for a
    /// business lot (positive on an A/R lot means the customer still owes).
    public var balance: Decimal {
        splits.reduce(Decimal(0)) { $0 + $1.value }
    }

    public var isEmpty: Bool { splits.isEmpty }
}
