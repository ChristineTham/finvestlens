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

    public init(id: UUID = UUID(), date: Date, amount: Decimal, payee: String = "",
                memo: String = "", reference: String = "", category: String = "") {
        self.id = id
        self.date = date
        self.amount = amount
        self.payee = payee
        self.memo = memo
        self.reference = reference
        self.category = category
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
        text = text.filter { $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }
        guard let value = Decimal(string: text) else { return nil }
        return negative ? -value : value
    }
}
