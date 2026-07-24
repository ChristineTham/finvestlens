//
//  FYPackTests.swift
//  FinvestLens — FeatureUI
//
//  The Financial Year Pack's one new computation: the Dividends & Franking
//  summary, classified per security by account name under the Dividends
//  income tree — the same shape the app books dividend statements into.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
}

@MainActor
@Suite("Financial Year Pack")
struct FYPackTests {

    @Test("Dividends classify per security into franked / unfranked / credits")
    func dividendClassification() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "CDIA", type: .bank))
        let income = try #require(model.book?.account(with:
            model.addAccount(name: "Income", type: .income)!))
        let dividends = Account(name: "Dividends", type: .income, commodity: .aud)
        income.addChild(dividends)
        let bhp = Account(name: "BHP", type: .income, commodity: .aud)
        dividends.addChild(bhp)
        let franked = Account(name: "Franked", type: .income, commodity: .aud)
        let credit = Account(name: "Imputation Credit", type: .income, commodity: .aud)
        bhp.addChild(franked)
        bhp.addChild(credit)
        let vas = Account(name: "VAS", type: .income, commodity: .aud)
        dividends.addChild(vas)
        let unfranked = Account(name: "Unfranked", type: .income, commodity: .aud)
        vas.addChild(unfranked)
        // The credit's non-cash offset, as the app books it.
        let offset = try #require(model.book?.account(with:
            model.addAccount(name: "Franking Credit Offset", type: .expense)!))
        model.refreshAll()

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        // Franked $70 with $30 credit: cash 70 in, credit offset by expense.
        _ = try model.addTransaction(date: date, description: "BHP Dividend", currency: .aud,
            splits: [SplitInput(accountID: bank, value: 70),
                     SplitInput(accountID: franked.guid, value: -70),
                     SplitInput(accountID: credit.guid, value: -30),
                     SplitInput(accountID: offset.guid, value: 30)])
        // Unfranked $40.
        _ = try model.addTransaction(date: date, description: "VAS Distribution", currency: .aud,
            splits: [SplitInput(accountID: bank, value: 40),
                     SplitInput(accountID: unfranked.guid, value: -40)])

        let doc = try #require(model.dividendFrankingDocument(
            from: date.addingTimeInterval(-86_400), to: date.addingTimeInterval(86_400),
            periodLabel: "FY test"))

        #expect(doc.kpis.first { $0.label == "Franked" }?.amount == 70)
        #expect(doc.kpis.first { $0.label == "Unfranked" }?.amount == 40)
        #expect(doc.kpis.first { $0.label == "Franking credits" }?.amount == 30)

        let frankedSection = try #require(doc.sections.first { $0.title == "Franked dividends" })
        #expect(frankedSection.rows.map(\.label) == ["BHP"])
        let unfrankedSection = try #require(doc.sections.first { $0.title == "Unfranked dividends" })
        #expect(unfrankedSection.rows.map(\.label) == ["VAS"])
        let grossed = try #require(doc.sections.first { $0.title == "Grossed-up total" })
        #expect(grossed.total?.amount == 140)

        // The pack skips reports with nothing to say, and includes this one.
        let (from, to) = (date.addingTimeInterval(-86_400), date.addingTimeInterval(86_400))
        let pack = model.financialYearPackPages(from: from, to: to, label: "FY test")
        #expect(pack.contains { $0.title == "Dividends & Franking" })
        #expect(pack.contains { $0.title == "Income Statement" })
        #expect(pack.contains { $0.title == "Statement of Financial Position" })
        #expect(pack.contains { $0.title == "Statement of Changes in Net Worth" })
    }

    @Test("No dividend income → no dividend document")
    func absentWhenNoDividends() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        _ = model.addAccount(name: "Bank", type: .bank)
        #expect(model.dividendFrankingDocument(
            from: .distantPast, to: .distantFuture, periodLabel: "FY") == nil)
    }
}
