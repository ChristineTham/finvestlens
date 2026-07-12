//
//  Money.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// An exact monetary amount in a specific ``Commodity``.
///
/// FinvestLens uses Swift-native `Foundation.Decimal` for money (Architecture
/// ADR-1): base-10, 38 significant digits, free of binary floating-point error.
/// Bit-for-bit parity with GnuCash's rational `gnc_numeric` is a non-goal —
/// small rounding differences are acceptable.
///
/// Arithmetic is only defined between amounts of the **same commodity**; mixing
/// commodities is a programmer error and traps. Cross-currency conversion is a
/// higher-level concern (prices / exchange rates), not an operator.
public struct Money: Hashable, Codable, Sendable {

    /// The raw (un-rounded) amount.
    public var amount: Decimal
    /// The commodity this amount is denominated in.
    public var commodity: Commodity

    public init(_ amount: Decimal, _ commodity: Commodity) {
        self.amount = amount
        self.commodity = commodity
    }

    /// Zero in the given commodity.
    public static func zero(_ commodity: Commodity) -> Money {
        Money(0, commodity)
    }

    /// The amount rounded to the commodity's smallest fraction.
    public var rounded: Money {
        Money(commodity.round(amount), commodity)
    }

    /// `true` if the amount rounds to zero at the commodity's fraction.
    ///
    /// Uses the rounded value so residuals smaller than one minor unit count
    /// as zero — the tolerance the double-entry balance check relies on.
    public var isZero: Bool {
        commodity.round(amount) == 0
    }

    public var isNegative: Bool { rounded.amount < 0 }
    public var isPositive: Bool { rounded.amount > 0 }

    /// A locale-aware currency string (best-effort; presentation may override).
    public func formatted(locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = commodity.mnemonic
        if let digits = commodity.fractionDigits {
            formatter.minimumFractionDigits = digits
            formatter.maximumFractionDigits = digits
        }
        return formatter.string(from: NSDecimalNumber(decimal: rounded.amount))
            ?? "\(rounded.amount) \(commodity.mnemonic)"
    }
}

// MARK: - Arithmetic (same-commodity only)

public extension Money {

    static prefix func - (value: Money) -> Money {
        Money(-value.amount, value.commodity)
    }

    static func + (lhs: Money, rhs: Money) -> Money {
        precondition(
            lhs.commodity == rhs.commodity,
            "Cannot add \(lhs.commodity.mnemonic) and \(rhs.commodity.mnemonic)"
        )
        return Money(lhs.amount + rhs.amount, lhs.commodity)
    }

    static func - (lhs: Money, rhs: Money) -> Money {
        precondition(
            lhs.commodity == rhs.commodity,
            "Cannot subtract \(rhs.commodity.mnemonic) from \(lhs.commodity.mnemonic)"
        )
        return Money(lhs.amount - rhs.amount, lhs.commodity)
    }

    static func += (lhs: inout Money, rhs: Money) { lhs = lhs + rhs }
    static func -= (lhs: inout Money, rhs: Money) { lhs = lhs - rhs }

    /// Scales the amount by a plain decimal factor (e.g. a share price or rate),
    /// keeping the same commodity. The result is **not** auto-rounded.
    static func * (lhs: Money, factor: Decimal) -> Money {
        Money(lhs.amount * factor, lhs.commodity)
    }

    /// Adds two amounts if they share a commodity, else returns `nil`.
    /// A non-trapping alternative to `+` for mixed-commodity contexts.
    func adding(_ other: Money) -> Money? {
        guard commodity == other.commodity else { return nil }
        return Money(amount + other.amount, commodity)
    }
}

// MARK: - Comparison (same-commodity only)

extension Money: Comparable {
    public static func < (lhs: Money, rhs: Money) -> Bool {
        precondition(
            lhs.commodity == rhs.commodity,
            "Cannot compare \(lhs.commodity.mnemonic) and \(rhs.commodity.mnemonic)"
        )
        return lhs.amount < rhs.amount
    }
}
