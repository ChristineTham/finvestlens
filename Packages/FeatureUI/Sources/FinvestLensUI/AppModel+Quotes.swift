//
//  AppModel+Quotes.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensQuotes

/// Progress/result of a quote fetch, surfaced to the Quotes UI.
public enum QuoteFetchStatus: Equatable, Sendable {
    case idle
    /// A fetch is in progress; the string describes what.
    case fetching(String)
    /// A fetch finished, adding `count` prices.
    case success(Int)
    /// A fetch failed with a user-facing message.
    case failure(String)
}

@MainActor
extension AppModel {

    // MARK: API keys

    /// The stored API key for `kind`, if any.
    public func apiKey(for kind: QuoteProviderKind) -> String? {
        apiKeys.key(for: kind)
    }

    /// Stores (or clears) the API key for `kind`.
    public func setAPIKey(_ key: String?, for kind: QuoteProviderKind) {
        try? apiKeys.setKey(key, for: kind)
    }

    /// Providers that are ready to use: Yahoo always, keyed providers once a
    /// key is stored.
    public var availableProviders: [QuoteProviderKind] {
        QuoteProviderKind.allCases.filter { !$0.requiresAPIKey || (apiKeys.key(for: $0)?.isEmpty == false) }
    }

    // MARK: Symbol overrides

    private func symbolKey(_ commodity: Commodity) -> String {
        "\(commodity.namespace)|\(commodity.mnemonic)"
    }

    /// The quote ticker override for `commodity`, if set.
    public func quoteSymbol(for commodity: Commodity) -> String? {
        quoteSymbols[symbolKey(commodity)]
    }

    /// Sets or clears the quote ticker override for `commodity`.
    public func setQuoteSymbol(_ symbol: String?, for commodity: Commodity) {
        let key = symbolKey(commodity)
        if let symbol, !symbol.trimmingCharacters(in: .whitespaces).isEmpty {
            quoteSymbols[key] = symbol.trimmingCharacters(in: .whitespaces)
        } else {
            quoteSymbols[key] = nil
        }
        commitKvpCollections(named: "Set Quote Symbol")
    }

    // MARK: Auto-refresh (`FR-INV-03`)

    /// Whether quotes refresh on open and periodically (book preference).
    public var autoRefreshQuotes: Bool {
        get {
            if case let .int64(v)? = book?.kvp["finvestlens/autoRefreshQuotes"] { return v != 0 }
            return false
        }
        set {
            editingWholeBook(named: "Change Quote Auto-Refresh Setting") {
                book?.kvp["finvestlens/autoRefreshQuotes"] = .int64(newValue ? 1 : 0)
            }
            startQuoteAutoRefresh()
        }
    }

    /// Fetches the latest prices now, if auto-refresh is on and Yahoo (keyless)
    /// is available and there are securities to price.
    public func refreshQuotesNow() async {
        guard autoRefreshQuotes, !pricableSecurities.isEmpty,
              availableProviders.contains(.yahoo) else { return }
        await fetchLatestQuotes(using: .yahoo)
    }

