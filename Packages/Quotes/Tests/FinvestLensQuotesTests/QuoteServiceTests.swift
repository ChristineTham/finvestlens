//
//  QuoteServiceTests.swift
//  FinvestLens — Quotes
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensQuotes

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

@Suite("Quote service")
struct QuoteServiceTests {

    private let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                                fullName: "Commonwealth Bank", smallestFraction: 10000)

    @Test("Latest quote maps to a Price in the requested currency")
    func latestPrice() async throws {
        let http = StubHTTPClient()
        http.on("chart", body: YahooProviderTests.chartJSON)
        let service = QuoteService(keys: InMemoryAPIKeyStore(), http: http)
        let price = try await service.latestPrice(for: cba, in: .aud, using: .yahoo, symbolOverride: "CBA.AX")
        #expect(price.commodity == cba)
        #expect(price.currency == .aud)
        #expect(price.value == dec("105.20"))
        #expect(price.source == "Finance::Quote:yahoo")
    }

    @Test("History maps to one Price per observation")
    func history() async throws {
        let http = StubHTTPClient()
        http.on("chart", body: YahooProviderTests.chartJSON)
        let service = QuoteService(keys: InMemoryAPIKeyStore(), http: http)
        let prices = try await service.historicalPrices(
            for: cba, in: .aud,
            from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 1_800_000_000),
            using: .yahoo, symbolOverride: "CBA.AX")
        #expect(prices.count == 2)
        #expect(prices.allSatisfy { $0.currency == .aud && $0.commodity == cba })
    }

    @Test("Keyed provider without a key throws missingAPIKey")
    func missingKey() async throws {
        let service = QuoteService(keys: InMemoryAPIKeyStore(), http: StubHTTPClient())
        await #expect(throws: QuoteError.missingAPIKey(.eodhd)) {
            _ = try await service.latestPrice(for: cba, in: .aud, using: .eodhd)
        }
    }

    @Test("Configured key builds an EODHD provider")
    func configuredKey() async throws {
        let http = StubHTTPClient()
        http.on("real-time", body: #"{"code":"CBA.AU","timestamp":1700000000,"close":105.20}"#)
        let keys = InMemoryAPIKeyStore([.eodhd: "SECRET"])
        let service = QuoteService(keys: keys, http: http)
        let price = try await service.latestPrice(for: cba, in: .aud, using: .eodhd, symbolOverride: "CBA.AU")
        #expect(price.value == dec("105.20"))
        #expect(price.source == "Finance::Quote:eodhd")
    }

    @Test("Symbol defaults to the commodity mnemonic")
    func symbolDefault() {
        #expect(QuoteService.symbol(for: cba) == "CBA")
        #expect(QuoteService.symbol(for: cba, override: "CBA.AX") == "CBA.AX")
    }
}

@Suite("In-memory key store")
struct APIKeyStoreTests {

    @Test("Set, read, and clear a key")
    func roundTrip() throws {
        let store = InMemoryAPIKeyStore()
        #expect(store.key(for: .finnhub) == nil)
        try store.setKey("abc", for: .finnhub)
        #expect(store.key(for: .finnhub) == "abc")
        try store.setKey("", for: .finnhub)
        #expect(store.key(for: .finnhub) == nil)
    }

    @Test("Provider metadata is consistent")
    func metadata() {
        #expect(QuoteProviderKind.yahoo.requiresAPIKey == false)
        #expect(QuoteProviderKind.eodhd.requiresAPIKey)
        #expect(QuoteProviderKind.finnhub.supportsHistory == false)
        #expect(QuoteProviderKind.stooq.requiresAPIKey == false)
        #expect(QuoteProviderKind.twelveData.supportsHistory)
        #expect(QuoteProviderKind.allCases.count == 6)
    }
}

@Suite("Provider symbol mapping")
struct ProviderSymbolTests {
    @Test("EODHD exchange-qualifies: Yahoo .AX becomes .AU, bare US becomes .US")
    func eodhd() {
        #expect(QuoteProviderKind.eodhd.providerSymbol(for: "CBA.AX") == "CBA.AU")
        #expect(QuoteProviderKind.eodhd.providerSymbol(for: "AAPL") == "AAPL.US")
        #expect(QuoteProviderKind.eodhd.providerSymbol(for: "CBA.NZ") == "CBA.NZ")
    }

    @Test("Stooq is lowercase with .au / .us")
    func stooq() {
        #expect(QuoteProviderKind.stooq.providerSymbol(for: "CBA.AX") == "cba.au")
        #expect(QuoteProviderKind.stooq.providerSymbol(for: "AAPL") == "aapl.us")
    }

    @Test("Yahoo passes the canonical symbol through unchanged")
    func yahoo() {
        #expect(QuoteProviderKind.yahoo.providerSymbol(for: "CBA.AX") == "CBA.AX")
        #expect(QuoteProviderKind.yahoo.providerSymbol(for: "AAPL") == "AAPL")
    }
}
