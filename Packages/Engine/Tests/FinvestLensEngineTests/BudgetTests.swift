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
