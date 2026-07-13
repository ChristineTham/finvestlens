//
//  Transaction.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// A dated economic event composed of two or more balancing ``Split``s.
///
/// The core double-entry invariant (`FR-ENG-06`) is that the sum of split
/// ``Split/value``s — all in ``currency`` — is zero. Because money uses
/// `Decimal`, "zero" means *rounds to zero at the currency's fraction*, so
/// residuals below one minor unit are tolerated (Architecture ADR-1).
public final class Transaction {

    /// Stable identity, preserved across GnuCash round-trips.
    public let guid: GncGUID

    /// The currency all split values are expressed in.
    public var currency: Commodity

    /// The economic date of the transaction (when it is considered to occur).
    public var datePosted: Date
    /// When the transaction was entered into the book.
    public var dateEntered: Date

    public var number: String
    public var transactionDescription: String
    public var notes: String

    /// Preserved key-value slots.
    public var kvp: KvpFrame

    /// The legs of the transaction, owned strongly.
    public private(set) var splits: [Split]

    /// Free-form tags, stored in a preserved KVP slot so they survive save and
    /// GnuCash round-trips (`FR-TAG-01`).
    public var tags: [String] {
        get {
            guard case let .list(values)? = kvp[Self.tagsKey] else { return [] }
            return values.compactMap { if case let .string(tag) = $0 { return tag } else { return nil } }
        }
        set {
            let cleaned = newValue
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            kvp[Self.tagsKey] = cleaned.isEmpty ? nil : .list(cleaned.map { .string($0) })
        }
    }
    private static let tagsKey = "finvestlens/tags"

    /// The date the transaction appeared on a bank statement, kept when
    /// ``datePosted`` is adjusted to the true economic date (e.g. an invoice
    /// date — banks often post a few days later). Stored in a preserved KVP
    /// slot so it survives save; import matching checks both dates so a
    /// re-imported statement still recognises the transaction (`FR-AI-07`).
    ///
    /// Not part of GnuCash's schema: GnuCash sees only `datePosted`, but the
    /// slot rides along in XML export/import (as `finvestlens/statement-date`)
    /// like any other preserved KVP, so it survives a GnuCash round-trip.
    public var statementDate: Date? {
        get {
            guard case let .date(date)? = kvp[Self.statementDateKey] else { return nil }
            return date
        }
        set {
            kvp[Self.statementDateKey] = newValue.map { .date($0) }
        }
    }
    private static let statementDateKey = "finvestlens/statement-date"

    /// Link to an attached source document — an invoice or dividend statement
    /// PDF (`FR-AI-08`). Uses GnuCash's transaction-association slot key
    /// (`assoc_uri`) so links round-trip with GnuCash: either an absolute
    /// `file://` URI, or a path relative to the user's document folder
    /// (GnuCash calls it the "path head").
    public var documentLink: String? {
        get {
            guard case let .string(link)? = kvp[Self.documentLinkKey], !link.isEmpty else { return nil }
            return link
        }
        set {
            let cleaned = newValue?.trimmingCharacters(in: .whitespaces)
            kvp[Self.documentLinkKey] = (cleaned?.isEmpty ?? true) ? nil : .string(cleaned!)
        }
    }
    private static let documentLinkKey = "assoc_uri"

    public init(
        guid: GncGUID = .random(),
        currency: Commodity,
        datePosted: Date,
        dateEntered: Date? = nil,
        number: String = "",
        description: String = "",
        notes: String = "",
        kvp: KvpFrame = KvpFrame()
    ) {
        self.guid = guid
        self.currency = currency
        self.datePosted = datePosted
        self.dateEntered = dateEntered ?? datePosted
        self.number = number
        self.transactionDescription = description
        self.notes = notes
        self.kvp = kvp
        self.splits = []
    }

    // MARK: Splits

    /// Adds a split to the transaction and links it back.
    @discardableResult
    public func addSplit(_ split: Split) -> Split {
        split.transaction = self
        splits.append(split)
        return split
    }

    /// Convenience: create and add a split posting `value` to `account`.
    @discardableResult
    public func addSplit(
        account: Account,
        value: Decimal,
        quantity: Decimal? = nil,
        memo: String = ""
    ) -> Split {
        addSplit(Split(account: account, value: value, quantity: quantity, memo: memo))
    }

    /// Removes a split from the transaction.
    public func removeSplit(_ split: Split) {
        guard split.transaction === self else { return }
        splits.removeAll { $0 === split }
        split.transaction = nil
    }

    // MARK: Balancing

    /// The signed sum of split values, in the transaction currency.
    /// A balanced transaction has an imbalance that rounds to zero.
    public var imbalance: Money {
        let total = splits.reduce(Decimal(0)) { $0 + $1.value }
        return Money(total, currency)
    }

    /// `true` when the transaction satisfies the double-entry invariant.
    public var isBalanced: Bool {
        imbalance.isZero
    }
}

extension Transaction: Identifiable {
    public var id: GncGUID { guid }
}

extension Transaction: Equatable, Hashable {
    public static func == (lhs: Transaction, rhs: Transaction) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
