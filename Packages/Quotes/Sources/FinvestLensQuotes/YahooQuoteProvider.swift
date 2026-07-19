//
//  YahooQuoteProvider.swift
//  FinvestLens — Quotes
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Keyless Yahoo Finance client, modelled on `yfinance` (`FR-INV-03a`).
///
/// Uses the public `v8/finance/chart` endpoint, which returns both a `meta`
/// block (latest price + currency) and a timestamp/close series for history —
/// so a single response shape covers both operations. A browser-like
/// User-Agent is required or Yahoo returns 429/401.
public struct YahooQuoteProvider: QuoteProvider {
    public let kind: QuoteProviderKind = .yahoo
    private let http: HTTPFetching
    private let host: String

    public init(http: HTTPFetching = URLSessionHTTPClient(), host: String = "query1.finance.yahoo.com") {
        self.http = http
        self.host = host
    }

    public func latestQuote(symbol: String) async throws -> Quote {
        let data = try await http.get(chartURL(symbol: symbol, query: [
            URLQueryItem(name: "interval", value: "1d"),
            URLQueryItem(name: "range", value: "5d"),
        ]), headers: ["User-Agent": HTTPDefaults.userAgent])
        return try Self.parseLatest(data, fallbackSymbol: symbol)
    }

    public func history(symbol: String, from: Date, to: Date) async throws -> [Quote] {
        let data = try await http.get(chartURL(symbol: symbol, query: [
            URLQueryItem(name: "interval", value: "1d"),
            URLQueryItem(name: "period1", value: String(Int(from.timeIntervalSince1970))),
            URLQueryItem(name: "period2", value: String(Int(to.timeIntervalSince1970))),
        ]), headers: ["User-Agent": HTTPDefaults.userAgent])
        return try Self.parseHistory(data, fallbackSymbol: symbol)
    }

    private func chartURL(symbol: String, query: [URLQueryItem]) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        // Percent-encode the symbol: an override like "BRK B" (space) would
        // otherwise make `components.url` nil and crash the force-unwrap.
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        components.percentEncodedPath = "/v8/finance/chart/" + encoded
        components.queryItems = query
        return components.url ?? URL(string: "https://\(host)")!
    }

    // MARK: Parsing

    static func parseLatest(_ data: Data, fallbackSymbol: String) throws -> Quote {
        let result = try decodeResult(data)
        guard let price = result.meta.regularMarketPrice else {
            throw QuoteError.malformedResponse("missing regularMarketPrice")
        }
        let time = result.meta.regularMarketTime.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date(timeIntervalSince1970: 0)
        return Quote(symbol: result.meta.symbol ?? fallbackSymbol,
                     currencyCode: result.meta.currency,
                     price: price,
                     date: time)
    }

    static func parseHistory(_ data: Data, fallbackSymbol: String) throws -> [Quote] {
        let result = try decodeResult(data)
        guard let timestamps = result.timestamp,
              let closes = result.indicators.quote.first?.close else {
            throw QuoteError.noData
        }
        let symbol = result.meta.symbol ?? fallbackSymbol
        let currency = result.meta.currency
        var quotes: [Quote] = []
        for (index, epoch) in timestamps.enumerated() {
            guard index < closes.count, let close = closes[index] else { continue }
            quotes.append(Quote(symbol: symbol, currencyCode: currency,
                                price: close,
                                date: Date(timeIntervalSince1970: TimeInterval(epoch))))
        }
        guard !quotes.isEmpty else { throw QuoteError.noData }
        return quotes
    }

    private static func decodeResult(_ data: Data) throws -> ChartResponse.Result {
        let response = try JSONDecoder().decode(ChartResponse.self, from: data)
        if let error = response.chart.error {
            throw QuoteError.providerError(error.description ?? error.code)
        }
        guard let result = response.chart.result?.first else {
            throw QuoteError.noData
        }
        return result
    }

    // MARK: Response shape

    private struct ChartResponse: Decodable {
        let chart: Chart

        struct Chart: Decodable {
            let result: [Result]?
            let error: YahooError?
        }
        struct YahooError: Decodable {
            let code: String
            let description: String?
        }
        struct Result: Decodable {
            let meta: Meta
            let timestamp: [Int]?
            let indicators: Indicators
        }
        struct Meta: Decodable {
            let currency: String?
            let symbol: String?
            let regularMarketPrice: Decimal?
            let regularMarketTime: Int?
        }
        struct Indicators: Decodable {
            let quote: [QuoteSeries]
        }
        struct QuoteSeries: Decodable {
            let close: [Decimal?]?
        }
    }
}
