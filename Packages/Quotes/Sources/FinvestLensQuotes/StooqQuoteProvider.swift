//
//  StooqQuoteProvider.swift
//  FinvestLens — Quotes
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Stooq client — a keyless CSV end-of-day fallback source (`FR-INV-03b`,
/// Architecture §5.7).
///
/// Stooq serves plain CSV: `/q/l/` for the latest quote and `/q/d/l/` for a
/// daily history range. Symbols are Stooq-style (US tickers get a `.us`
/// suffix, indices start with `^`); the symbol is passed through as the user
/// configured it. Stooq does not report a currency, so quotes carry none.
public struct StooqQuoteProvider: QuoteProvider {
    public let kind: QuoteProviderKind = .stooq
    private let http: HTTPFetching
    private let host: String

    public init(http: HTTPFetching = URLSessionHTTPClient(), host: String = "stooq.com") {
        self.http = http
        self.host = host
    }

    public func latestQuote(symbol: String) async throws -> Quote {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/q/l/"
        components.queryItems = [
            URLQueryItem(name: "s", value: symbol),
            URLQueryItem(name: "f", value: "sd2t2ohlcv"),
            URLQueryItem(name: "h", value: nil),
            URLQueryItem(name: "e", value: "csv"),
        ]
        let data = try await http.get(components.url!)
        return try Self.parseLatest(data, fallbackSymbol: symbol)
    }

    public func history(symbol: String, from: Date, to: Date) async throws -> [Quote] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/q/d/l/"
        components.queryItems = [
            URLQueryItem(name: "s", value: symbol),
            URLQueryItem(name: "d1", value: Self.compactDate(from)),
            URLQueryItem(name: "d2", value: Self.compactDate(to)),
            URLQueryItem(name: "i", value: "d"),
        ]
        let data = try await http.get(components.url!)
        return try Self.parseHistory(data, fallbackSymbol: symbol)
    }

    // MARK: Parsing

    /// Latest CSV: `Symbol,Date,Time,Open,High,Low,Close,Volume`.
    static func parseLatest(_ data: Data, fallbackSymbol: String) throws -> Quote {
        let rows = csvRows(data)
        guard rows.count >= 2 else { throw QuoteError.noData }
        let header = rows[0].map { $0.lowercased() }
        let cols = rows[1]
        func col(_ name: String) -> String? {
            guard let i = header.firstIndex(of: name), i < cols.count else { return nil }
            return cols[i]
        }
        guard let closeText = col("close"), let price = Decimal(string: closeText),
              closeText.uppercased() != "N/D" else { throw QuoteError.noData }
        let date = col("date").flatMap(QuoteDate.date(from:)) ?? Date(timeIntervalSince1970: 0)
        return Quote(symbol: col("symbol") ?? fallbackSymbol, currencyCode: nil, price: price, date: date)
    }

    /// History CSV: `Date,Open,High,Low,Close,Volume`.
    static func parseHistory(_ data: Data, fallbackSymbol: String) throws -> [Quote] {
        let rows = csvRows(data)
        guard let header = rows.first?.map({ $0.lowercased() }),
              let dateIdx = header.firstIndex(of: "date"),
              let closeIdx = header.firstIndex(of: "close") else { throw QuoteError.noData }
        var quotes: [Quote] = []
        for cols in rows.dropFirst() {
            guard closeIdx < cols.count, dateIdx < cols.count,
                  let price = Decimal(string: cols[closeIdx]),
                  let day = QuoteDate.date(from: cols[dateIdx]) else { continue }
            quotes.append(Quote(symbol: fallbackSymbol, currencyCode: nil, price: price, date: day))
        }
        guard !quotes.isEmpty else { throw QuoteError.noData }
        return quotes.sorted { $0.date < $1.date }
    }

    private static func csvRows(_ data: Data) -> [[String]] {
        String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
    }

    private static func compactDate(_ date: Date) -> String {
        QuoteDate.string(from: date).replacingOccurrences(of: "-", with: "")
    }
}
