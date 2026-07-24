//
//  AppModel+Planning.swift
//  FinvestLens — FeatureUI
//
//  P9 planning & insights (docs/planning-design.md): the Debt Reduction
//  Planner, Lifetime Planner, tax estimator, spending insights, wellbeing
//  score, savings challenges, and emergency records — the book-facing layer
//  over the pure calculators in FinvestLensReports.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensReports

// MARK: - Stored models (book KVP)

/// The user's figures for one debt — statements don't carry APR or minimums.
public struct DebtInput: Codable, Sendable, Equatable, Identifiable {
    public var id: GncGUID { accountID }
    public var accountID: GncGUID
    public var apr: Decimal
    public var minimumPayment: Decimal

    public init(accountID: GncGUID, apr: Decimal = 0, minimumPayment: Decimal = 0) {
        self.accountID = accountID
        self.apr = apr
        self.minimumPayment = minimumPayment
    }
}

public struct DebtPlanSettings: Codable, Sendable, Equatable {
    public var monthlyBudget: Decimal
    public var strategyRaw: String
    public var inputs: [DebtInput]

    public var strategy: DebtPlan.Strategy {
        get { DebtPlan.Strategy(rawValue: strategyRaw) ?? .avalanche }
        set { strategyRaw = newValue.rawValue }
    }

    public init(monthlyBudget: Decimal = 0, strategy: DebtPlan.Strategy = .avalanche,
                inputs: [DebtInput] = []) {
        self.monthlyBudget = monthlyBudget
        self.strategyRaw = strategy.rawValue
        self.inputs = inputs
    }
}

/// The Lifetime Planner's saved state: the assumptions plus any bucket
/// overrides (nil = use the book's seeded value).
public struct StoredLifetimePlan: Codable, Sendable, Equatable {
    public var assumptions: LifetimeProjection.Assumptions?
    public var bucketOverrides: LifetimeProjection.Buckets?

    public init(assumptions: LifetimeProjection.Assumptions? = nil,
                bucketOverrides: LifetimeProjection.Buckets? = nil) {
        self.assumptions = assumptions
        self.bucketOverrides = bucketOverrides
    }
}

/// A savings challenge decorating a goal (`FR-GOAL-02`): reach `targetAmount`
/// of *additional* saving between the two dates.
public struct SavingsChallenge: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var goalID: GncGUID
    public var name: String
    public var targetAmount: Decimal
    public var startDate: Date
    public var endDate: Date
    /// The goal's saved amount when the challenge began — progress is growth
    /// beyond this.
    public var startingSaved: Decimal

    public init(id: UUID = UUID(), goalID: GncGUID, name: String, targetAmount: Decimal,
                startDate: Date, endDate: Date, startingSaved: Decimal) {
        self.id = id
        self.goalID = goalID
        self.name = name
        self.targetAmount = targetAmount
        self.startDate = startDate
        self.endDate = endDate
        self.startingSaved = startingSaved
    }

    public enum Status: String, Sendable {
        case ahead, onTrack, behind, done, lapsed
    }

    /// Progress and pace against the straight line to the target.
    public func status(savedNow: Decimal, today: Date = Date()) -> (status: Status, progress: Decimal) {
        let progress = max(0, savedNow - startingSaved)
        if progress >= targetAmount { return (.done, progress) }
        if today >= endDate { return (.lapsed, progress) }
        let total = endDate.timeIntervalSince(startDate)
        guard total > 0, today > startDate else { return (.onTrack, progress) }
        let elapsed = today.timeIntervalSince(startDate) / total
        let expected = targetAmount * Decimal(elapsed)
        if progress >= expected * Decimal(string: "1.1")! { return (.ahead, progress) }
        if progress < expected * Decimal(string: "0.9")! { return (.behind, progress) }
        return (.onTrack, progress)
    }
}

