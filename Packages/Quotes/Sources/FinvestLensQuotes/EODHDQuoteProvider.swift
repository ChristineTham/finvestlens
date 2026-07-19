//
//  EODHDQuoteProvider.swift
//  FinvestLens — Quotes
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// EODHD client — end-of-day history (incl. delisted securities) and real-time
/// quotes (`FR-INV-03b`). Symbols are exchange-qualified, e.g. `"CBA.AU"`.
public struct EODHDQuoteProvider: QuoteProvider {
    public let kind: QuoteProviderKind = .eodhd
    private let apiKey: String
    private let http: HTTPFetching
    private let host: String

    public init(apiKey: String, http: HTTPFetching = URLSessionHTTPClient(), host: String = "eodhd.com") {
        self.apiKey = apiKey
        self.http = http
        self.host = host
    }

    public func latestQuote(symbol: String) async throws -> Quote {
        let data = try await http.get(url(path: "/api/real-time/\(symbol)", extra: []))
        return try Self.parseLatest(data, fallbackSymbol: symbol)
    }

    public func history(symbol: String, from: Date, to: Date) async throws -> [Quote] {
        let data = try await http.get(url(path: "/api/eod/\(symbol)", extra: [
            URLQueryItem(name: "from", value: QuoteDate.string(from: from)),
            URLQueryItem(name: "to", value: QuoteDate.string(from: to)),
        ]))
        return try Self.parseHistory(data, fallbackSymbol: symbol)
    }

    private func url(path: String, extra: [URLQueryItem]) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        // Percent-encode the path (which embeds the symbol): a symbol with a
        // space or other path-invalid character would otherwise make
        // `components.url` nil and crash the force-unwrap. `.urlPathAllowed`
        // keeps the "/" separators intact.
        components.percentEncodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        components.queryItems = [
            URLQueryItem(name: "api_token", value: apiKey),
            URLQueryItem(name: "fmt", value: "json"),
        ] + extra
        return components.url ?? URL(string: "https://\(host)")!
    }

    // MARK: Parsing

    static func parseLatest(_ data: Data, fallbackSymbol: String) throws -> Quote {
        let row = try JSONDecoder().decode(RealTimeRow.self, from: data)
        guard let close = row.close, close != "NA", let price = Decimal(string: close) else {
            throw QuoteError.noData
        }
        let date = row.timestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date(timeIntervalSince1970: 0)
        return Quote(symbol: row.code ?? fallbackSymbol, currencyCode: nil, price: price, date: date)
    }

    static func parseHistory(_ data: Data, fallbackSymbol: String) throws -> [Quote] {
        let rows = try JSONDecoder().decode([EODRow].self, from: data)
        let quotes: [Quote] = rows.compactMap { row in
            guard let date = QuoteDate.date(from: row.date) else { return nil }
            return Quote(symbol: fallbackSymbol, currencyCode: nil, price: row.close, date: date)
        }
        guard !quotes.isEmpty else { throw QuoteError.noData }
        return quotes.sorted { $0.date < $1.date }
    }

    // EODHD encodes real-time `close`/`timestamp` as either a number or the
    // string "NA"; decode `close` as a string to tolerate both.
    private struct RealTimeRow: Decodable {
        let code: String?
        let close: String?
        let timestamp: Int?

        private enum CodingKeys: String, CodingKey { case code, close, timestamp }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            code = try c.decodeIfPresent(String.self, forKey: .code)
            timestamp = try? c.decodeIfPresent(Int.self, forKey: .timestamp)
            if let s = try? c.decodeIfPresent(String.self, forKey: .close) {
                close = s
            } else if let d = try? c.decodeIfPresent(Decimal.self, forKey: .close) {
                close = NSDecimalNumber(decimal: d).stringValue
            } else {
                close = nil
            }
        }
    }

    private struct EODRow: Decodable {
        let date: String
        let close: Decimal
    }
}
