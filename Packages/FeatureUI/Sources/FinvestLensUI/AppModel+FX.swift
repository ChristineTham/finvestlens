//
//  AppModel+FX.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Foreign-amount conversion for the transaction editor (`FR-CUR-01…04`).
//
//  GnuCash's data model is kept — rates are ordinary price-DB records, splits
//  carry value/quantity — but the workflow is automated: the rate auto-fills
//  from the book, can be fetched live (Yahoo `MYRAUD=X`, keyless), and when
//  the user knows both amounts the implied rate is derived and stored, so
//  every conversion teaches the price DB.
//

import Foundation
import FinvestLensEngine
import FinvestLensQuotes

@MainActor
extension AppModel {

    /// Currency codes offered by the converter: the book's currencies first,
    /// then common ISO codes.
    public var fxCurrencyCodes: [String] {
        let inBook = (book?.commodities ?? [])
            .filter { $0.namespace == .currency }
            .map(\.mnemonic)
        let common = ["USD", "EUR", "GBP", "JPY", "NZD", "SGD", "MYR", "HKD",
                      "CNY", "THB", "IDR", "INR", "CHF", "CAD", "KRW", "VND"]
        var seen = Set<String>()
        return (inBook + common).filter { $0 != reportCurrency.mnemonic && seen.insert($0).inserted }
    }

    /// The book's commodity for `code`, or a fresh currency commodity. Reusing
    /// the stored instance matters: `Commodity` equality spans all fields, and
    /// price-index buckets key on it.
    func currencyCommodity(_ code: String) -> Commodity {
        book?.commodities.first { $0.namespace == .currency && $0.mnemonic == code }
            ?? Commodity(namespace: .currency, mnemonic: code, fullName: code, smallestFraction: 100)
    }

    /// The stored rate: one unit of `code` in the report currency, nearest to
    /// `date` (price DB — direct, inverse, or one indirect hop).
    public func storedFxRate(code: String, on date: Date? = nil) -> Decimal? {
        guard let book else { return nil }
        return book.exchangeRate(from: currencyCommodity(code), to: reportCurrency, on: date)
    }

    /// Fetches a live rate for one unit of `code` in the report currency
    /// (Yahoo `MYRAUD=X`, keyless) and stores it in the price DB so future
    /// lookups — and reports — can use it. Throws with the provider's reason
    /// so the UI can say why a fetch failed rather than doing nothing.
    public func fetchLiveFxRate(code: String) async throws -> Decimal {
        let foreign = currencyCommodity(code)
        let symbol = "\(code)\(reportCurrency.mnemonic)=X"
        let service = QuoteService(keys: apiKeys, http: quoteHTTP)
        let price = try await service.latestPrice(
            for: foreign, in: reportCurrency, using: .yahoo, symbolOverride: symbol)
        guard price.value > 0 else {
            throw QuoteError.noData
        }
        editingWholeBook(named: "Fetch Exchange Rate") {
            book?.addPrice(price)
        }
        return price.value
    }

    /// Records a user-confirmed rate (e.g. the implied rate of a purchase whose
    /// foreign and local amounts are both known) into the price DB.
    public func recordFxRate(code: String, rate: Decimal, date: Date) {
        guard rate > 0 else { return }
        editingWholeBook(named: "Record Exchange Rate") {
            book?.setExchangeRate(from: currencyCommodity(code), to: reportCurrency,
                                  rate: rate, date: date, source: "user:fx-editor")
        }
    }
}
