//
//  LivePlanningTests.swift
//  FinvestLens — FeatureUI
//
//  P9 exit criteria against the real book (plan.md §13): a debt-payoff plan
//  and a lifetime projection from real book data, and a tax estimate from
//  tagged tax lines. Env-gated on FL_PERF_FILE; works on a copy.
//
//      FL_PERF_FILE="/path/to/Book.finvestlens" \
//          swift test --filter LivePlanningTests
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
import FinvestLensReports
@testable import FinvestLensUI

private let perfPath = ProcessInfo.processInfo.environment["FL_PERF_FILE"]

@MainActor
@Suite(.serialized)
struct LivePlanningTests {

    @Test("Debt plan, lifetime projection, tax estimate, and insights from real data")
    func planningExitCriteria() async throws {
        guard let perfPath else { return }
        let source = URL(fileURLWithPath: perfPath)
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("flplan-\(UUID().uuidString).finvestlens")
        try FileManager.default.copyItem(at: source, to: copy)
        defer {
            try? FileManager.default.removeItem(at: copy)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: copy.path + ".audit.log"))
        }

        let model = AppModel()
        await model.openBook(at: copy, breakStaleLock: true)
        defer { model.close() }
        try #require(model.book != nil)

        // Bucket seeding: the SMSF lands in retirement by name; the book has
        // real cash, investments, and property.
        let buckets = model.seededLifetimeBuckets()
        print("🧮 buckets — cash \(buckets.cash), investments \(buckets.investments), "
              + "retirement \(buckets.retirement), property \(buckets.property), debts \(buckets.debts)")
        #expect(buckets.retirement > 0, "SMSF accounts should seed the retirement bucket")
        #expect(buckets.cash != 0)
        #expect(buckets.investments > 0)

        // Lifetime projection runs on the seeds with book-derived defaults.
        let projection = model.lifetimeResult()
        #expect(projection.points.count > 10)
        #expect(projection.points.first!.netWorth != 0)
        print("🧮 lifetime — \(projection.points.count) years, "
              + "ends age \(projection.points.last!.age) at \(projection.points.last!.netWorth); "
              + "depletion \(projection.depletionAge.map(String.init) ?? "never")")

        // Debt plan over the real liabilities (the ANZ VISA carries a balance).
        let debts = model.plannerDebts()
        #expect(!debts.isEmpty, "the book's credit cards should appear as planner debts")
        let planned = debts.map {
            DebtPlan.Debt(id: $0.id, name: $0.name, balance: $0.balance,
                          apr: Decimal(string: "0.20")!, minimumPayment: max(25, $0.balance / 50))
        }
        let plan = DebtPlan.simulate(debts: planned, budget: 5_000,
                                     strategy: .avalanche, currency: model.reportCurrency)
        #expect(plan.paysOff)
        print("🧮 debt — \(debts.count) debts, payoff in \(plan.months) months, "
              + "interest \(plan.totalInterest)")

        // Tax estimate: tag the top income and expense accounts on the COPY,
        // then the estimate must flow through brackets to a figure.
        let (from, to) = model.resolve(.previousFinancialYear)
        let candidates = model.taxAccounts(from: from, to: to)
            .sorted { abs($0.periodBalance) > abs($1.periodBalance) }
        let income = candidates.first { $0.typeName.caseInsensitiveCompare("income") == .orderedSame }
        let expense = candidates.first { $0.typeName.caseInsensitiveCompare("expense") == .orderedSame }
        for pick in [income, expense].compactMap({ $0 }) {
            model.setAccountTax(id: pick.id, related: true, code: nil)
        }
        let estimate = model.taxEstimateResult(period: .previousFinancialYear)
        #expect(estimate.assessableIncome > 0)
        #expect(estimate.baseTax > 0)
        print("🧮 tax — assessable \(estimate.assessableIncome), taxable \(estimate.taxableIncome), "
              + "base \(estimate.baseTax), levy \(estimate.levy), balance \(estimate.balance)")

        // Insights and wellbeing produce grounded reads.
        let insights = try #require(model.spendingInsights(period: .previousFinancialYear))
        let sentences = insights.summary { AmountFormat.string($0, code: model.reportCurrency.mnemonic) }
        #expect(!sentences.isEmpty)
        print("🧮 insights — \(sentences.first ?? "")")

        let wellbeing = try #require(model.wellbeingScore())
        #expect((0...100).contains(wellbeing.total))
        print("🧮 wellbeing — \(wellbeing.total)/100: "
              + wellbeing.components.map { "\($0.component.rawValue) \($0.points)" }.joined(separator: ", "))

        // The passport assembles from the same book.
        let passport = try #require(model.passportData())
        #expect(passport.netWorth != 0)
        #expect(!passport.assetClasses.isEmpty)
        print("🧮 passport — net worth \(passport.netWorth), "
              + "\(passport.assetClasses.count) asset classes, savings rate "
              + (passport.savingsRate.map { "\($0)" } ?? "n/a"))
    }
}
