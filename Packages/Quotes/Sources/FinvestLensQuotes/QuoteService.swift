//
//  QuoteService.swift
//  FinvestLens — Quotes
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// Bridges ``QuoteProvider`` results into engine ``Price`` records.
///
/// The service resolves an API key (for keyed providers), fetches latest or
/// historical quotes, and maps each ``Quote`` to a `Price` denominated in the
/// caller-supplied currency — defaulting to the security's own currency when
/// the provider does not report one (Alpha Vantage, Finnhub).
public struct QuoteService: Sendable {
    private let keys: APIKeyStoring
    private let http: HTTPFetching

    public init(keys: APIKeyStoring, http: HTTPFetching = URLSessionHTTPClient()) {
        self.keys = keys
        self.http = http
    }

    /// Builds the provider for `kind`, throwing if a keyed provider lacks a key.
    public func provider(_ kind: QuoteProviderKind) throws -> QuoteProvider {
        let key = kind.requiresAPIKey ? keys.key(for: kind) : nil
        if kind.requiresAPIKey, (key ?? "").isEmpty {
            throw QuoteError.missingAPIKey(kind)
        }
        guard let provider = QuoteProviderFactory.make(kind, apiKey: key, http: http) else {
            throw QuoteError.missingAPIKey(kind)
        }
        return provider
    }

    /// The provider ticker for `commodity`: an explicit override, else its
    /// mnemonic.
    public static func symbol(for commodity: Commodity, override: String? = nil) -> String {
        if let override, !override.isEmpty { return override }
        return commodity.mnemonic
    }

    /// Fetches the latest quote and returns a `Price` of `commodity` in
    /// `currency`.
    public func latestPrice(
        for commodity: Commodity,
        in currency: Commodity,
        using kind: QuoteProviderKind,
        symbolOverride: String? = nil
    ) async throws -> Price {
        let provider = try provider(kind)
        let symbol = kind.providerSymbol(for: Self.symbol(for: commodity, override: symbolOverride))
        let quote = try await provider.latestQuote(symbol: symbol)
        return Self.price(from: quote, commodity: commodity, currency: currency, kind: kind)
    }

    /// Fetches daily history and returns one `Price` per observation.
    public func historicalPrices(
        for commodity: Commodity,
        in currency: Commodity,
        from: Date,
        to: Date,
        using kind: QuoteProviderKind,
        symbolOverride: String? = nil
    ) async throws -> [Price] {
        let provider = try provider(kind)
        let symbol = kind.providerSymbol(for: Self.symbol(for: commodity, override: symbolOverride))
        let quotes = try await provider.history(symbol: symbol, from: from, to: to)
        return quotes.map { Self.price(from: $0, commodity: commodity, currency: currency, kind: kind) }
    }

    /// Maps a ``Quote`` to a `Price`. The provider-reported currency, if any, is
    /// carried in the price `source` for provenance but does not override the
    /// caller's `currency` (multi-currency FX valuation is a higher layer).
    static func price(from quote: Quote, commodity: Commodity, currency: Commodity, kind: QuoteProviderKind) -> Price {
        Price(
            commodity: commodity,
            currency: currency,
            date: quote.date,
            value: quote.price,
            source: "Finance::Quote:\(kind.rawValue)",
            type: "last"
        )
    }
}
