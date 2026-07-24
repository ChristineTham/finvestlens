//
//  BudgetTests.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensEngine

@Suite("Budget")
struct BudgetTests {

    private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

    @Test("A flat amount applies to every period")
    func flatAmount() {
        let acct = GncGUID.random()
        var budget = Budget(name: "Monthly")
        budget.setAmount(dec("500"), for: acct)
        #expect(budget.amount(for: acct, period: 0) == dec("500"))
        #expect(budget.amount(for: acct, period: 5) == dec("500"))   // same each period
    }

    @Test("Per-period overrides beat the flat amount")
    func perPeriod() {
        let acct = GncGUID.random()
        var budget = Budget(name: "Yearly", numPeriods: 12)
        budget.setAmount(dec("500"), for: acct)          // default
        budget.setAmount(dec("800"), for: acct, period: 11)   // December spike
        #expect(budget.amount(for: acct, period: 0) == dec("500"))
        #expect(budget.amount(for: acct, period: 11) == dec("800"))
    }

    @Test("An unbudgeted account reads as zero, not unbudgeted (GnuCash)")
    func unbudgetedIsZero() {
        let budget = Budget(name: "Monthly")
        #expect(budget.amount(for: .random(), period: 0) == 0)
        #expect(budget.amount(for: .random()) == nil)   // the flat accessor still distinguishes
    }

    @Test("Per-period amounts survive Codable round-trip")
    func codableRoundTrip() throws {
        let acct = GncGUID.random()
        var budget = Budget(name: "Y", numPeriods: 4)
        budget.setAmount(dec("100"), for: acct)
        budget.setAmount(dec("250"), for: acct, period: 2)
        let data = try JSONEncoder().encode(budget)
        let back = try JSONDecoder().decode(Budget.self, from: data)
        #expect(back.numPeriods == 4)
        #expect(back.amount(for: acct, period: 2) == dec("250"))
        #expect(back.amount(for: acct, period: 0) == dec("100"))
    }
}

@Suite("Budget gaps")
struct BudgetGapTests {

    private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

    @Test("A line's id is its account, and overrides sit atop the flat amount")
    func lineIdentity() {
        let acct = GncGUID.random()
        let line = BudgetLine(accountGUID: acct, amount: dec("10"))
        #expect(line.id == acct)
        #expect(line.amount(inPeriod: 3) == dec("10"))
        var overridden = line
        overridden.periodAmounts[3] = dec("15")
        #expect(overridden.amount(inPeriod: 3) == dec("15"))
        #expect(overridden.amount(inPeriod: 2) == dec("10"))
    }

    @Test("setAmount replaces an existing line's flat amount")
    func replaceAmount() {
        let acct = GncGUID.random()
        var budget = Budget(name: "B")
        budget.setAmount(dec("100"), for: acct)
        budget.setAmount(dec("150"), for: acct)
        #expect(budget.lines.count == 1)
        #expect(budget.amount(for: acct) == dec("150"))
    }

    @Test("A per-period amount on a new account creates a zero-flat line")
    func perPeriodOnNewAccount() {
        let acct = GncGUID.random()
        var budget = Budget(name: "B")
        budget.setAmount(dec("99"), for: acct, period: 4)
        #expect(budget.amount(for: acct, period: 4) == dec("99"))
        #expect(budget.amount(for: acct, period: 0) == 0)
        #expect(budget.amount(for: acct) == 0)      // the flat default is zero
    }

    @Test("Rollover toggles only existing lines")
    func rollover() {
        let acct = GncGUID.random()
        var budget = Budget(name: "B")
        budget.setRollover(true, for: acct)          // no line yet → no-op
        #expect(budget.lines.isEmpty)
        budget.setAmount(dec("50"), for: acct)
        budget.setRollover(true, for: acct)
        #expect(budget.lines.first?.rollover == true)
        budget.setRollover(false, for: acct)
        #expect(budget.lines.first?.rollover == false)
    }

    @Test("numPeriods is clamped to at least one")
    func clampPeriods() {
        #expect(Budget(name: "B", numPeriods: 0).numPeriods == 1)
        #expect(Budget(name: "B", numPeriods: -3).numPeriods == 1)
    }

    @Test("Budgets saved before per-period amounts still decode")
    func legacyDecode() throws {
        let acct = GncGUID.random()
        let lineJSON = #"{"accountGUID":"\#(acct.hexString)","amount":250}"#
        let line = try JSONDecoder().decode(BudgetLine.self, from: Data(lineJSON.utf8))
        #expect(line.accountGUID == acct)
        #expect(line.amount == dec("250"))
        #expect(line.periodAmounts.isEmpty)
        #expect(!line.rollover)

        let id = GncGUID.random()
        let budgetJSON = #"{"id":"\#(id.hexString)","name":"Old"}"#
        let budget = try JSONDecoder().decode(Budget.self, from: Data(budgetJSON.utf8))
        #expect(budget.id == id)
        #expect(budget.name == "Old")
        #expect(budget.lines.isEmpty)
        #expect(budget.numPeriods == 12)
    }

    @Test("Rollover survives a Codable round-trip")
    func rolloverRoundTrip() throws {
        let acct = GncGUID.random()
        var budget = Budget(name: "R")
        budget.setAmount(dec("10"), for: acct)
        budget.setRollover(true, for: acct)
        let back = try JSONDecoder().decode(Budget.self, from: JSONEncoder().encode(budget))
        #expect(back.lines.first?.rollover == true)
        #expect(back == budget)
    }
}
