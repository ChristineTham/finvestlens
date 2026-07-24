//
//  FinancialReviewTests.swift
//  FinvestLens — FeatureUI
//
//  The Financial Review deck: slides appear only with meaningful data, every
//  slide carries a deterministic headline (Apple Intelligence only ever
//  improves one), and the net-worth bridge's steps reconcile exactly.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
import FinvestLensIntelligence
@testable import FinvestLensUI

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
}

@MainActor
@Suite("Financial Review deck")
struct FinancialReviewTests {

    /// A cash-only book: income, expenses, a liability — no securities, no
    /// dividends, activity in a single month.
    private func makeCashBook() throws -> (AppModel, URL, Date) {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let salary = try #require(model.addAccount(name: "Salary", type: .income))
        let food = try #require(model.addAccount(name: "Food", type: .expense))
        let loan = try #require(model.addAccount(name: "Loan", type: .liability))
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        func txn(_ amount: Decimal, from: GncGUID, to: GncGUID) throws {
            _ = try model.addTransaction(date: date, description: "t", currency: .aud,
                splits: [SplitInput(accountID: from, value: -amount),
                         SplitInput(accountID: to, value: amount)])
        }
        try txn(6_000, from: salary, to: bank)
        try txn(1_500, from: bank, to: food)
        try txn(2_000, from: loan, to: bank)
        return (model, url, date)
    }

    @Test("Slides appear only where the book has something to present")
    func slideSelection() throws {
        let (model, url, date) = try makeCashBook()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let slides = model.financialReviewSlides(
            from: date.addingTimeInterval(-86_400 * 30),
            to: date.addingTimeInterval(86_400), label: "Test period")
        let ids = slides.map(\.id)

        // Present: the always-on story slides.
        #expect(ids.contains("highlights"))
        #expect(ids.contains("bridge"))
        #expect(ids.contains("income"))
        #expect(ids.contains("spending"))
        #expect(ids.contains("position"))
        // Absent: no securities, no dividends, no disposals, one month only.
        #expect(!ids.contains("portfolio"))
        #expect(!ids.contains("dividends"))
        #expect(!ids.contains("gains"))
        #expect(!ids.contains("cashflow"))

        // Every slide has a deterministic voice and a bounded callout row.
        for slide in slides {
            #expect(!slide.headline.isEmpty, "slide \(slide.id) needs a headline")
            #expect(!slide.callouts.isEmpty && slide.callouts.count <= 4)
            #expect(!slide.facts.figures.isEmpty)
        }
    }

    @Test("The net-worth bridge reconciles: opening + surplus + valuation = closing")
    func bridgeReconciles() throws {
        let (model, url, date) = try makeCashBook()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        let from = date.addingTimeInterval(-86_400 * 30)
        let to = date.addingTimeInterval(86_400)

        let slides = model.financialReviewSlides(from: from, to: to, label: "Test")
        let bridge = try #require(slides.first { $0.id == "bridge" })

        func figure(_ label: String) -> Decimal {
            bridge.facts.figures.first { $0.0 == label }?.1 ?? 0
        }
        let opening = figure("Opening net worth")
        let income = figure("Income")
        let expenses = figure("Expenses")
        let valuation = figure("Valuation and currency movement")
        let closing = figure("Closing net worth")
        #expect(opening + income - expenses + valuation == closing)

        // And the closing figure is the engine's own net worth.
        let sheet = try #require(model.balanceSheet(asOf: to))
        #expect(closing == sheet.totalAssets - sheet.totalLiabilities)

        // The waterfall's anchors carry the same opening and closing.
        guard case .waterfall(let steps) = bridge.chart else {
            Issue.record("bridge slide should carry a waterfall"); return
        }
        #expect(steps.first?.end == opening)
        #expect(steps.last?.end == closing)
    }

    @Test("The story validator rejects numbers the facts don't contain")
    func storyValidation() {
        let facts = ReviewSlideFacts(
            kicker: "Net worth", periodLabel: "FY 2025–26", currencyCode: "AUD",
            figures: [("Closing net worth", Decimal(3_825_458.71)),
                      ("Net surplus", Decimal(145_432)),
                      ("Change in net worth", Decimal(50_194.68))],
            deltaPercents: [("Net worth", Decimal(string: "1.2")!)])

        // Grounded: quotes listed figures, rounded and abbreviated.
        let grounded = ReviewSlideStory(
            headline: "Net worth up 1.2% to $3.83m",
            insight: "The change of 50,194.68 AUD includes a 145k surplus, ending FY 2025–26 well.")
        #expect(ReviewStoryValidator.isGrounded(grounded, facts: facts))

        // Invented percentages (the exact live failure) are rejected.
        let invented = ReviewSlideStory(
            headline: "Net worth increased by 17.9%.",
            insight: "Driven by a 15.2% increase in income and a 7.4% decrease in expenses.")
        #expect(!ReviewStoryValidator.isGrounded(invented, facts: facts))

        // An invented absolute figure is rejected too.
        let inventedAbsolute = ReviewSlideStory(
            headline: "Net worth up 1.2%",
            insight: "Assets of 9,999,999 dominate the position.")
        #expect(!ReviewStoryValidator.isGrounded(inventedAbsolute, facts: facts))

        // Calendar years pass as dates, not figures.
        let withYear = ReviewSlideStory(
            headline: "A steady close to 2026",
            insight: "Net worth ended at 3.83m.")
        #expect(ReviewStoryValidator.isGrounded(withYear, facts: facts))
    }

    @Test("A dividend book gains the dividends slide with a grossed-up callout")
    func dividendSlide() throws {
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
        bhp.addChild(franked)
        model.refreshAll()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try model.addTransaction(date: date, description: "Dividend", currency: .aud,
            splits: [SplitInput(accountID: bank, value: 70),
                     SplitInput(accountID: franked.guid, value: -70)])

        let slides = model.financialReviewSlides(
            from: date.addingTimeInterval(-86_400), to: date.addingTimeInterval(86_400),
            label: "Test")
        let slide = try #require(slides.first { $0.id == "dividends" })
        #expect(slide.callouts.contains { $0.label == "Grossed-up" })
        #expect(slide.facts.figures.contains { $0.0 == "Franked dividends" && $0.1 == 70 })
    }
}
