//
//  Commodity.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// How amounts are rounded to a commodity's smallest fraction.
///
/// Maps to `NSDecimalNumber.RoundingMode`. The default for currencies is
/// ``plain`` (round half away from zero), which matches common statement
/// behaviour. Per-commodity choice is an open decision (Architecture OD-4).
public enum MoneyRoundingMode: String, Codable, Sendable, CaseIterable {
    /// Round half away from zero.
    case plain
    /// Round toward zero.
    case down
    /// Round away from zero.
    case up
    /// Banker's rounding (round half to even).
    case bankers

    /// The `NSDecimalNumber` mode realising this mode's *sign-relative*
    /// semantics. `NSDecimalNumber.down`/`.up` round toward −∞/+∞, so for a
    /// negative value they are the opposite of the documented toward-zero /
    /// away-from-zero behaviour; flip them when the value is negative.
    func nsMode(negative: Bool) -> NSDecimalNumber.RoundingMode {
        switch self {
        case .plain: return .plain
        case .bankers: return .bankers
        case .down: return negative ? .up : .down   // toward zero
        case .up: return negative ? .down : .up     // away from zero
        }
    }
}

/// The classifying namespace of a ``Commodity``.
///
/// Mirrors GnuCash's commodity namespaces: currencies live in a single
/// currency namespace; securities live in an exchange/quote namespace.
public enum CommodityNamespace: Hashable, Codable, Sendable {
    /// An ISO 4217 currency.
    case currency
    /// A security (stock/fund) in a named namespace, e.g. `"NASDAQ"`, `"ASX"`.
    case security(String)
    /// Any other user-defined namespace.
    case other(String)
}

/// A currency or security in which accounts are denominated.
///
/// A commodity is identified by its ``namespace`` and ``mnemonic`` (e.g.
/// `.currency` + `"AUD"`, or `.security("ASX")` + `"CBA"`). ``smallestFraction``
/// is the denominator of the smallest representable unit — 100 for cents,
/// 1 for whole units — and drives rounding via ``round(_:)``.
public struct Commodity: Hashable, Codable, Sendable {

    /// Classifying namespace (currency / security / other).
    public var namespace: CommodityNamespace
    /// Short code, e.g. `"AUD"` or `"CBA"`.
    public var mnemonic: String
    /// Human-readable name, e.g. `"Australian Dollar"`.
    public var fullName: String
    /// Denominator of the smallest unit (100 → cents, 1000 → mills, 1 → whole).
    public var smallestFraction: Int
    /// Rounding policy applied when quantising to ``smallestFraction``.
    public var roundingMode: MoneyRoundingMode
    /// Exchange-specific code — ISIN or ticker (GnuCash `cmdty:xcode`).
    public var exchangeCode: String?
    /// Whether GnuCash's online quoting is enabled (`cmdty:get_quotes`).
    public var getQuotes: Bool
    /// GnuCash quote source, e.g. `"yahoo_json"` (`cmdty:quote_source`).
    public var quoteSource: String?
    /// GnuCash quote timezone (`cmdty:quote_tz`); an empty string means the
    /// element was present but empty, which is GnuCash's usual form.
    public var quoteTimezone: String?
    /// Preserved slots (`cmdty:slots`, e.g. `user_symbol`).
    public var kvp: KvpFrame

    public init(
        namespace: CommodityNamespace,
        mnemonic: String,
        fullName: String,
        smallestFraction: Int,
        roundingMode: MoneyRoundingMode = .plain,
        exchangeCode: String? = nil,
        getQuotes: Bool = false,
        quoteSource: String? = nil,
        quoteTimezone: String? = nil,
        kvp: KvpFrame = KvpFrame()
    ) {
        precondition(smallestFraction >= 1, "smallestFraction must be >= 1")
        self.namespace = namespace
        self.mnemonic = mnemonic
        self.fullName = fullName
        self.smallestFraction = smallestFraction
        self.roundingMode = roundingMode
        self.exchangeCode = exchangeCode
        self.getQuotes = getQuotes
        self.quoteSource = quoteSource
        self.quoteTimezone = quoteTimezone
        self.kvp = kvp
    }

    // Custom Codable: the quote/xcode/kvp fields default when absent, so
    // documents saved before they existed still decode.
    private enum CodingKeys: String, CodingKey {
        case namespace, mnemonic, fullName, smallestFraction, roundingMode
        case exchangeCode, getQuotes, quoteSource, quoteTimezone, kvp
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        namespace = try container.decode(CommodityNamespace.self, forKey: .namespace)
        mnemonic = try container.decode(String.self, forKey: .mnemonic)
        fullName = try container.decode(String.self, forKey: .fullName)
        smallestFraction = try container.decode(Int.self, forKey: .smallestFraction)
        roundingMode = try container.decodeIfPresent(MoneyRoundingMode.self, forKey: .roundingMode) ?? .plain
        exchangeCode = try container.decodeIfPresent(String.self, forKey: .exchangeCode)
        getQuotes = try container.decodeIfPresent(Bool.self, forKey: .getQuotes) ?? false
        quoteSource = try container.decodeIfPresent(String.self, forKey: .quoteSource)
        quoteTimezone = try container.decodeIfPresent(String.self, forKey: .quoteTimezone)
        kvp = try container.decodeIfPresent(KvpFrame.self, forKey: .kvp) ?? KvpFrame()
    }

    /// Rounds `value` to the nearest multiple of `1 / smallestFraction`
    /// using this commodity's rounding mode.
    public func round(_ value: Decimal) -> Decimal {
        let fraction = Decimal(smallestFraction)
        var scaled = value * fraction
        var result = Decimal()
        NSDecimalRound(&result, &scaled, 0, roundingMode.nsMode(negative: value < 0))
        return result / fraction
    }

    // A commodity is identified by its namespace + mnemonic (as in GnuCash);
    // the descriptive fields (name, fraction, rounding) are not part of identity.
    public static func == (lhs: Commodity, rhs: Commodity) -> Bool {
        lhs.namespace == rhs.namespace && lhs.mnemonic == rhs.mnemonic
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(namespace)
        hasher.combine(mnemonic)
    }

    /// The number of decimal places implied by ``smallestFraction`` when it is
    /// a power of ten (e.g. 100 → 2). `nil` for non-decimal fractions.
    public var fractionDigits: Int? {
        var f = smallestFraction
        guard f >= 1 else { return nil }
        var digits = 0
        while f > 1 {
            guard f % 10 == 0 else { return nil }
            f /= 10
            digits += 1
        }
        return digits
    }
}

public extension Commodity {

    /// Convenience constructor for an ISO 4217 currency.
    ///
    /// - Parameters:
    ///   - code: ISO currency code, e.g. `"AUD"`.
    ///   - fractionDigits: minor-unit digits (2 for most currencies, 0 for JPY).
    ///   - name: optional full name (defaults to `code`).
    static func currency(
        _ code: String,
        fractionDigits: Int = 2,
        name: String? = nil,
        roundingMode: MoneyRoundingMode = .plain
    ) -> Commodity {
        var denominator = 1
        for _ in 0..<max(0, fractionDigits) { denominator *= 10 }
        return Commodity(
            namespace: .currency,
            mnemonic: code,
            fullName: name ?? code,
            smallestFraction: denominator,
            roundingMode: roundingMode
        )
    }

    /// Australian Dollar.
    static let aud = Commodity.currency("AUD", name: "Australian Dollar")
    /// US Dollar.
    static let usd = Commodity.currency("USD", name: "US Dollar")
    /// Euro.
    static let eur = Commodity.currency("EUR", name: "Euro")
}
