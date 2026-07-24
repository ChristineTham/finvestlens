//
//  PlanningIntegrationTests.swift
//  FinvestLens — FeatureUI
//
//  P9's book-facing layer: KVP persistence, tax-line classification, bucket
//  seeding, wellbeing inputs, and challenge pacing (docs/planning-design.md).
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
import FinvestLensReports
@testable import FinvestLensUI

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("finvestlens")
}

private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
    var c = DateComponents(); c.year = y; c.month = m; c.day = d
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    return cal.date(from: c)!
}

@MainActor
@Suite("Planning integration")
struct PlanningIntegrationTests {

    @Test("Planning collections persist through the book's KVP slots")
    func kvpRoundTrip() async throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        _ = try #require(model.addAccount(name: "Visa", type: .credit))

        // Debt plan, lifetime plan, tax settings, a record — all committed.
        model.updateDebtPlanSettings(DebtPlanSettings(
            monthlyBudget: 800, strategy: .snowball,
            inputs: [DebtInput(accountID: bank, apr: Decimal(string: "0.199")!,
                               minimumPayment: 50)]))
        var assumptions = LifetimeProjection.Assumptions(birthYear: 1980)
        assumptions.annualIncome = 120_000
        model.updateLifetimePlan(StoredLifetimePlan(assumptions: assumptions))
        var tax = TaxEstimate.Settings.australian(financialYearEnding: 2027)
        tax.levyRate = Decimal(string: "0.015")!
        model.updateTaxSettings(tax)
        model.saveEmergencyRecord(EmergencyRecord(
            kind: .insurance, title: "Home & contents",
            fields: [.init(label: "Policy", value: "H-123456")]))

        try model.save()
        model.close()
        try await model.open(at: url)
        defer { model.close() }

