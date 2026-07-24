//
//  AppModel+Prices.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensReports
import FinvestLensInterchange

/// A row in the price editor.
public struct PriceRow: Identifiable, Hashable, Sendable {
    public let id: GncGUID
    public var symbol: String
    public var currencyCode: String
    public var date: Date
    public var value: Decimal
}

@MainActor
extension AppModel {

    /// Commodities that are held in a security account (candidates to price).
    public var securityCommodities: [Commodity] {
        guard let book else { return [] }
        var seen = Set<String>()
        var result: [Commodity] = []
        for account in book.accounts where account.type.isSecurityType {
            let key = "\(account.commodity.namespace)|\(account.commodity.mnemonic)"
            if seen.insert(key).inserted { result.append(account.commodity) }
        }
        return result
    }

    /// Adds a price to the database (`FR-INV-02`).
    public func addPrice(commodity: Commodity, currency: Commodity, date: Date, value: Decimal) {
        guard let book else { return }
        editingPrices(named: "Add Price") {
            book.addPrice(Price(commodity: commodity, currency: currency, date: date, value: value))
        }
    }

    public func deletePrice(_ id: GncGUID) {
        guard let book else { return }
        editingPrices(named: "Delete Price") {
            book.removePrice(id)
        }
    }

    /// The outcome of a CSV price import (`FR-XIO-03`).
    public struct PriceImportOutcome: Sendable {
        public var imported = 0
        /// Symbols in the file that matched no known commodity (skipped).
        public var unmatchedSymbols: [String] = []
        /// True when the file's header couldn't be recognised.
        public var unrecognisedFormat = false
    }

    /// Imports commodity prices from a CSV file (`FR-XIO-03`), auto-detecting
    /// the columns from the header. A symbol is resolved against the book's
    /// commodities by mnemonic; the currency column (if any) is resolved by
    /// mnemonic, otherwise the base currency is assumed. Unknown symbols are
    /// reported, not invented.
    @discardableResult
    public func importPrices(csv text: String) -> PriceImportOutcome {
        var outcome = PriceImportOutcome()
        guard let book else { return outcome }
        guard let staged = CSVPriceImporter.parseAutodetect(text) else {
            outcome.unrecognisedFormat = true
            return outcome
        }

        // Resolve commodities/currencies by mnemonic (case-insensitive).
        var byMnemonic: [String: Commodity] = [:]
        for c in book.commodities { byMnemonic[c.mnemonic.uppercased()] = c }
        let base = reportCurrency

        var toAdd: [Price] = []
        var unmatched = Set<String>()
        for row in staged {
            guard let commodity = byMnemonic[row.commoditySymbol.uppercased()] else {
                unmatched.insert(row.commoditySymbol); continue
            }
            let currency = row.currencyCode.isEmpty
                ? base
                : (byMnemonic[row.currencyCode.uppercased()] ?? base)
            toAdd.append(Price(commodity: commodity, currency: currency, date: row.date,
                               value: row.value, source: "user:price"))
        }

        if !toAdd.isEmpty {
            editingPrices(named: "Import Prices") {
                for price in toAdd { book.addPrice(price) }
            }
        }
        outcome.imported = toAdd.count
        outcome.unmatchedSymbols = unmatched.sorted()
        return outcome
    }

    /// The portfolio valuation over security accounts (`FR-RPT-02`).
    public func portfolio(asOf: Date = Date()) -> Portfolio? {
        guard let book, !securityCommodities.isEmpty else { return nil }
        return cachedReport("pf:\(asOf.timeIntervalSinceReferenceDate)") {
            FinancialReports.portfolio(book, currency: reportCurrency, asOf: asOf)
        }
    }

    /// The market unit price of the security in `accountID`, in the report
    /// currency, nearest in time to `date` — the price series that drives a
    /// holding's return regardless of how many shares were held then.
    public func securityUnitPrice(accountID: GncGUID, on date: Date) -> Decimal? {
        guard let book, let account = book.account(with: accountID) else { return nil }
        return book.securityUnitValue(account.commodity, in: reportCurrency, on: date)
    }

    /// Realised capital gains and open lots under the selected cost-basis
    /// method (`FR-RPT-03`).
    public func capitalGains(from: Date = .distantPast, to: Date = .distantFuture) -> CapitalGainsReport? {
        guard let book, !securityCommodities.isEmpty else { return nil }
        return cachedReport("cg:\(from.timeIntervalSinceReferenceDate):\(to.timeIntervalSinceReferenceDate):\(costBasisMethod.rawValue):\(feeTreatment.rawValue)") {
            FinancialReports.capitalGains(book, currency: reportCurrency,
                                          from: from, to: to, method: costBasisMethod,
                                          feeTreatment: feeTreatment)
        }
    }

    /// The advanced portfolio (cost basis, avg cost, unrealized/realized gain,
    /// allocation) under the selected cost-basis method (`FR-RPT-02a`).
    public func advancedPortfolio(asOf: Date = Date()) -> AdvancedPortfolio? {
        guard let book, !securityCommodities.isEmpty else { return nil }
        // "As of now" quantises to end-of-day: a live Date() key would defeat
        // the memo (one entry per call), and holdings don't move mid-day here.
        let cap = min(asOf, Self.endOfToday())
        return cachedReport("apf:\(cap.timeIntervalSinceReferenceDate):\(costBasisMethod.rawValue):\(feeTreatment.rawValue)") {
            FinancialReports.advancedPortfolio(book, currency: reportCurrency,
                                               asOf: cap, method: costBasisMethod,
                                               feeTreatment: feeTreatment)
        }
    }

    /// Every open tax lot valued at the latest price, under the selected
    /// cost-basis method (`FR-RPT-02`, Investment Lots).
    public func investmentLots(asOf: Date = Date()) -> [LotDetail] {
        guard let book, !securityCommodities.isEmpty else { return [] }
        let cap = min(asOf, Self.endOfToday())
        return cachedReport("lots:\(cap.timeIntervalSinceReferenceDate):\(costBasisMethod.rawValue):\(feeTreatment.rawValue)") {
            FinancialReports.investmentLots(book, currency: reportCurrency,
                                            asOf: cap, method: costBasisMethod,
                                            feeTreatment: feeTreatment)
        } ?? []
    }

    /// End of the current day — the stable stand-in for "now" in report memo
    /// keys (a raw `Date()` would make every call a cache miss).
    static func endOfToday() -> Date {
        Calendar.current.startOfDay(for: Date()).addingTimeInterval(24 * 3600)
    }

    /// Securities that have at least one recorded price (candidates for the
    /// price-history chart).
    public var securitiesWithPriceHistory: [Commodity] {
        guard let book else { return [] }
        var seen = Set<String>()
        var result: [Commodity] = []
        for price in book.prices where price.commodity.namespace != .currency {
            if seen.insert(price.commodity.mnemonic).inserted { result.append(price.commodity) }
        }
        return result.sorted { $0.mnemonic < $1.mnemonic }
    }

    /// The recorded price series for `commodity`, oldest first.
    public func priceHistory(for commodity: Commodity) -> [PricePoint] {
        guard let book else { return [] }
        return book.prices
            .filter { $0.commodity == commodity }
            .sorted { $0.date < $1.date }
            .map { PricePoint(date: $0.date, value: $0.value, currencyCode: $0.currency.mnemonic) }
    }
}

/// One point in a security's price-history chart.
public struct PricePoint: Identifiable, Hashable, Sendable {
    public var id: Date { date }
    public var date: Date
    public var value: Decimal
    public var currencyCode: String
}
