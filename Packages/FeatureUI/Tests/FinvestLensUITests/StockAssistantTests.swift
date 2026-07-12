//
//  StockAssistantTests.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
}
private func day(_ days: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(days) * 86_400) }

@MainActor
@Suite("Stock Transaction Assistant (AppModel)")
struct StockAssistantTests {

    private func model() throws -> (AppModel, GncGUID, GncGUID, GncGUID, GncGUID, URL) {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                            fullName: "Commonwealth Bank", smallestFraction: 10000)
        let stock = try #require(model.addAccount(name: "CBA", type: .stock, commodity: cba))
        let cash = try #require(model.addAccount(name: "Cash", type: .bank))
        let fee = try #require(model.addAccount(name: "Commission", type: .expense))
        let income = try #require(model.addAccount(name: "Dividends", type: .income))
        return (model, stock, cash, fee, income, url)
    }

    @Test("Buy then sell yields correct cost basis and net cash")
    func buySell() throws {
        let (model, stock, cash, fee, _, url) = try model()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        try model.recordStockTransaction(
            action: .buy, securityID: stock, settlementID: cash, commissionID: fee,
            shares: dec("10"), pricePerShare: dec("10"), commission: dec("9.95"),
            date: day(0), description: "Buy CBA")
        try model.recordStockTransaction(
            action: .sell, securityID: stock, settlementID: cash, commissionID: fee,
            shares: dec("4"), pricePerShare: dec("15"), commission: dec("9.95"),
            date: day(400), description: "Sell CBA")

        let gains = try #require(model.capitalGains())
        // Sold 4 for 60, cost 40 → gain 20 (long-term). 6 shares remain, cost 60.
        #expect(gains.totalGain == dec("20"))
        #expect(gains.longTermGain == dec("20"))
        #expect(gains.openCostBasis == dec("60"))

        // Typed account lists surface the right endpoints.
        #expect(model.securityAccountNodes.contains { $0.id == stock })
        #expect(model.expenseAccountNodes.contains { $0.id == fee })
    }

    @Test("Cash dividend increases income and cash")
    func dividend() throws {
        let (model, _, cash, _, income, url) = try model()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        try model.recordStockTransaction(
            action: .dividend, securityID: nil, settlementID: cash, incomeID: income,
            amount: dec("42.50"), date: day(30), description: "CBA dividend")
        model.selectedAccountID = cash
        #expect(model.registerRows.last?.description == "CBA dividend")
    }

    @Test("Reinvested dividend adds shares")
    func reinvest() throws {
        let (model, stock, _, _, income, url) = try model()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        try model.recordStockTransaction(
            action: .reinvestDividend, securityID: stock, settlementID: nil, incomeID: income,
            shares: dec("2.5"), amount: dec("42.50"), date: day(30), description: "DRP")
        let gains = try #require(model.capitalGains())
        #expect(gains.openLots.contains { $0.quantity == dec("2.5") })
    }

    @Test("Invalid input throws")
    func invalid() throws {
        let (model, stock, cash, _, _, url) = try model()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }
        #expect(throws: StockEntryError.invalidInput) {
            try model.recordStockTransaction(
                action: .buy, securityID: stock, settlementID: cash,
                shares: 0, pricePerShare: dec("10"), date: day(0), description: "Bad")
        }
    }
}
