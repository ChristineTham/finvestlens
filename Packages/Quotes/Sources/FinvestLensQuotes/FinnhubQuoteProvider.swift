//
//  FinnhubQuoteProvider.swift
//  FinvestLens — Quotes
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Finnhub client — latest quotes only (`FR-INV-03d`). Finnhub's free tier no
/// longer exposes daily candles, so ``history(symbol:from:to:)`` is unsupported.
public struct FinnhubQuoteProvider: QuoteProvider {
    public let kind: QuoteProviderKind = .finnhub
    private let apiKey: String
    private let http: HTTPFetching
    private let host: String

    public init(apiKey: String, http: HTTPFetching = URLSessionHTTPClient(), host: String = "finnhub.io") {
        self.apiKey = apiKey
        self.http = http
        self.host = host
    }

    public func latestQuote(symbol: String) async throws -> Quote {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/api/v1/quote"
        components.queryItems = [
            URLQueryItem(name: "symbol", value: symbol),
            URLQueryItem(name: "token", value: apiKey),
        ]
        let data = try await http.get(components.url!)
        return try Self.parseLatest(data, fallbackSymbol: symbol)
    }

    public func history(symbol: String, from: Date, to: Date) async throws -> [Quote] {
        throw QuoteError.unsupported("Finnhub does not provide daily history on the free tier")
    }

    // MARK: Parsing

    static func parseLatest(_ data: Data, fallbackSymbol: String) throws -> Quote {
        let row = try JSONDecoder().decode(QuoteRow.self, from: data)
        // Finnhub returns c=0 for an unknown symbol.
        guard row.current != 0 else { throw QuoteError.noData }
        let date = row.timestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date(timeIntervalSince1970: 0)
        return Quote(symbol: fallbackSymbol, currencyCode: nil, price: row.current, date: date)
    }

    private struct QuoteRow: Decodable {
        let current: Decimal
        let timestamp: Int?
        enum CodingKeys: String, CodingKey {
            case current = "c"
            case timestamp = "t"
        }
    }
}
