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
        commitKvpCollections()
    }

    // MARK: Fetching

    private func service() -> QuoteService {
        QuoteService(keys: apiKeys, http: quoteHTTP)
    }

    /// Fetches the latest quote for every held security using `kind` and adds a
    /// price for each success. Failures for individual symbols are collected but
    /// do not abort the run (`FR-INV-03`).
    public func fetchLatestQuotes(using kind: QuoteProviderKind) async {
        let commodities = securityCommodities
        guard !commodities.isEmpty else {
            quoteStatus = .failure("No securities to price.")
            return
        }
        quoteStatus = .fetching("latest quotes")
        let service = service()
        var added = 0
        var failures: [String] = []
        for commodity in commodities {
            do {
                let price = try await service.latestPrice(
                    for: commodity, in: reportCurrency, using: kind,
                    symbolOverride: quoteSymbol(for: commodity))
                book?.addPrice(price)
                added += 1
            } catch {
                failures.append("\(commodity.mnemonic): \(Self.describe(error))")
            }
        }
        if added > 0 { markDirtyAndRefresh() }
        quoteStatus = failures.isEmpty
            ? .success(added)
            : .failure("Added \(added). Failed — " + failures.joined(separator: "; "))
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
            for price in prices { book?.addPrice(price) }
            if !prices.isEmpty { markDirtyAndRefresh() }
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