/// One emergency record (`FR-PLAN-15`): structured details that travel with
/// the book.
public struct EmergencyRecord: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        case insurance, account, contact, document, other
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .insurance: "Insurance"
            case .account: "Account"
            case .contact: "Contact"
            case .document: "Document"
            case .other: "Other"
            }
        }
    }

    public struct Field: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var label: String
        public var value: String
        public init(id: UUID = UUID(), label: String = "", value: String = "") {
            self.id = id
            self.label = label
            self.value = value
        }
    }

    public var id: UUID
    public var kind: Kind
    public var title: String
    public var fields: [Field]
    public var notes: String
    public var updated: Date

    public init(id: UUID = UUID(), kind: Kind = .other, title: String = "",
                fields: [Field] = [], notes: String = "", updated: Date = Date()) {
        self.id = id
        self.kind = kind
        self.title = title
        self.fields = fields
        self.notes = notes
        self.updated = updated
    }
}

// MARK: - Planning accessors

@MainActor
extension AppModel {

    // MARK: Debt Reduction Planner (FR-PLAN-10)

    /// Open liabilities (credit/liability accounts with money owed), as the
    /// planner's debts — balances from the book, APR/minimums from the saved
    /// inputs.
    public func plannerDebts() -> [DebtPlan.Debt] {
        guard let book else { return [] }
        let inputs = Dictionary(uniqueKeysWithValues: debtPlanSettings.inputs.map { ($0.accountID, $0) })
        let balances = book.balancesByAccount(from: nil, to: Self.endOfToday())
        var debts: [DebtPlan.Debt] = []
        for account in book.accounts where !account.isPlaceholder {
            guard account.type == .credit || account.type == .liability else { continue }
            let owed = -(balances[ObjectIdentifier(account)] ?? 0)
            guard owed > 0 else { continue }
            let input = inputs[account.guid]
            debts.append(DebtPlan.Debt(id: account.guid, name: account.name,
                                       balance: account.commodity.round(owed),
                                       apr: input?.apr ?? 0,
                                       minimumPayment: input?.minimumPayment ?? 0))
        }
        return debts.sorted { $0.balance > $1.balance }
    }

    public func updateDebtPlanSettings(_ settings: DebtPlanSettings) {
        guard settings != debtPlanSettings else { return }
        debtPlanSettings = settings
        commitKvpCollections(named: "Change Debt Plan")
    }

    /// Runs the plan under the saved settings, plus the minimums-only baseline
    /// it is measured against.
    public func debtPlanResults() -> (plan: DebtPlan.Result, baseline: DebtPlan.Result)? {
        let debts = plannerDebts()
        guard !debts.isEmpty else { return nil }
        let plan = DebtPlan.simulate(debts: debts, budget: debtPlanSettings.monthlyBudget,
                                     strategy: debtPlanSettings.strategy, currency: reportCurrency)
        let baseline = DebtPlan.simulate(debts: debts, budget: 0,
                                         strategy: .minimumsOnly, currency: reportCurrency)
        return (plan, baseline)
    }

    // MARK: Lifetime Planner (FR-PLAN-11)

    /// Whether an account (or an ancestor) is a retirement bucket by name.
    nonisolated static func isRetirementAccount(_ account: Account) -> Bool {
        var current: Account? = account
        while let node = current {
            let name = node.name.lowercased()
            if name.contains("smsf") || name.contains("super")
                || name.contains("retirement") || name.contains("pension") {
                return true
            }
            current = node.parent
        }
        return false
    }

    /// The book-seeded buckets, before any user override.
    public func seededLifetimeBuckets() -> LifetimeProjection.Buckets {
        guard let book else { return LifetimeProjection.Buckets() }
        return cachedReport("lifetime.buckets:\(Self.endOfToday().timeIntervalSinceReferenceDate)") {
            FinancialReports.lifetimeBuckets(book, currency: reportCurrency,
                                             asOf: Self.endOfToday(),
                                             isRetirement: Self.isRetirementAccount)
        } ?? LifetimeProjection.Buckets()
    }

    /// The buckets the projection actually uses (overrides win field by field
    /// only when the whole override struct is present).
    public func lifetimeBuckets() -> LifetimeProjection.Buckets {
        lifetimePlan.bucketOverrides ?? seededLifetimeBuckets()
    }

