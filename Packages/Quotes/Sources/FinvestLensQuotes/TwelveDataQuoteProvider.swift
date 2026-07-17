//
//  TwelveDataQuoteProvider.swift
//  FinvestLens — Quotes
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Twelve Data client — latest quotes and daily history (keyed, `FR-INV-03b`).
///
/// Uses `/quote` (latest, with currency + timestamp) and `/time_series`
/// (`interval=1day`) for history. Both report an error as
/// `{"status":"error","message":…}`, which is surfaced as a `providerError`.
public struct TwelveDataQuoteProvider: QuoteProvider {
    public let kind: QuoteProviderKind = .twelveData
    private let apiKey: String
    private let http: HTTPFetching
    private let host: String

    public init(apiKey: String, http: HTTPFetching = URLSessionHTTPClient(), host: String = "api.twelvedata.com") {
        self.apiKey = apiKey
        self.http = http
        self.host = host
    }

    public func latestQuote(symbol: String) async throws -> Quote {
        let data = try await http.get(url(path: "/quote", extra: [
            URLQueryItem(name: "symbol", value: symbol),
        ]))
        return try Self.parseLatest(data, fallbackSymbol: symbol)
    }

    public func history(symbol: String, from: Date, to: Date) async throws -> [Quote] {
        let data = try await http.get(url(path: "/time_series", extra: [
            URLQueryItem(name: "symbol", value: symbol),
            URLQueryItem(name: "interval", value: "1day"),
            URLQueryItem(name: "start_date", value: QuoteDate.string(from: from)),
            URLQueryItem(name: "end_date", value: QuoteDate.string(from: to)),
            URLQueryItem(name: "order", value: "ASC"),
        ]))
        return try Self.parseHistory(data, fallbackSymbol: symbol)
    }

    private func url(path: String, extra: [URLQueryItem]) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = [
            URLQueryItem(name: "apikey", value: apiKey),
            URLQueryItem(name: "format", value: "JSON"),
        ] + extra
        return components.url!
    }

    // MARK: Parsing

    static func parseLatest(_ data: Data, fallbackSymbol: String) throws -> Quote {
        let row = try JSONDecoder().decode(QuoteRow.self, from: data)
        if row.status == "error" { throw QuoteError.providerError(row.message ?? "error") }
        guard let closeText = row.close, let price = Decimal(string: closeText) else {
            throw QuoteError.noData
        }
        let date = date(timestamp: row.timestamp, datetime: row.datetime)
        return Quote(symbol: row.symbol ?? fallbackSymbol, currencyCode: row.currency,
                     price: price, date: date)
    }

    static func parseHistory(_ data: Data, fallbackSymbol: String) throws -> [Quote] {
        let response = try JSONDecoder().decode(TimeSeriesResponse.self, from: data)
        if response.status == "error" { throw QuoteError.providerError(response.message ?? "error") }
        let symbol = response.meta?.symbol ?? fallbackSymbol
        let currency = response.meta?.currency
        let quotes: [Quote] = (response.values ?? []).compactMap { value in
            guard let close = value.close, let price = Decimal(string: close),
                  let day = QuoteDate.date(from: String(value.datetime.prefix(10))) else { return nil }
            return Quote(symbol: symbol, currencyCode: currency, price: price, date: day)
        }
        guard !quotes.isEmpty else { throw QuoteError.noData }
        return quotes.sorted { $0.date < $1.date }
    }

    private static func date(timestamp: Int?, datetime: String?) -> Date {
        if let timestamp { return Date(timeIntervalSince1970: TimeInterval(timestamp)) }
        if let datetime, let day = QuoteDate.date(from: String(datetime.prefix(10))) { return day }
        return Date(timeIntervalSince1970: 0)
    }

    // MARK: Response shapes

    private struct QuoteRow: Decodable {
        let symbol: String?
        let currency: String?
        let datetime: String?
        let timestamp: Int?
        let close: String?
        let status: String?
        let message: String?
    }

    private struct TimeSeriesResponse: Decodable {
        let meta: Meta?
        let values: [Value]?
        let status: String?
        let message: String?

        struct Meta: Decodable {
            let symbol: String?
            let currency: String?
        }
        struct Value: Decodable {
            let datetime: String
            let close: String?
        }
    }
}
