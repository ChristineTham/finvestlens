//
//  ProviderParsingTests.swift
//  FinvestLens — Quotes
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensQuotes

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

@Suite("Yahoo provider")
struct YahooProviderTests {

    // Trimmed v8/finance/chart payload with a meta block and a 3-day close series.
    static let chartJSON = """
    {"chart":{"result":[{"meta":{"currency":"AUD","symbol":"CBA.AX",
    "regularMarketPrice":105.20,"regularMarketTime":1700000000},
    "timestamp":[1699800000,1699886400,1699972800],
    "indicators":{"quote":[{"close":[104.10,null,105.20]}]}}],"error":null}}
    """

    @Test("Latest quote parses price, currency and time")
    func latest() async throws {
        let http = StubHTTPClient()
        http.on("/v8/finance/chart/CBA.AX", body: Self.chartJSON)
        let quote = try await YahooQuoteProvider(http: http).latestQuote(symbol: "CBA.AX")
        #expect(quote.symbol == "CBA.AX")
        #expect(quote.currencyCode == "AUD")
        #expect(quote.price == dec("105.20"))
        #expect(quote.date == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("Decimal price is exact (no binary-float drift)")
    func exactDecimal() async throws {
        let http = StubHTTPClient()
        http.on("chart", body: Self.chartJSON)
        let quote = try await YahooQuoteProvider(http: http).latestQuote(symbol: "CBA.AX")
        #expect("\(quote.price)" == "105.2")
    }

    @Test("History skips null closes and pairs timestamps")
    func history() async throws {
        let http = StubHTTPClient()
        http.on("chart", body: Self.chartJSON)
        let quotes = try await YahooQuoteProvider(http: http)
            .history(symbol: "CBA.AX", from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(quotes.count == 2)
        #expect(quotes.first?.price == dec("104.10"))
        #expect(quotes.first?.date == Date(timeIntervalSince1970: 1_699_800_000))
        #expect(quotes.last?.price == dec("105.20"))
    }

    @Test("Provider error surfaces")
    func providerError() async throws {
        let http = StubHTTPClient()
        http.on("chart", body: #"{"chart":{"result":null,"error":{"code":"Not Found","description":"No data found"}}}"#)
        await #expect(throws: QuoteError.self) {
            _ = try await YahooQuoteProvider(http: http).latestQuote(symbol: "NOPE")
        }
    }
}

@Suite("EODHD provider")
struct EODHDProviderTests {

    @Test("Real-time latest parses close and timestamp")
    func latest() async throws {
        let http = StubHTTPClient()
        http.on("/api/real-time/CBA.AU",
                body: #"{"code":"CBA.AU","timestamp":1700000000,"close":105.20}"#)
        let quote = try await EODHDQuoteProvider(apiKey: "K", http: http).latestQuote(symbol: "CBA.AU")
        #expect(quote.price == dec("105.20"))
        #expect(quote.date == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("Real-time NA close yields noData")
    func naClose() async throws {
        let http = StubHTTPClient()
        http.on("real-time", body: #"{"code":"X","timestamp":"NA","close":"NA"}"#)
        await #expect(throws: QuoteError.noData) {
            _ = try await EODHDQuoteProvider(apiKey: "K", http: http).latestQuote(symbol: "X")
        }
    }

    @Test("EOD history parses and sorts oldest-first")
    func history() async throws {
        let http = StubHTTPClient()
        http.on("/api/eod/CBA.AU", body: """
        [{"date":"2023-11-15","close":105.20},{"date":"2023-11-13","close":104.10}]
        """)
        let quotes = try await EODHDQuoteProvider(apiKey: "K", http: http)
            .history(symbol: "CBA.AU", from: QuoteDate.date(from: "2023-11-01")!, to: QuoteDate.date(from: "2023-11-30")!)
        #expect(quotes.count == 2)
        #expect(quotes.first?.date == QuoteDate.date(from: "2023-11-13"))
        #expect(quotes.last?.price == dec("105.20"))
    }

    @Test("API key travels in the query")
    func keyInQuery() async throws {
        let http = StubHTTPClient()
        http.on("real-time", body: #"{"code":"X","timestamp":1,"close":1.0}"#)
        _ = try await EODHDQuoteProvider(apiKey: "SECRET", http: http).latestQuote(symbol: "X")
        #expect(http.requestedURLs.first?.absoluteString.contains("api_token=SECRET") == true)
    }
}

@Suite("Alpha Vantage provider")
struct AlphaVantageProviderTests {

    @Test("Global quote parses string price and date")
    func latest() async throws {
        let http = StubHTTPClient()
        http.on("GLOBAL_QUOTE", body: """
        {"Global Quote":{"01. symbol":"IBM","05. price":"182.4500","07. latest trading day":"2023-11-15"}}
        """)
        let quote = try await AlphaVantageQuoteProvider(apiKey: "K", http: http).latestQuote(symbol: "IBM")
        #expect(quote.price == dec("182.45"))
        #expect(quote.date == QuoteDate.date(from: "2023-11-15"))
    }

    @Test("Time series filters to the requested window")
    func history() async throws {
        let http = StubHTTPClient()
        http.on("TIME_SERIES_DAILY", body: """
        {"Time Series (Daily)":{
          "2023-11-15":{"4. close":"182.45"},
          "2023-11-14":{"4. close":"181.00"},
          "2023-10-01":{"4. close":"170.00"}}}
        """)
        let quotes = try await AlphaVantageQuoteProvider(apiKey: "K", http: http)
            .history(symbol: "IBM", from: QuoteDate.date(from: "2023-11-01")!, to: QuoteDate.date(from: "2023-11-30")!)
        #expect(quotes.count == 2)
        #expect(quotes.map(\.price).contains(dec("170.00")) == false)
    }

    @Test("Rate-limit note surfaces as providerError")
    func rateLimit() async throws {
        let http = StubHTTPClient()
        http.on("GLOBAL_QUOTE", body: #"{"Note":"Thank you for using Alpha Vantage! Our standard API rate limit..."}"#)
        await #expect(throws: QuoteError.self) {
            _ = try await AlphaVantageQuoteProvider(apiKey: "K", http: http).latestQuote(symbol: "IBM")
        }
    }
}

@Suite("Finnhub provider")
struct FinnhubProviderTests {

    @Test("Quote parses current and timestamp")
    func latest() async throws {
        let http = StubHTTPClient()
        http.on("/api/v1/quote", body: #"{"c":182.45,"h":183.0,"l":181.0,"o":181.5,"pc":181.0,"t":1700000000}"#)
        let quote = try await FinnhubQuoteProvider(apiKey: "K", http: http).latestQuote(symbol: "AAPL")
        #expect(quote.price == dec("182.45"))
        #expect(quote.date == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("Zero current price (unknown symbol) yields noData")
    func unknown() async throws {
        let http = StubHTTPClient()
        http.on("quote", body: #"{"c":0,"t":0}"#)
        await #expect(throws: QuoteError.noData) {
            _ = try await FinnhubQuoteProvider(apiKey: "K", http: http).latestQuote(symbol: "NOPE")
        }
    }

    @Test("History is unsupported")
    func historyUnsupported() async throws {
        let http = StubHTTPClient()
        await #expect(throws: QuoteError.self) {
            _ = try await FinnhubQuoteProvider(apiKey: "K", http: http)
                .history(symbol: "AAPL", from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 1))
        }
    }
}