    /// Assumptions: the saved ones, else defaults seeded from the last twelve
    /// months of the book (income, expenses).
    public func lifetimeAssumptions() -> LifetimeProjection.Assumptions {
        if let saved = lifetimePlan.assumptions { return saved }
        let now = Self.endOfToday()
        let calendar = Calendar.current
        let yearAgo = calendar.date(byAdding: .year, value: -1, to: now) ?? now
        var assumptions = LifetimeProjection.Assumptions(
            birthYear: calendar.component(.year, from: now) - 45)
        if let book {
            let breakdown = FinancialReports.categoryBreakdown(book, from: yearAgo, to: now,
                                                               currency: reportCurrency)
            assumptions.annualIncome = breakdown.totalIncome
            assumptions.annualExpenses = breakdown.totalExpenses
        }
        return assumptions
    }

    public func updateLifetimePlan(_ plan: StoredLifetimePlan) {
        guard plan != lifetimePlan else { return }
        lifetimePlan = plan
        commitKvpCollections(named: "Change Lifetime Plan")
    }

    public func lifetimeResult() -> LifetimeProjection.Result {
        let year = Calendar.current.component(.year, from: Self.endOfToday())
        return LifetimeProjection.project(start: lifetimeBuckets(),
                                          assumptions: lifetimeAssumptions(),
                                          currentYear: year,
                                          taxSettings: currentTaxSettings())
    }

    // MARK: Tax estimator (FR-PLAN-12)

    /// The bracket table in force: the saved one, else Australian resident
    /// rates for the book's current financial year.
    public func currentTaxSettings() -> TaxEstimate.Settings {
        if let taxSettings { return taxSettings }
        let (_, fyEnd) = resolve(.currentFinancialYear)
        let year = Calendar.current.component(.year, from: fyEnd)
        return TaxEstimate.Settings.australian(financialYearEnding: year)
    }

    public func updateTaxSettings(_ settings: TaxEstimate.Settings?) {
        guard settings != taxSettings else { return }
        taxSettings = settings
        commitKvpCollections(named: "Change Tax Settings")
    }

    /// Which side of the estimate a tax-tagged account feeds. Withholding
    /// (PAYG) and franking (imputation) accounts are recognised by name and
    /// counted as credits; the estimate screen shows the classification so
    /// nothing is hidden.
    nonisolated static func taxRole(name: String, typeName: String) -> TaxLineRole {
        let lowered = name.lowercased()
        let isIncome = typeName.caseInsensitiveCompare("income") == .orderedSame
        if lowered.contains("imputation") || lowered.contains("franking") {
            return .franking
        }
        if lowered.contains("payg") || lowered.contains("withheld")
            || lowered.contains("withholding") || lowered.contains("instalment") {
            return .withheld
        }
        return isIncome ? .income : .deduction
    }

    public enum TaxLineRole: Sendable { case income, deduction, franking, withheld }

    /// The FY-to-date estimate from tax-tagged accounts plus the realised
    /// capital-gains report.
    public func taxEstimateResult(period: ReportPeriod = .currentFinancialYear) -> TaxEstimate.Result {
        let (from, to) = resolve(period)
        let accounts = taxAccounts(from: from, to: to).filter(\.taxRelated)

        var income: [TaxEstimate.Line] = []
        var deductions: [TaxEstimate.Line] = []
        var franking = Decimal(0)
        var withheld = Decimal(0)
        for account in accounts {
            let line = TaxEstimate.Line(id: account.id, name: account.name,
                                        amount: account.periodBalance)
            switch Self.taxRole(name: account.name, typeName: account.typeName) {
            case .income: income.append(line)
            case .deduction: deductions.append(line)
            case .franking:
                // Grossed-up: franking credits are assessable income AND a
                // credit against the bill.
                income.append(line)
                franking += account.periodBalance
            case .withheld: withheld += account.periodBalance
            }
        }

        let gains = capitalGains(from: from, to: to)
        return TaxEstimate.estimate(
            income: income, deductions: deductions,
            shortTermGains: gains?.shortTermGain ?? 0,
            longTermGains: gains?.longTermGain ?? 0,
            otherGains: gains?.otherGain ?? 0,
            frankingCredits: franking, withheld: withheld,
            settings: currentTaxSettings())
    }

    // MARK: Spending insights (FR-PLAN-13)