        #expect(model.debtPlanSettings.strategy == .snowball)
        #expect(model.debtPlanSettings.inputs.first?.minimumPayment == 50)
        #expect(model.lifetimePlan.assumptions?.annualIncome == 120_000)
        #expect(model.taxSettings?.levyRate == Decimal(string: "0.015"))
        #expect(model.emergencyRecords.first?.title == "Home & contents")
        #expect(model.emergencyRecords.first?.fields.first?.value == "H-123456")
    }

    @Test("Tax estimate classifies tagged accounts and applies franking/withholding")
    func taxEstimateFromTags() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let salary = try #require(model.addAccount(name: "Salary", type: .income))
        let franking = try #require(model.addAccount(name: "Imputation Credits", type: .income))
        let payg = try #require(model.addAccount(name: "PAYG Withheld", type: .expense))
        let deduction = try #require(model.addAccount(name: "Work Expenses", type: .expense))

        // FY 2026–27 activity (the book is AUD → July FY): salary 100k with
        // 20k withheld, 1.5k franking, 2k deductions.
        model.addTransfer(from: salary, to: bank, amount: 100_000,
                          date: day(2026, 7, 10), description: "Pay")
        model.addTransfer(from: bank, to: payg, amount: 20_000,
                          date: day(2026, 7, 10), description: "PAYG")
        model.addTransfer(from: franking, to: bank, amount: 1_500,
                          date: day(2026, 7, 11), description: "Franking")
        model.addTransfer(from: bank, to: deduction, amount: 2_000,
                          date: day(2026, 7, 12), description: "Laptop")

        for id in [salary, franking, payg, deduction] {
            model.setAccountTax(id: id, related: true, code: nil)
        }

        let result = model.taxEstimateResult(period: .currentFinancialYear)
        #expect(result.assessableIncome == 101_500)      // salary + grossed-up franking
        #expect(result.totalDeductions == 2_000)
        #expect(result.frankingCredits == 1_500)
        #expect(result.withheld == 20_000)
        #expect(result.taxableIncome == 99_500)
        // FY 2026-27: 26,800 @ 15% + 54,500 @ 30% = 20,370; levy 1,990.
        #expect(result.baseTax == Decimal(string: "20370"))
        #expect(result.balance == Decimal(string: "20370")! + 1_990 - 1_500 - 20_000)
    }

    @Test("Lifetime buckets classify by type with retirement detected by name")
    func bucketSeeding() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Everyday", type: .bank))
        let smsf = try #require(model.addAccount(name: "SMSF Cash", type: .bank))
        let visa = try #require(model.addAccount(name: "Visa", type: .credit))
        let equity = try #require(model.addAccount(name: "Opening", type: .equity))

        model.addTransfer(from: equity, to: bank, amount: 10_000,
                          date: day(2026, 1, 1), description: "Opening")
        model.addTransfer(from: equity, to: smsf, amount: 50_000,
                          date: day(2026, 1, 1), description: "Opening")
        model.addTransfer(from: visa, to: bank, amount: 3_000,
                          date: day(2026, 2, 1), description: "Drawdown")

        let buckets = model.seededLifetimeBuckets()
        #expect(buckets.cash == 13_000)          // everyday + drawn cash
        #expect(buckets.retirement == 50_000)    // "SMSF" in the name
        #expect(buckets.debts == 3_000)          // owed on the card
        _ = bank

        // A projection over these seeds runs end to end.
        let result = model.lifetimeResult()
        #expect(!result.points.isEmpty)
    }

    @Test("Wellbeing score computes from recent book activity")
    func wellbeing() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let salary = try #require(model.addAccount(name: "Salary", type: .income))
        let rent = try #require(model.addAccount(name: "Rent", type: .expense))
        let calendar = Calendar.current
        for monthsAgo in 0..<6 {
            let date = calendar.date(byAdding: .month, value: -monthsAgo, to: Date())!
            model.addTransfer(from: salary, to: bank, amount: 10_000,
                              date: date, description: "Pay")
            model.addTransfer(from: bank, to: rent, amount: 7_000,
                              date: date, description: "Rent")
        }

        let score = try #require(model.wellbeingScore())
        #expect(score.total > 0 && score.total <= 100)
        let byKind = Dictionary(uniqueKeysWithValues: score.components.map { ($0.component, $0) })
        // 30% savings rate → full marks; no debt → full marks.
        #expect(byKind[.savingsRate]!.points == 25)
        #expect(byKind[.debtPressure]!.points == 25)
        _ = bank
    }

    @Test("Challenges pace against the straight line to the target")
    func challengePacing() {
        let goalID = GncGUID.random()
        let challenge = SavingsChallenge(
            goalID: goalID, name: "Winter saver", targetAmount: 1_000,
            startDate: day(2026, 7, 1), endDate: day(2026, 7, 31),
            startingSaved: 500)

        // Halfway through, 500 of 1,000 expected: 500 saved is on track,
        // 700 ahead, 300 behind; hitting the target is done; time out lapses.
        let mid = day(2026, 7, 16)
        #expect(challenge.status(savedNow: 1_000, today: mid).status == .onTrack)
        #expect(challenge.status(savedNow: 1_200, today: mid).status == .ahead)
        #expect(challenge.status(savedNow: 800, today: mid).status == .behind)
        #expect(challenge.status(savedNow: 1_500, today: mid).status == .done)
        #expect(challenge.status(savedNow: 800, today: day(2026, 8, 2)).status == .lapsed)
    }

    @Test("The audit log records edit operations beside the book")
    func auditTrail() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer {
            model.close()
            try? FileManager.default.removeItem(at: url)
            if let log = model.auditLogURL { try? FileManager.default.removeItem(at: log) }
        }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let food = try #require(model.addAccount(name: "Food", type: .expense))
        model.addTransfer(from: bank, to: food, amount: 42,
                          date: day(2026, 7, 1), description: "Lunch")

        let tail = model.auditLogTail()
        #expect(!tail.isEmpty)
        #expect(tail.contains { $0.operation.localizedCaseInsensitiveContains("account")
            || $0.operation.localizedCaseInsensitiveContains("transaction") })
        // Timestamps parse as ISO-8601.
        #expect(ISO8601DateFormatter().date(from: tail.first!.date) != nil)
    }
}
