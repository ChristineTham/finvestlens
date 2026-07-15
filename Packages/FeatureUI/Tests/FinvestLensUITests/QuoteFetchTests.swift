//
//  QuoteFetchTests.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
import FinvestLensQuotes
@testable import FinvestLensUI

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
}

/// Stub transport returning a fixed Yahoo chart body for any request.
private final class FixedHTTP: HTTPFetching, @unchecked Sendable {
    let body: Data
    init(_ string: String) { body = Data(string.utf8) }
    func data(for request: URLRequest) async throws -> Data { body }
}

private let chartJSON = """
{"chart":{"result":[{"meta":{"currency":"AUD","symbol":"CBA.AX",
"regularMarketPrice":105.20,"regularMarketTime":1700000000},
"timestamp":[1699800000],"indicators":{"quote":[{"close":[105.20]}]}}],"error":null}}
"""

@MainActor
@Suite("Quote fetching (AppModel)")
struct QuoteFetchTests {

    private func modelWithSecurity(_ http: HTTPFetching, keys: APIKeyStoring = InMemoryAPIKeyStore()) throws -> (AppModel, Commodity, URL) {
        let url = tempURL()
        let model = AppModel(apiKeys: keys, quoteHTTP: http)
        try model.newDocument(at: url)
        let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                            fullName: "Commonwealth Bank", smallestFraction: 10000)
        _ = model.addAccount(name: "CBA", type: .stock, commodity: cba)
        return (model, cba, url)
    }

    @Test("Fetching latest quotes adds a price and reports success")
    func fetchLatest() async throws {
        let (model, cba, url) = try modelWithSecurity(FixedHTTP(chartJSON))
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        model.setQuoteSymbol("CBA.AX", for: cba)

        await model.fetchLatestQuotes(using: .yahoo)

        #expect(model.quoteStatus == .success(1))
        #expect(model.priceRows.count == 1)
        #expect(model.priceRows.first?.value == dec("105.20"))
        #expect(model.hasUnsavedChanges)
    }

    @Test("Yahoo is available; keyed providers need a key")
    func availability() throws {
        let keys = InMemoryAPIKeyStore([.finnhub: "abc"])
        let (model, _, url) = try modelWithSecurity(FixedHTTP(chartJSON), keys: keys)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        #expect(model.availableProviders.contains(.yahoo))
        #expect(model.availableProviders.contains(.finnhub))
        #expect(model.availableProviders.contains(.eodhd) == false)
    }

    @Test("Ticker override persists via the book KVP")
    func symbolPersists() async throws {
        let (model, cba, url) = try modelWithSecurity(FixedHTTP(chartJSON))
        model.setQuoteSymbol("CBA.AX", for: cba)
        #expect(model.quoteSymbol(for: cba) == "CBA.AX")
        try model.save()
        model.close()

        let reopened = AppModel()
        try await reopened.open(at: url)
        defer { reopened.close(); try? FileManager.default.removeItem(at: url) }
        #expect(reopened.quoteSymbol(for: cba) == "CBA.AX")
    }
}
