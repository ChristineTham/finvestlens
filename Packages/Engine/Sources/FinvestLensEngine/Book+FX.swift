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

    /// The rate to convert one unit of `from` into `to` on or before `date`
    /// (`nil` when no path exists in the price DB).
    func exchangeRate(from: Commodity, to: Commodity, on date: Date? = nil) -> Decimal? {
        if from == to { return 1 }
        if let direct = latestPrice(of: from, in: to, on: date) {
            return direct.value
        }
        if let inverse = latestPrice(of: to, in: from, on: date), inverse.value != 0 {
            return 1 / inverse.value
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
        if let direct = latestPrice(of: commodity, in: currency, on: date) {
            return direct.value
        }
        guard let quote = latestPriceInAnyCurrency(of: commodity, on: date),
              let rate = exchangeRate(from: quote.currency, to: currency, on: date) else {
            return nil
        }
        return quote.value * rate
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
        let native = balance(of: account, filter: filter,
                             includingDescendants: includingDescendants).amount
        if account.commodity == currency { return native }
        if account.commodity.namespace == .currency {
            return convert(native, from: account.commodity, to: currency, on: date)
        }
        // Security (or other) commodity: value at market via its unit value.
        guard let unit = securityUnitValue(account.commodity, in: currency, on: date) else { return nil }
        return native * unit
    }
}