    /// (Re)starts the periodic refresh loop: refreshes immediately, then every
    /// six hours while the document is open. Cancelled on close.
    public func startQuoteAutoRefresh() {
        quoteRefreshTask?.cancel()
        guard autoRefreshQuotes else { quoteRefreshTask = nil; return }
        quoteRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refreshQuotesNow()
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    /// Stops the periodic refresh loop.
    public func stopQuoteAutoRefresh() {
        quoteRefreshTask?.cancel()
        quoteRefreshTask = nil
    }

    // MARK: Fetching

    private func service() -> QuoteService {
        QuoteService(keys: apiKeys, http: quoteHTTP)
    }

    /// Fetches the latest quote for every held security using `kind` and adds a
    /// price for each success. Failures for individual symbols are collected but
    /// do not abort the run (`FR-INV-03`).
    public func fetchLatestQuotes(using kind: QuoteProviderKind) async {
        let commodities = pricableSecurities
        guard !commodities.isEmpty else {
            quoteStatus = .failure("No securities to price.")
            return
        }
        quoteStatus = .fetching("latest quotes")
        let service = service()
        var fetched: [Price] = []
        var failures: [String] = []
        for commodity in commodities {
            do {
                fetched.append(try await service.latestPrice(
                    for: commodity, in: reportCurrency, using: kind,
                    symbolOverride: quoteSymbol(for: commodity)))
            } catch {
                failures.append("\(commodity.mnemonic): \(Self.describe(error))")
            }
        }
        // Collected first, then applied in one go: the fetches await, and an
        // edit has to snapshot and mutate without suspending in between.
        let added = fetched.count
        if added > 0 {
            editingWholeBook(named: "Fetch Quotes") {
                for price in fetched { book?.addPrice(price) }
            }
        }
        quoteStatus = failures.isEmpty
            ? .success(added)
            : .failure("Added \(added). Failed — " + failures.joined(separator: "; "))
    }

    /// Brings **every** held security's price history up to date (`FR-INV-03e`):
    /// for each, fetches daily history from the day after its most recent stored
    /// price (or its first holding date when it has none) through today, adding
    /// only dates not already present. Providers without history fall back to a
    /// single latest quote. When this finishes, no security has a gap up to today.
    public func updatePriceHistory(using kind: QuoteProviderKind) async {
        let commodities = pricableSecurities
        guard !commodities.isEmpty else {
            quoteStatus = .failure("No securities to price.")
            return
        }
        let service = service()
        let calendar = Calendar.current
        let today = Date()
        let todayStart = calendar.startOfDay(for: today)

        // The dates we already hold per commodity — built once, so a big price
        // database isn't rescanned per security.
        var existing: [Commodity: Set<Date>] = [:]
        for price in book?.prices ?? [] {
            existing[price.commodity, default: []].insert(calendar.startOfDay(for: price.date))
        }

        var toAdd: [Price] = []
        var failures: [String] = []
        var alreadyCurrent = 0

        for (index, commodity) in commodities.enumerated() {
            quoteStatus = .fetching("prices \(index + 1) of \(commodities.count) — \(commodity.mnemonic)")
            let have = existing[commodity] ?? []
            let start: Date
            if let last = have.max() {
                start = calendar.date(byAdding: .day, value: 1, to: last) ?? last
            } else {
                start = firstHoldingDate(for: commodity)
                    ?? calendar.date(byAdding: .year, value: -5, to: today) ?? today
            }
            guard calendar.startOfDay(for: start) <= todayStart else { alreadyCurrent += 1; continue }

            do {
                let novel: [Price]
                if kind.supportsHistory {
                    novel = try await service.historicalPrices(
                        for: commodity, in: reportCurrency, from: start, to: today, using: kind,
                        symbolOverride: quoteSymbol(for: commodity))
                        .filter { !have.contains(calendar.startOfDay(for: $0.date)) }
                } else {
                    // No history endpoint: at least bring the latest price current.
                    let price = try await service.latestPrice(
                        for: commodity, in: reportCurrency, using: kind,
                        symbolOverride: quoteSymbol(for: commodity))
                    novel = have.contains(calendar.startOfDay(for: price.date)) ? [] : [price]
                }
                if novel.isEmpty { alreadyCurrent += 1 } else { toAdd.append(contentsOf: novel) }
            } catch {
                failures.append("\(commodity.mnemonic): \(Self.describe(error))")
            }
        }

        let added = toAdd.count
        if added > 0 {
            editingWholeBook(named: "Update Price History") {
                for price in toAdd { book?.addPrice(price) }
            }
        }
        if failures.isEmpty {
            quoteStatus = .success(added)
        } else {
            quoteStatus = .failure("Added \(added). Failed — " + failures.joined(separator: "; "))
        }
    }

    /// The earliest date any account denominated in `commodity` was posted to —
    /// where a security with no prices yet should start its history.
    private func firstHoldingDate(for commodity: Commodity) -> Date? {
        guard let book else { return nil }
        return book.accounts
            .filter { $0.commodity == commodity }
            .flatMap { book.splits(for: $0) }
            .compactMap { $0.transaction?.datePosted }
            .min()
    }

    /// Backfills daily history for `commodity` over `[from, to]`, adding a price
    /// per observation (`FR-INV-03e`).
    public func backfillHistory(for commodity: Commodity, from: Date, to: Date,
                                using kind: QuoteProviderKind) async {
        quoteStatus = .fetching("history for \(commodity.mnemonic)")
        do {
            let prices = try await service().historicalPrices(
                for: commodity, in: reportCurrency, from: from, to: to, using: kind,
                symbolOverride: quoteSymbol(for: commodity))
            if !prices.isEmpty {
                editingWholeBook(named: "Backfill Price History") {
                    for price in prices { book?.addPrice(price) }
                }
            }
            quoteStatus = .success(prices.count)
        } catch {
            quoteStatus = .failure(Self.describe(error))
        }
    }

    private static func describe(_ error: Error) -> String {
        if let quoteError = error as? QuoteError {
            switch quoteError {
            case .missingAPIKey(let kind): return "\(kind.displayName) API key not set"
            case .unsupported(let message): return message
            case .httpStatus(let code): return "HTTP \(code)"
            case .malformedResponse(let detail): return "bad response (\(detail))"
            case .providerError(let message): return message
            case .noData: return "no data"
            }
        }
        return error.localizedDescription
    }
}