    /// Compares a period against the immediately-preceding period of the same
    /// length.
    public func spendingInsights(period: ReportPeriod) -> SpendingInsights? {
        guard let book else { return nil }
        let (from, to) = resolve(period)
        let length = to.timeIntervalSince(from)
        let priorTo = from.addingTimeInterval(-1)
        let priorFrom = priorTo.addingTimeInterval(-length)
        return cachedReport("insights:\(from.timeIntervalSinceReferenceDate):\(to.timeIntervalSinceReferenceDate)") {
            FinancialReports.spendingInsights(book, from: from, to: to,
                                              priorFrom: priorFrom, priorTo: priorTo,
                                              currency: reportCurrency)
        }
    }

    // MARK: Wellbeing score (FR-PLAN-16)

    public func wellbeingScore() -> WellbeingScore.Result? {
        guard let book else { return nil }
        let now = Self.endOfToday()
        return cachedReport("wellbeing:\(now.timeIntervalSinceReferenceDate)") { () -> WellbeingScore.Result? in
            let calendar = Calendar.current
            let threeMonthsAgo = calendar.date(byAdding: .month, value: -3, to: now) ?? now
            let sixMonthsAgo = calendar.date(byAdding: .month, value: -6, to: now) ?? now
            let yearAgo = calendar.date(byAdding: .year, value: -1, to: now) ?? now

            let recent = FinancialReports.categoryBreakdown(book, from: threeMonthsAgo, to: now,
                                                            currency: reportCurrency)
            let prior = FinancialReports.categoryBreakdown(book, from: sixMonthsAgo,
                                                           to: threeMonthsAgo,
                                                           currency: reportCurrency)
            let year = FinancialReports.categoryBreakdown(book, from: yearAgo, to: now,
                                                          currency: reportCurrency)

            // Liquid funds and non-mortgage debt from the bucket walk.
            let buckets = FinancialReports.lifetimeBuckets(book, currency: reportCurrency,
                                                           asOf: now,
                                                           isRetirement: Self.isRetirementAccount)
            var mortgage = Decimal(0)
            let map = book.balancesByAccount(from: nil, to: now)
            for account in book.accounts where !account.isPlaceholder {
                guard account.type == .liability || account.type == .credit else { continue }
                let name = account.name.lowercased()
                guard name.contains("mortgage") || name.contains("home loan") else { continue }
                mortgage -= map[ObjectIdentifier(account)] ?? 0
            }

            return WellbeingScore.compute(.init(
                income3Months: recent.totalIncome,
                spending3Months: recent.totalExpenses,
                priorSpending3Months: prior.totalExpenses,
                liquidBalance: buckets.cash,
                monthlySpend: recent.totalExpenses / 3,
                nonMortgageDebt: max(0, buckets.debts - mortgage),
                annualIncome: year.totalIncome))
        }
    }

    // MARK: Savings challenges (FR-GOAL-02)

    public func addChallenge(goalID: GncGUID, name: String, target: Decimal,
                             start: Date, end: Date) {
        guard let goal = savingsGoals.first(where: { $0.id == goalID }) else { return }
        savingsChallenges.append(SavingsChallenge(
            goalID: goalID, name: name, targetAmount: target,
            startDate: start, endDate: end, startingSaved: goal.savedAmount))
        commitKvpCollections(named: "Add Challenge")
    }

    public func deleteChallenge(_ id: UUID) {
        savingsChallenges.removeAll { $0.id == id }
        commitKvpCollections(named: "Delete Challenge")
    }

    /// A challenge with its live status against its goal.
    public func challengeStatus(_ challenge: SavingsChallenge)
        -> (status: SavingsChallenge.Status, progress: Decimal) {
        let saved = savingsGoals.first { $0.id == challenge.goalID }?.savedAmount
            ?? challenge.startingSaved
        return challenge.status(savedNow: saved, today: Self.endOfToday())
    }

    // MARK: Emergency records (FR-PLAN-15)

    public func saveEmergencyRecord(_ record: EmergencyRecord) {
        var updated = record
        updated.updated = Date()
        if let index = emergencyRecords.firstIndex(where: { $0.id == record.id }) {
            emergencyRecords[index] = updated
        } else {
            emergencyRecords.append(updated)
        }
        commitKvpCollections(named: "Save Emergency Record")
    }

    public func deleteEmergencyRecord(_ id: UUID) {
        emergencyRecords.removeAll { $0.id == id }
        commitKvpCollections(named: "Delete Emergency Record")
    }
}
