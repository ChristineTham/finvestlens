//
//  AlphaVantageQuoteProvider.swift
//  FinvestLens — Quotes
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Alpha Vantage client — `GLOBAL_QUOTE` for latest, `TIME_SERIES_DAILY` for
/// history (`FR-INV-03c`). Alpha Vantage does not report a currency, so the
/// caller values the price in the security's own currency.
public struct AlphaVantageQuoteProvider: QuoteProvider {
    public let kind: QuoteProviderKind = .alphaVantage
    private let apiKey: String
    private let http: HTTPFetching
    private let host: String

    public init(apiKey: String, http: HTTPFetching = URLSessionHTTPClient(), host: String = "www.alphavantage.co") {
        self.apiKey = apiKey
        self.http = http
        self.host = host
    }

    public func latestQuote(symbol: String) async throws -> Quote {
        let data = try await http.get(url(function: "GLOBAL_QUOTE", symbol: symbol, extra: []))
        return try Self.parseLatest(data, fallbackSymbol: symbol)
    }

    public func history(symbol: String, from: Date, to: Date) async throws -> [Quote] {
        let data = try await http.get(url(function: "TIME_SERIES_DAILY", symbol: symbol, extra: [
            URLQueryItem(name: "outputsize", value: "full"),
        ]))
        return try Self.parseHistory(data, fallbackSymbol: symbol, from: from, to: to)
    }

    private func url(function: String, symbol: String, extra: [URLQueryItem]) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/query"
        components.queryItems = [
            URLQueryItem(name: "function", value: function),
            URLQueryItem(name: "symbol", value: symbol),
            URLQueryItem(name: "apikey", value: apiKey),
        ] + extra
        return components.url!
    }

    // MARK: Parsing

    static func parseLatest(_ data: Data, fallbackSymbol: String) throws -> Quote {
        try checkForNotice(data)
        let response = try JSONDecoder().decode(GlobalQuoteResponse.self, from: data)
        guard let quote = response.quote else { throw QuoteError.noData }
        guard let price = Decimal(string: quote.price) else {
            throw QuoteError.malformedResponse("unparseable price \(quote.price)")
        }
        let date = QuoteDate.date(from: quote.latestTradingDay) ?? Date(timeIntervalSince1970: 0)
        return Quote(symbol: quote.symbol ?? fallbackSymbol, currencyCode: nil, price: price, date: date)
    }

    static func parseHistory(_ data: Data, fallbackSymbol: String, from: Date, to: Date) throws -> [Quote] {
        try checkForNotice(data)
        let response = try JSONDecoder().decode(TimeSeriesResponse.self, from: data)
        guard let series = response.series else { throw QuoteError.noData }
        // Bar dates are day-only (UTC midnight); `from`/`to` usually carry a
        // wall-clock time, so compare at UTC day granularity or the first/last
        // day of the window would be dropped.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let fromDay = utc.startOfDay(for: from)
        let toDay = utc.startOfDay(for: to)
        var quotes: [Quote] = []
        for (dateString, bar) in series {
            guard let date = QuoteDate.date(from: dateString), date >= fromDay, date <= toDay,
                  let price = Decimal(string: bar.close) else { continue }
            quotes.append(Quote(symbol: fallbackSymbol, currencyCode: nil, price: price, date: date))
        }
        guard !quotes.isEmpty else { throw QuoteError.noData }
        return quotes.sorted { $0.date < $1.date }
    }

    /// Alpha Vantage returns a 200 with a `Note`/`Information` body when the
    /// rate limit is hit or the key is invalid — surface that as an error.
    private static func checkForNotice(_ data: Data) throws {
        struct Notice: Decodable { let note: String?; let information: String?; let errorMessage: String?
            enum CodingKeys: String, CodingKey {
                case note = "Note", information = "Information", errorMessage = "Error Message"
            }
        }
        if let notice = try? JSONDecoder().decode(Notice.self, from: data),
           let message = notice.note ?? notice.information ?? notice.errorMessage {
            throw QuoteError.providerError(message)
        }
    }

    // MARK: Response shapes

    private struct GlobalQuoteResponse: Decodable {
        let quote: Row?
        enum CodingKeys: String, CodingKey { case quote = "Global Quote" }
        struct Row: Decodable {
            let symbol: String?
            let price: String
            let latestTradingDay: String
            enum CodingKeys: String, CodingKey {
                case symbol = "01. symbol"
                case price = "05. price"
                case latestTradingDay = "07. latest trading day"
            }
        }
    }

    private struct TimeSeriesResponse: Decodable {
        let series: [String: Bar]?
        enum CodingKeys: String, CodingKey { case series = "Time Series (Daily)" }
        struct Bar: Decodable {
            let close: String
            enum CodingKeys: String, CodingKey { case close = "4. close" }
        }
    }
}
