//
//  QuoteProvider.swift
//  FinvestLens — Quotes
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The quote services FinvestLens ships with (`FR-INV-03`).
public enum QuoteProviderKind: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Keyless yfinance-like Yahoo Finance client.
    case yahoo
    /// EODHD — historical data incl. delisted securities (keyed).
    case eodhd
    /// Alpha Vantage (keyed).
    case alphaVantage
    /// Finnhub (keyed, latest quotes only).
    case finnhub
    /// Twelve Data — latest + daily history (keyed).
    case twelveData
    /// Stooq — keyless CSV end-of-day fallback.
    case stooq

    public var id: String { rawValue }

    /// Human-readable name for settings UI.
    public var displayName: String {
        switch self {
        case .yahoo: return "Yahoo Finance"
        case .eodhd: return "EODHD"
        case .alphaVantage: return "Alpha Vantage"
        case .finnhub: return "Finnhub"
        case .twelveData: return "Twelve Data"
        case .stooq: return "Stooq"
        }
    }

    /// Whether the provider needs a user-supplied API key.
    public var requiresAPIKey: Bool {
        switch self {
        case .yahoo, .stooq: return false
        case .eodhd, .alphaVantage, .finnhub, .twelveData: return true
        }
    }

    /// Whether the provider can return historical series.
    public var supportsHistory: Bool {
        switch self {
        case .yahoo, .eodhd, .alphaVantage, .twelveData, .stooq: return true
        case .finnhub: return false
        }
    }

    /// Where the user can obtain an API key.
    public var signupURL: URL? {
        switch self {
        case .yahoo, .stooq: return nil
        case .eodhd: return URL(string: "https://eodhd.com/register")
        case .alphaVantage: return URL(string: "https://www.alphavantage.co/support/#api-key")
        case .finnhub: return URL(string: "https://finnhub.io/register")
        case .twelveData: return URL(string: "https://twelvedata.com/pricing")
        }
    }
}

/// A source of security prices — latest and (optionally) historical.
///
/// Providers are stateless value types built with an injectable ``HTTPFetching``
/// transport, so their URL construction and response parsing can be unit-tested
/// against captured fixtures without touching the network.
public protocol QuoteProvider: Sendable {
    /// Which service this is.
    var kind: QuoteProviderKind { get }

    /// The most recent quote for `symbol`.
    func latestQuote(symbol: String) async throws -> Quote

    /// Daily closes for `symbol` in `[from, to]` (inclusive), oldest first.
    func history(symbol: String, from: Date, to: Date) async throws -> [Quote]
}

/// Builds the shipped provider for a given kind, wiring in an API key and
/// transport. Returns `nil` when a keyed provider has no key configured.
public enum QuoteProviderFactory {
    public static func make(
        _ kind: QuoteProviderKind,
        apiKey: String? = nil,
        http: HTTPFetching = URLSessionHTTPClient()
    ) -> QuoteProvider? {
        switch kind {
        case .yahoo:
            return YahooQuoteProvider(http: http)
        case .eodhd:
            guard let apiKey, !apiKey.isEmpty else { return nil }
            return EODHDQuoteProvider(apiKey: apiKey, http: http)
        case .alphaVantage:
            guard let apiKey, !apiKey.isEmpty else { return nil }
            return AlphaVantageQuoteProvider(apiKey: apiKey, http: http)
        case .finnhub:
            guard let apiKey, !apiKey.isEmpty else { return nil }
            return FinnhubQuoteProvider(apiKey: apiKey, http: http)
        case .twelveData:
            guard let apiKey, !apiKey.isEmpty else { return nil }
            return TwelveDataQuoteProvider(apiKey: apiKey, http: http)
        case .stooq:
            return StooqQuoteProvider(http: http)
        }
    }
}
