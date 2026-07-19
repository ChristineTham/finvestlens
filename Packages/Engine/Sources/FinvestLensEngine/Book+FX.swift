//
//  Book+FX.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Foreign-exchange and cross-commodity valuation over the price database
/// (`FR-CUR-01`…`FR-CUR-04`).
///
/// Exchange rates are ordinary ``Price`` records between two currency
/// commodities. Rate lookup tries the direct price, then the inverse; security
/// valuation additionally hops through the security's quote currency.
public extension Book {

    /// The direct rate `from`→`to` nearest in time to `date` — the stored price,
    /// or the inverse of the reverse price (GnuCash `direct_price_conversion`).
    private func directRate(from: Commodity, to: Commodity, on date: Date?) -> Decimal? {
        if from == to { return 1 }
        if let direct = nearestPrice(of: from, in: to, on: date) {
            return direct.value
        }
        if let inverse = nearestPrice(of: to, in: from, on: date), inverse.value != 0 {
            return 1 / inverse.value
        }
        return nil
    }

    /// The rate to convert one unit of `from` into `to` near `date` (`nil` when
    /// no path exists). Tries the direct/inverse price, then — like GnuCash's
    /// `indirect_price_conversion` — chains through a common intermediate
    /// currency when no direct rate exists.
    func exchangeRate(from: Commodity, to: Commodity, on date: Date? = nil) -> Decimal? {
        if let direct = directRate(from: from, to: to, on: date) { return direct }
        // Indirect: one hop through any commodity both are priced against.
        let intermediates = pricedAgainst(from).intersection(pricedAgainst(to))
        for mid in intermediates.sorted(by: { $0.mnemonic < $1.mnemonic }) {
            if let r1 = directRate(from: from, to: mid, on: date),
               let r2 = directRate(from: mid, to: to, on: date) {
                return r1 * r2
            }
        }
        return nil
    }

    /// Converts `amount` of `from` into `to`, or `nil` if no rate is available.
    func convert(_ amount: Decimal, from: Commodity, to: Commodity, on date: Date? = nil) -> Decimal? {
        guard let rate = exchangeRate(from: from, to: to, on: date) else { return nil }
        return amount * rate
    }

    /// Records an exchange rate as a price of `from` expressed in `to`.
    @discardableResult
    func setExchangeRate(from: Commodity, to: Commodity, rate: Decimal,
                         date: Date, source: String = "user:xfer") -> Price {
        addPrice(Price(commodity: from, currency: to, date: date, value: rate,
                       source: source, type: "last"))
    }

    /// The most recent price of `commodity` in *any* currency on or before
    /// `date` — used to value a security when no price exists directly in the
    /// report currency.
    func latestPriceInAnyCurrency(of commodity: Commodity, on date: Date? = nil) -> Price? {
        latestPricedAnyCurrency(of: commodity, on: date)
    }

    /// The value of one unit of a security `commodity` in `currency`, priced
    /// directly when possible, otherwise via its quote currency and an FX hop
    /// (`FR-CUR-04`). Returns `nil` when neither path is available.
    func securityUnitValue(_ commodity: Commodity, in currency: Commodity,
                           on date: Date? = nil) -> Decimal? {
        if let direct = nearestPrice(of: commodity, in: currency, on: date) {
            return direct.value
        }
        // Try every currency the security is priced in, chaining to the target —
        // not just its single latest quote (GnuCash considers all quote
        // currencies when finding a common conversion path).
        for quoteCurrency in pricedAgainst(commodity).sorted(by: { $0.mnemonic < $1.mnemonic }) {
            guard let quote = nearestPrice(of: commodity, in: quoteCurrency, on: date),
                  let rate = exchangeRate(from: quoteCurrency, to: currency, on: date) else {
                continue
            }
            return quote.value * rate
        }
        return nil
    }

    /// The balance of `account` converted into `currency` using the rate on or
    /// before `date` (`nil` when the account's commodity cannot be valued).
    ///
    /// Security accounts are valued at market (shares × unit value); currency
    /// accounts are converted at the FX rate.
    func convertedBalance(of account: Account, in currency: Commodity,
                          on date: Date? = nil,
                          filter: BalanceFilter = .all,
                          includingDescendants: Bool = false) -> Decimal? {
        // A subtree can mix currencies and securities, so each account must be
        // valued in its own commodity and the converted amounts summed — summing
        // native quantities first and valuing the total at the parent's single
        // commodity (e.g. treating 100 shares as 100 of the parent currency) is
        // meaningless. Zero-balance nodes contribute nothing and need no price.
        if includingDescendants {
            var total = Decimal(0)
            for node in [account] + account.descendants {
                let native = balance(of: node, filter: filter).amount
                guard native != 0 else { continue }
                guard let value = convertedBalance(of: node, in: currency, on: date,
                                                   filter: filter) else { return nil }
                total += value
            }
            return total
        }
        let native = balance(of: account, filter: filter).amount
        if account.commodity == currency { return native }
        // GnuCash rounds each converted balance to the target currency's fraction
        // before it is summed into a report total (convert_amount_at_date), so
        // multi-account totals are round-then-sum.
        if account.commodity.namespace == .currency {
            return convert(native, from: account.commodity, to: currency, on: date)
                .map { currency.round($0) }
        }
        // Security (or other) commodity: value at market via its unit value.
        guard let unit = securityUnitValue(account.commodity, in: currency, on: date) else { return nil }
        return currency.round(native * unit)
    }
}
