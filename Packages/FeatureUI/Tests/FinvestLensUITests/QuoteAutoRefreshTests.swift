//
//  QuoteAutoRefreshTests.swift
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

private final class FixedHTTP: HTTPFetching, @unchecked Sendable {
    let body: Data
    init(_ s: String) { body = Data(s.utf8) }
    func data(for request: URLRequest) async throws -> Data { body }
}

private let chartJSON = """
{"chart":{"result":[{"meta":{"currency":"AUD","symbol":"CBA.AX",
"regularMarketPrice":105.20,"regularMarketTime":1700000000},
"timestamp":[1699800000],"indicators":{"quote":[{"close":[105.20]}]}}],"error":null}}
"""

@MainActor
@Suite("Quote auto-refresh")
struct QuoteAutoRefreshTests {

    @Test("Enabling auto-refresh and refreshing now adds a price")
    func refresh() async throws {
        let url = tempURL()
        let model = AppModel(quoteHTTP: FixedHTTP(chartJSON))
        try model.newDocument(at: url)
        defer { model.stopQuoteAutoRefresh(); model.close(); try? FileManager.default.removeItem(at: url) }

        let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                            fullName: "Commonwealth Bank", smallestFraction: 10000)
        _ = model.addAccount(name: "CBA", type: .stock, commodity: cba)

        // Off by default → no-op.
        await model.refreshQuotesNow()
        #expect(model.priceRows.isEmpty)

        model.autoRefreshQuotes = true
        model.stopQuoteAutoRefresh()   // avoid the periodic loop racing this test
        await model.refreshQuotesNow()
        #expect(model.priceRows.count == 1)
        #expect(model.priceRows.first?.value == dec("105.20"))
    }
}
