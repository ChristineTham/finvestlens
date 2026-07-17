//
//  NewProviderTests.swift
//  FinvestLens — Quotes
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensQuotes

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

@Suite("Twelve Data provider")
struct TwelveDataProviderTests {

    @Test("Latest quote parses close, currency and timestamp")
    func latest() async throws {
        let json = """
        {"symbol":"AAPL","currency":"USD","datetime":"2023-11-14",
        "timestamp":1700000000,"close":"105.20","status":"ok"}
        """
        let http = StubHTTPClient(); http.on("/quote", body: json)
        let quote = try await TwelveDataQuoteProvider(apiKey: "k", http: http).latestQuote(symbol: "AAPL")
        #expect(quote.symbol == "AAPL")
        #expect(quote.currencyCode == "USD")
        #expect(quote.price == dec("105.20"))
        #expect(quote.date == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("History parses the values array, oldest first")
    func history() async throws {
        let json = """
        {"meta":{"symbol":"AAPL","currency":"USD"},"values":[
        {"datetime":"2023-11-15","close":"106.00"},
        {"datetime":"2023-11-14","close":"105.20"}],"status":"ok"}
        """
        let http = StubHTTPClient(); http.on("/time_series", body: json)
        let quotes = try await TwelveDataQuoteProvider(apiKey: "k", http: http)
            .history(symbol: "AAPL", from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(quotes.count == 2)
        #expect(quotes.first?.price == dec("105.20"))   // sorted ascending
        #expect(quotes.last?.price == dec("106.00"))
    }

    @Test("An error status surfaces as providerError")
    func errorStatus() async throws {
        let http = StubHTTPClient()
        http.on("/quote", body: #"{"code":429,"message":"API limit","status":"error"}"#)
        await #expect(throws: QuoteError.self) {
            _ = try await TwelveDataQuoteProvider(apiKey: "k", http: http).latestQuote(symbol: "AAPL")
        }
    }
}

@Suite("Stooq provider")
struct StooqProviderTests {

    @Test("Latest CSV parses the close and date")
    func latest() async throws {
        let csv = "Symbol,Date,Time,Open,High,Low,Close,Volume\nAAPL.US,2023-11-14,22:00:00,104,106,103,105.20,1000\n"
        let http = StubHTTPClient(); http.on("/q/l/", body: csv)
        let quote = try await StooqQuoteProvider(http: http).latestQuote(symbol: "aapl.us")
        #expect(quote.symbol == "AAPL.US")
        #expect(quote.currencyCode == nil)
        #expect(quote.price == dec("105.20"))
        #expect(quote.date == QuoteDate.date(from: "2023-11-14"))
    }

    @Test("History CSV parses rows, oldest first")
    func history() async throws {
        let csv = "Date,Open,High,Low,Close,Volume\n2023-11-15,105,107,104,106.00,1200\n2023-11-14,104,106,103,105.20,1000\n"
        let http = StubHTTPClient(); http.on("/q/d/l/", body: csv)
        let quotes = try await StooqQuoteProvider(http: http)
            .history(symbol: "aapl.us", from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(quotes.count == 2)
        #expect(quotes.first?.price == dec("105.20"))
        #expect(quotes.last?.price == dec("106.00"))
    }

    @Test("Stooq is keyless and the factory builds it without a key")
    func factory() {
        #expect(QuoteProviderKind.stooq.requiresAPIKey == false)
        #expect(QuoteProviderFactory.make(.stooq) != nil)
        #expect(QuoteProviderFactory.make(.twelveData, apiKey: "") == nil)
        #expect(QuoteProviderFactory.make(.twelveData, apiKey: "k") != nil)
    }
}
