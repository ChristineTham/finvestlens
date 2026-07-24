//
//  ReportCatalogueSyntheticTests.swift
//  FinvestLens — FeatureUI
//
//  The CI-runnable counterpart of the env-gated LiveReportCatalogueTests:
//  every scaffold report kind, under its default configuration, against a
//  small synthetic book — banking, an expense, a priced security with a
//  disposal, and a posted invoice. No network, no env vars.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
import FinvestLensReports
@testable import FinvestLensUI

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
}

@MainActor
@Suite("Report catalogue on a synthetic book")
struct ReportCatalogueSyntheticTests {

    @Test("Every scaffold kind builds its document under the default configuration")
    func catalogue() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        // Activity is posted "now" so it always falls inside the default
        // reporting period (the current financial year), whenever this runs.
        let now = Date()
        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let groceries = try #require(model.addAccount(name: "Groceries", type: .expense))
        let salary = try #require(model.addAccount(name: "Salary", type: .income))
        let sales = try #require(model.addAccount(name: "Sales", type: .income))
        let ar = try #require(model.addAccount(name: "Accounts Receivable", type: .receivable))
        let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                            fullName: "Commonwealth Bank", smallestFraction: 10000)
        let shares = try #require(model.addAccount(name: "CBA", type: .stock, commodity: cba))

        // A pay cheque and a grocery run.
        model.addTransfer(from: salary, to: bank, amount: dec("5000"), date: now, description: "Pay")
        model.addTransfer(from: bank, to: groceries, amount: dec("300"), date: now,
                          description: "Woolworths")
        // Buy 10 shares at $100, sell 4 at cost (a realised disposal, no gain),
        // and price the rest at $120.
        try model.addTransaction(date: now.addingTimeInterval(-60), description: "Buy CBA",
                                 currency: .aud, splits: [
            SplitInput(accountID: shares, value: dec("1000"), quantity: dec("10")),
            SplitInput(accountID: bank, value: dec("-1000"))])
        try model.addTransaction(date: now, description: "Sell CBA", currency: .aud, splits: [
            SplitInput(accountID: shares, value: dec("-400"), quantity: dec("-4")),
            SplitInput(accountID: bank, value: dec("400"))])
        model.addPrice(commodity: cba, currency: .aud, date: now, value: dec("120"))
        // A posted invoice, so the business reports have a customer to show.
        let customer = try #require(model.addCustomer(id: "C1", name: "Acme"))
        let invoice = try #require(model.createInvoice(
            id: "INV-1", kind: .invoice, ownerType: .customer, ownerID: customer,
            dateOpened: now, lines: [.init(accountID: sales, price: dec("100"))]))
        #expect(model.postInvoice(invoice, to: ar, postDate: now))

        // The single-account reports read the selection when unconfigured.
        model.selectedAccountID = bank

        // Kinds this small book must feed with real content; the remaining
        // scaffold kinds (payable/vendor/employee/job) legitimately render
        // empty-but-valid documents here.
        let mustHaveContent: Set<ReportKind> = [
            .balanceSheet, .incomeStatement, .equityStatement, .trialBalance,
            .accountSummary, .netWorth, .cashFlow, .incomeExpense, .averageBalance,
            .transactions, .reconcile, .spendingInsights,
            .portfolio, .investmentLots, .capitalGains,
            .receivableAging, .customerSummary,
        ]

        for kind in ReportKind.allCases where kind.usesScaffold {
            let configuration = kind.defaultConfiguration(for: model)
            let document = try #require(model.reportDocument(for: configuration),
                                        "\(kind.rawValue) built no document")
            #expect(!document.periodLabel.isEmpty, "\(kind.rawValue) has no period label")
            #expect(!document.title.isEmpty)
            if mustHaveContent.contains(kind) {
                #expect(!document.isEmpty, "\(kind.rawValue) produced an empty document")
            }
        }

        // The interactive tools' printable forms: prices exist, so the price
        // history prints; no scheduled activity, so the forecast prints nothing.
        #expect(model.priceHistoryDocument() != nil)
        #expect(model.forecastDocument() == nil)

        // Non-scaffold kinds never come back as documents.
        #expect(model.reportDocument(for: ReportKind.forecast.defaultConfiguration(for: model)) == nil)
        #expect(model.reportDocument(
            for: ReportKind.priceScatter.defaultConfiguration(for: model)) == nil)

        // Spot figures, pinned where the arithmetic is unambiguous.
        let incomeExpense = try #require(model.reportDocument(
            for: ReportKind.incomeExpense.defaultConfiguration(for: model)))
        #expect(incomeExpense.kpis.first { $0.label == "Expenses" }?.amount == dec("300"))
        #expect(incomeExpense.kpis.first { $0.label == "Income" }?.amount == dec("5100"))

        let transactions = try #require(model.reportDocument(
            for: ReportKind.transactions.defaultConfiguration(for: model)))
        #expect(transactions.title == "Transactions — Bank")
        #expect(transactions.sections.first?.rows.count == 4)      // pay, shop, buy, sell

        let portfolio = try #require(model.reportDocument(
            for: ReportKind.portfolio.defaultConfiguration(for: model)))
        #expect(portfolio.kpis.first { $0.label == "Market value" }?.amount == dec("720"))

        let customers = try #require(model.reportDocument(
            for: ReportKind.customerSummary.defaultConfiguration(for: model)))
        let acmeRow = try #require(customers.sections.first?.rows.first)
        #expect(acmeRow.label == "Acme")
        #expect(acmeRow.amounts == [dec("100"), 0, dec("100")])    // invoiced, paid, outstanding
    }

    @Test("With no book open no scaffold kind builds anything")
    func noBook() {
        let model = AppModel()
        for kind in ReportKind.allCases where kind.usesScaffold {
            #expect(model.reportDocument(for: kind.defaultConfiguration(for: model)) == nil)
        }
    }

    @Test("The forecast's printable document lists upcoming scheduled activity")
    func forecastDocument() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let salary = try #require(model.addAccount(name: "Salary", type: .income))
        let rent = try #require(model.addAccount(name: "Rent", type: .expense))
        model.addTransfer(from: salary, to: bank, amount: dec("1000"),
                          date: Date(timeIntervalSinceNow: -86_400), description: "Opening")
        model.addScheduledTransaction(ScheduledTransaction(
            name: "Rent", currency: .aud,
            recurrence: Recurrence(period: .monthly,
                                   startDate: Date(timeIntervalSinceNow: 7 * 86_400)),
            splits: [
                ScheduledSplit(accountGUID: rent, value: dec("800")),
                ScheduledSplit(accountGUID: bank, value: dec("-800")),
            ]))

        let document = try #require(model.forecastDocument())
        #expect(document.title == "Cash-Flow Forecast — Bank")
        #expect(!document.isEmpty)
        let section = try #require(document.sections.first)
        #expect(section.title == "Upcoming Activity")
        #expect(section.columns == ["Change", "Balance"])
        #expect(section.rows.contains { $0.label.contains("Rent") })
        #expect(!section.rows.contains { $0.label.contains("(what-if)") })
    }
}
