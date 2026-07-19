//
//  StagedTransaction.swift
//  FinvestLens — Interchange
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// A normalized transaction produced by a bank-file importer, before it is
/// matched and posted into the book.
///
/// `amount` is signed from the perspective of the account being imported into:
/// positive is money in, negative is money out. All importers (CSV/QIF/OFX)
/// emit this shape, which then flows into the shared ``ImportMatcher``
/// (Architecture §5.8a).
public struct StagedTransaction: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var date: Date
    public var amount: Decimal
    public var payee: String
    public var memo: String
    public var reference: String
    /// Source category label (QIF `L`, OFX has none) — a hint for matching.
    public var category: String
    /// Investment detail when this row is a security transaction (QIF
    /// `!Type:Invst`, OFX `<INVBUY>`/`<INVSELL>`/…). `nil` for ordinary cash
    /// rows, which flow through the cash ``ImportMatcher`` as before.
    public var investment: InvestmentDetail?
    /// Sub-splits when the record distributes one cash movement across several
    /// categories (QIF `S`/`E`/`$` lines). Empty for a plain two-legged row.
    public var splits: [StagedSplit]

    public init(id: UUID = UUID(), date: Date, amount: Decimal, payee: String = "",
                memo: String = "", reference: String = "", category: String = "",
                investment: InvestmentDetail? = nil, splits: [StagedSplit] = []) {
        self.id = id
        self.date = date
        self.amount = amount
        self.payee = payee
        self.memo = memo
        self.reference = reference
        self.category = category
        self.investment = investment
        self.splits = splits
    }

    /// Whether this staged row is a security transaction rather than cash.
    public var isInvestment: Bool { investment != nil }
    /// Whether this row distributes its amount across more than one category.
    public var isSplit: Bool { splits.count > 1 }
}

/// One category leg of a split cash record (QIF `S`/`E`/`$`).
public struct StagedSplit: Hashable, Sendable {
    /// The category / account name this leg books to (QIF `S`).
    public var category: String
    /// The leg's amount, signed like the parent (QIF `$`).
    public var amount: Decimal
    public var memo: String

    public init(category: String, amount: Decimal, memo: String = "") {
        self.category = category
        self.amount = amount
        self.memo = memo
    }
}

/// The security-transaction fields a QIF `!Type:Invst` record or an OFX
/// investment statement carries (`FR-XIO-01`/`FR-XIO-02`).
public struct InvestmentDetail: Hashable, Sendable {

    /// The kinds of security action an import can express, normalised across
    /// QIF action codes and OFX transaction types.
    public enum Action: String, Hashable, Sendable {
        case buy, sell, dividend, reinvestDividend, other
    }

    public var action: Action
    /// The security's name or ticker as written in the file (resolved to a
    /// commodity/account at import time).
    public var security: String
    /// Shares transacted (always positive; the action carries direction).
    public var quantity: Decimal
    public var pricePerShare: Decimal
    public var commission: Decimal

    public init(action: Action, security: String = "", quantity: Decimal = 0,
                pricePerShare: Decimal = 0, commission: Decimal = 0) {
        self.action = action
        self.security = security
        self.quantity = quantity
        self.pricePerShare = pricePerShare
        self.commission = commission
    }
}

/// Shared helpers for importers.
enum ImportParsing {

    /// Parses a monetary string, tolerating currency symbols, thousands
    /// separators, spaces, and parenthesised negatives.
    static func amount(_ raw: String) -> Decimal? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var negative = false
        if text.hasPrefix("(") && text.hasSuffix(")") {
            negative = true
            text = String(text.dropFirst().dropLast())
        }
        // A trailing minus ("500.00-") denotes a debit in many accounting/German
        // exports; `Decimal(string:)` only honours a *leading* sign and would
        // silently read it as +500, flipping a debit into a credit.
        text = text.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("-") {
            negative = true
            text = String(text.dropLast())
        }
        text = text.filter { $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }
        guard let value = Decimal(string: text) else { return nil }
        return negative ? -value : value
    }
}
