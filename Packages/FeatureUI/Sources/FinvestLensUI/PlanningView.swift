//
//  PlanningView.swift
//  FinvestLens — FeatureUI
//
//  The Planner destination (P9, docs/planning-design.md): the Debt Reduction
//  Planner, the Lifetime Planner, and the Tax Estimate — transparent models
//  over the user's own figures, every assumption on screen and editable, and
//  every projection labelled an estimate, not advice.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import Charts
import FinvestLensEngine
import FinvestLensReports

// MARK: - Hub

struct PlanningView: View {
    @Bindable var model: AppModel

    enum Tool: String, CaseIterable, Identifiable {
        case debt = "Debt Reduction"
        case lifetime = "Lifetime"
        case tax = "Tax Estimate"
        var id: String { rawValue }
    }
    @SceneStorage("planner.tool") private var tool: Tool = .debt

    var body: some View {
        VStack(spacing: 0) {
            Picker("Tool", selection: $tool) {
                ForEach(Tool.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: 480)

            switch tool {
            case .debt: DebtPlannerView(model: model)
            case .lifetime: LifetimePlannerView(model: model)
            case .tax: TaxEstimateView(model: model)
            }
        }
        .navigationTitle("Planner")
    }
}


/// The standing footnote every planning surface carries.
struct PlanningDisclaimer: View {
    var body: some View {
        Text("An estimate from your own figures and assumptions — not financial or tax advice.")
            .scaledFont(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Debt Reduction Planner (FR-PLAN-10)

struct DebtPlannerView: View {
    @Bindable var model: AppModel

    @State private var budget = ""
    @State private var strategy: DebtPlan.Strategy = .avalanche
    /// Per-debt APR% and minimum, string-backed for editing.
    @State private var aprs: [GncGUID: String] = [:]
    @State private var minimums: [GncGUID: String] = [:]

    private var debts: [DebtPlan.Debt] { model.plannerDebts() }
    private var code: String { model.reportCurrency.mnemonic }

    private func dec(_ s: String) -> Decimal { Decimal(string: s.trimmingCharacters(in: .whitespaces)) ?? 0 }

    /// The planner inputs as currently edited (percent fields are per-cent).
    private var editedDebts: [DebtPlan.Debt] {
        debts.map { debt in
            DebtPlan.Debt(id: debt.id, name: debt.name, balance: debt.balance,
                          apr: dec(aprs[debt.id] ?? "") / 100,
                          minimumPayment: dec(minimums[debt.id] ?? ""))
        }
    }

    private var results: (plan: DebtPlan.Result, baseline: DebtPlan.Result)? {
        guard !debts.isEmpty else { return nil }
        let edited = editedDebts
        let plan = DebtPlan.simulate(debts: edited, budget: dec(budget),
                                     strategy: strategy, currency: model.reportCurrency)
        let baseline = DebtPlan.simulate(debts: edited, budget: 0,
                                         strategy: .minimumsOnly, currency: model.reportCurrency)
        return (plan, baseline)
    }

    private var totalMinimums: Decimal {
        editedDebts.reduce(0) { $0 + $1.minimumPayment }
    }

    var body: some View {
        if debts.isEmpty {
            ContentUnavailableView("No debts to plan", systemImage: "checkmark.seal",
                                   description: Text("Liability and credit-card accounts with a balance owing appear here."))
        } else {
            Form {
                Section("Debts (balances from the book)") {
                    ForEach(debts) { debt in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(debt.name)
                                Text(AmountFormat.string(debt.balance, code: code))
                                    .scaledFont(.caption).foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Spacer()
                            TextField("APR %", text: binding($aprs, debt.id))
                                .frame(width: 70)
                                .multilineTextAlignment(.trailing)
                            TextField("Min / month", text: binding($minimums, debt.id))
                                .frame(width: 110)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
                Section("Plan") {
                    TextField("Monthly budget for debts", text: $budget)
                    Picker("Strategy", selection: $strategy) {
                        Text("Avalanche — highest rate first").tag(DebtPlan.Strategy.avalanche)
                        Text("Snowball — smallest balance first").tag(DebtPlan.Strategy.snowball)
                    }
                    if dec(budget) < totalMinimums {
                        Label("The budget is below the \(AmountFormat.string(totalMinimums, code: code)) of minimum payments.",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .scaledFont(.caption)
                    }
                }

                if let results {
                    resultSection(results)
                }

                Section { PlanningDisclaimer() }
            }
            .formStyle(.grouped)
            .onAppear(perform: load)
            .onDisappear(perform: persist)
            .onSubmit(persist)
        }
    }

    @ViewBuilder
    private func resultSection(_ results: (plan: DebtPlan.Result, baseline: DebtPlan.Result)) -> some View {
        let plan = results.plan
        let baseline = results.baseline
        Section("Payoff") {
            if !plan.underwater.isEmpty {
                Label("A minimum payment doesn't cover its debt's interest — it never pays off.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            if plan.paysOff {
                LabeledContent("Debt-free") {
                    Text(payoffDate(plan.months)).fontWeight(.semibold)
                }
                LabeledContent("Interest paid") {
                    Text(AmountFormat.string(plan.totalInterest, code: code)).monospacedDigit()
                }
                if baseline.paysOff, baseline.totalInterest > plan.totalInterest {
                    LabeledContent("Saved vs minimums only") {
                        Text("\(AmountFormat.string(baseline.totalInterest - plan.totalInterest, code: code))"
                             + " and \(baseline.months - plan.months) months")
                            .foregroundStyle(.green)
                    }
                }
            } else if plan.underwater.isEmpty {
                Label("This budget never clears the debts within 100 years.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            ForEach(plan.debts) { debt in
                LabeledContent(debt.name) {
                    Text(debt.payoffMonth >= DebtPlan.horizonMonths
                         ? "—" : payoffDate(debt.payoffMonth))
                        .foregroundStyle(.secondary)
                }
            }

            if plan.balanceSeries.count > 1 {
                Chart(Array(plan.balanceSeries.enumerated()), id: \.offset) { month, balance in
                    LineMark(x: .value("Month", month + 1),
                             y: .value("Owing", NSDecimalNumber(decimal: balance).doubleValue))
                        .interpolationMethod(.monotone)
                }
                .frame(height: 160)
                .accessibilityLabel("Total balance owing by month")
            }
        }
    }

    private func payoffDate(_ months: Int) -> String {
        let date = Calendar.current.date(byAdding: .month, value: months, to: Date()) ?? Date()
        return date.formatted(.dateTime.month(.abbreviated).year())
    }

    private func binding(_ store: Binding<[GncGUID: String]>, _ id: GncGUID) -> Binding<String> {
        Binding(get: { store.wrappedValue[id] ?? "" },
                set: { store.wrappedValue[id] = $0 })
    }

    private func load() {
        let settings = model.debtPlanSettings
        budget = settings.monthlyBudget == 0 ? "" : "\(settings.monthlyBudget)"
        strategy = settings.strategy == .minimumsOnly ? .avalanche : settings.strategy
        for input in settings.inputs {
            aprs[input.accountID] = input.apr == 0 ? "" : "\(input.apr * 100)"
            minimums[input.accountID] = input.minimumPayment == 0 ? "" : "\(input.minimumPayment)"
        }
    }

    private func persist() {
        let inputs = debts.map { debt in
            DebtInput(accountID: debt.id, apr: dec(aprs[debt.id] ?? "") / 100,
                      minimumPayment: dec(minimums[debt.id] ?? ""))
        }.filter { $0.apr != 0 || $0.minimumPayment != 0 }
        model.updateDebtPlanSettings(DebtPlanSettings(
            monthlyBudget: dec(budget), strategy: strategy, inputs: inputs))
    }
}

// MARK: - Lifetime Planner (FR-PLAN-11)

struct LifetimePlannerView: View {
    @Bindable var model: AppModel

    @State private var assumptions: LifetimeProjection.Assumptions?
    @State private var overrideBuckets = false
    @State private var buckets = LifetimeProjection.Buckets()
    @State private var todaysDollars = false
    // Add-event scratch fields.
    @State private var eventName = ""
    @State private var eventYear = ""
    @State private var eventAmount = ""

    private var code: String { model.reportCurrency.mnemonic }

    var body: some View {
        let seeded = model.seededLifetimeBuckets()
        let active = overrideBuckets ? buckets : seeded
        let current = assumptions ?? model.lifetimeAssumptions()
        let result = LifetimeProjection.project(
            start: active, assumptions: current,
            currentYear: Calendar.current.component(.year, from: Date()),
            taxSettings: model.currentTaxSettings())

        Form {
            verdict(result)

            if result.points.count > 1 {
                Section {
                    Toggle("Today's dollars", isOn: $todaysDollars)
                    chart(result)
                }
            }

            Section("About you") {
                DecimalTextField(label: "Birth year", value: intBinding(\.birthYear), scale: 1)
                DecimalTextField(label: "Retirement age", value: intBinding(\.retirementAge), scale: 1)
                DecimalTextField(label: "Plan to age", value: intBinding(\.lifeExpectancy), scale: 1)
            }

            Section("Income & spending (seeded from the last 12 months)") {
                moneyField("Annual income", value: bindingFor(\.annualIncome))
                percentField("Income growth %", value: bindingFor(\.incomeGrowth))
                moneyField("Annual living expenses", value: bindingFor(\.annualExpenses))
                percentField("Inflation %", value: bindingFor(\.inflation))
                moneyField("Retirement contribution / year", value: bindingFor(\.retirementContribution))
                percentField("Retirement spending % of expenses", value: bindingFor(\.retirementSpendShare))
                moneyField("Pension income / year (today's $)", value: bindingFor(\.pensionIncome))
            }

            Section("Returns % (nominal, net of fees)") {
                percentField("Cash", value: bindingFor(\.returnCash))
                percentField("Investments", value: bindingFor(\.returnInvestments))
                percentField("Retirement", value: bindingFor(\.returnRetirement))
                percentField("Property", value: bindingFor(\.returnProperty))
                percentField("Debt interest", value: bindingFor(\.debtInterest))
                moneyField("Debt repayment / year", value: bindingFor(\.debtRepayment))
            }

            bucketsSection(seeded: seeded, active: active)
            eventsSection(current)

            Section { PlanningDisclaimer() }
        }
        .formStyle(.grouped)
        .onAppear {
            assumptions = model.lifetimeAssumptions()
            if let saved = model.lifetimePlan.bucketOverrides {
                overrideBuckets = true
                buckets = saved
            }
        }
        .onDisappear(perform: persist)
        .onSubmit(persist)
    }

    // MARK: Sections

    @ViewBuilder
    private func verdict(_ result: LifetimeProjection.Result) -> some View {
        Section {
            if let depletion = result.depletionAge {
                Label("Funds run short at age \(depletion).", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fontWeight(.semibold)
            } else if let last = result.points.last {
                Label("Your money lasts to age \(last.age), ending near "
                      + AmountFormat.string(display(last.netWorth, last), code: code) + ".",
                      systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .fontWeight(.semibold)
            }
        }
    }

    private func chart(_ result: LifetimeProjection.Result) -> some View {
        Chart {
            ForEach(result.points) { point in
                ForEach(series(point), id: \.name) { layer in
                    AreaMark(x: .value("Age", point.age),
                             y: .value(layer.name, layer.value),
                             stacking: .standard)
                        .foregroundStyle(by: .value("Bucket", layer.name))
                }
                LineMark(x: .value("Age", point.age),
                         y: .value("Debts", -NSDecimalNumber(decimal: display(point.debts, point)).doubleValue))
                    .foregroundStyle(.red.opacity(0.6))
            }
            if let retirementAge = result.points.first(where: { $0.age == (assumptions ?? model.lifetimeAssumptions()).retirementAge })?.age {
                RuleMark(x: .value("Retire", retirementAge))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(dash: [4]))
            }
        }
        .frame(height: 220)
        .accessibilityLabel("Projected net worth by age, stacked by bucket")
    }

    private func series(_ point: LifetimeProjection.YearPoint)
        -> [(name: String, value: Double)] {
        [("Cash", point.cash), ("Investments", point.investments),
         ("Retirement", point.retirement), ("Property", point.property)]
            .map { ($0.0, NSDecimalNumber(decimal: display($0.1, point)).doubleValue) }
    }

    private func display(_ value: Decimal, _ point: LifetimeProjection.YearPoint) -> Decimal {
        guard todaysDollars, point.deflator != 0 else { return value }
        return value / point.deflator
    }

    @ViewBuilder
    private func bucketsSection(seeded: LifetimeProjection.Buckets,
                                active: LifetimeProjection.Buckets) -> some View {
        Section("Starting position (seeded from the book)") {
            Toggle("Customise", isOn: $overrideBuckets.animation())
                .onChange(of: overrideBuckets) { _, on in
                    if on, buckets == LifetimeProjection.Buckets() { buckets = seeded }
                    persist()
                }
            if overrideBuckets {
                moneyField("Cash", value: $buckets.cash)
                moneyField("Investments", value: $buckets.investments)
                moneyField("Retirement", value: $buckets.retirement)
                moneyField("Property", value: $buckets.property)
                moneyField("Debts", value: $buckets.debts)
            } else {
                LabeledContent("Cash") { amount(active.cash) }
                LabeledContent("Investments") { amount(active.investments) }
                LabeledContent("Retirement (SMSF/super by name)") { amount(active.retirement) }
                LabeledContent("Property & other assets") { amount(active.property) }
                LabeledContent("Debts") { amount(active.debts) }
            }
        }
    }

    @ViewBuilder
    private func eventsSection(_ current: LifetimeProjection.Assumptions) -> some View {
        Section("Life events (one-offs, + in or − out)") {
            ForEach(current.events) { event in
                HStack {
                    Text(event.name)
                    Spacer()
                    Text(String(event.year)).foregroundStyle(.secondary)
                    Text(AmountFormat.string(event.amount, code: code))
                        .monospacedDigit()
                        .foregroundStyle(event.amount < 0 ? .red : .primary)
                    Button(role: .destructive) {
                        update { $0.events.removeAll { $0.id == event.id } }
                        persist()
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(event.name)")
                }
            }
            HStack {
                TextField("Event", text: $eventName)
                TextField("Year", text: $eventYear).frame(width: 64)
                TextField("Amount", text: $eventAmount).frame(width: 110)
                Button("Add") {
                    guard let year = Int(eventYear.trimmingCharacters(in: .whitespaces)),
                          !eventName.isEmpty else { return }
                    let amount = Decimal(string: eventAmount.trimmingCharacters(in: .whitespaces)) ?? 0
                    update { $0.events.append(.init(name: eventName, year: year, amount: amount)) }
                    eventName = ""; eventYear = ""; eventAmount = ""
                    persist()
                }
                .disabled(eventName.isEmpty || Int(eventYear) == nil)
            }
        }
    }

    // MARK: Field plumbing

    private func update(_ change: (inout LifetimeProjection.Assumptions) -> Void) {
        var current = assumptions ?? model.lifetimeAssumptions()
        change(&current)
        assumptions = current
    }

    private func bindingFor(_ keyPath: WritableKeyPath<LifetimeProjection.Assumptions, Decimal>) -> Binding<Decimal> {
        Binding(get: { (assumptions ?? model.lifetimeAssumptions())[keyPath: keyPath] },
                set: { value in update { $0[keyPath: keyPath] = value } })
    }

    private func intBinding(_ keyPath: WritableKeyPath<LifetimeProjection.Assumptions, Int>) -> Binding<Decimal> {
        Binding(get: { Decimal((assumptions ?? model.lifetimeAssumptions())[keyPath: keyPath]) },
                set: { value in update { $0[keyPath: keyPath] = NSDecimalNumber(decimal: value).intValue } })
    }

    private func amount(_ value: Decimal) -> some View {
        Text(AmountFormat.string(value, code: code)).monospacedDigit().foregroundStyle(.secondary)
    }

    private func moneyField(_ label: String, value: Binding<Decimal>) -> some View {
        DecimalTextField(label: label, value: value, scale: 1)
    }

    /// Percent fields edit "3" for 0.03.
    private func percentField(_ label: String, value: Binding<Decimal>) -> some View {
        DecimalTextField(label: label, value: value, scale: 100)
    }

    private func persist() {
        model.updateLifetimePlan(StoredLifetimePlan(
            assumptions: assumptions,
            bucketOverrides: overrideBuckets ? buckets : nil))
    }
}

/// A labelled Decimal field over a string editor: `scale` maps the stored
/// value to the edited one (100 for percents).
private struct DecimalTextField: View {
    let label: String
    @Binding var value: Decimal
    let scale: Decimal
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent(label) {
            TextField(label, text: $text)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 140)
                .focused($focused)
                .onAppear { text = display(value) }
                .onChange(of: value) { _, fresh in
                    if !focused { text = display(fresh) }
                }
                .onChange(of: text) { _, fresh in
                    guard focused,
                          let parsed = Decimal(string: fresh.trimmingCharacters(in: .whitespaces))
                    else { return }
                    value = parsed / scale
                }
        }
    }

    private func display(_ value: Decimal) -> String {
        let scaled = value * scale
        return scaled == 0 ? "" : "\(scaled)"
    }
}


// MARK: - Wellbeing breakdown (FR-PLAN-16)

/// The score with its working shown in full — measures, targets, and points,
/// so nothing about the number is a mystery.
struct WellbeingSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let score = model.wellbeingScore() {
                    Form {
                        Section {
                            LabeledContent("Score") {
                                Text("\(score.total) / 100")
                                    .scaledFont(.title2, weight: .bold)
                                    .monospacedDigit()
                            }
                        }
                        Section("Components (0–25 each, last 3 months vs prior 3)") {
                            ForEach(score.components) { component in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(component.component.title)
                                        Spacer()
                                        Text("\(component.points) pts").monospacedDigit()
                                            .foregroundStyle(.secondary)
                                    }
                                    ProgressView(value: NSDecimalNumber(decimal: component.points).doubleValue,
                                                 total: 25)
                                    Text(explanation(component))
                                        .scaledFont(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        Section {
                            Text("A transparent indicator from your own books — savings rate (full marks at 20%), months of spending covered by cash (full at 6), non-mortgage debt against annual income (none at 60%), and the three-month spending trend. Not a judgement, and not advice.")
                                .scaledFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .formStyle(.grouped)
                } else {
                    ContentUnavailableView("No score yet", systemImage: "heart.text.square")
                }
            }
            .navigationTitle("Financial Wellbeing")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .frame(minWidth: 440, minHeight: 460)
    }

    private func explanation(_ component: WellbeingScore.ComponentScore) -> String {
        let measure = component.measure
        switch component.component {
        case .savingsRate:
            return "You kept \(SpendingInsights.wholePercent(measure * 100))% of income; 20% earns full marks."
        case .cashBuffer:
            return "Liquid funds cover \(SpendingInsights.wholePercent(measure)) months of spending; 6 months earns full marks."
        case .debtPressure:
            return "Non-mortgage debt is \(SpendingInsights.wholePercent(measure * 100))% of annual income; zero earns full marks."
        case .spendingTrend:
            let percent = SpendingInsights.wholePercent(abs(measure) * 100)
            return measure <= 0
                ? "Spending is flat or falling (\(percent)% down) — full marks."
                : "Spending is up \(percent)% on the prior three months; +25% scores zero."
        }
    }
}

// MARK: - Tax estimate (FR-PLAN-12)

struct TaxEstimateView: View {
    @Bindable var model: AppModel

    @State private var period: ReportPeriod = .currentFinancialYear
    @State private var showRates = false

    private var code: String { model.reportCurrency.mnemonic }

    var body: some View {
        let result = model.taxEstimateResult(period: period)
        Form {
            Section {
                Picker("Period", selection: $period) {
                    Text(model.label(for: .currentFinancialYear)).tag(ReportPeriod.currentFinancialYear)
                    Text(model.label(for: .previousFinancialYear)).tag(ReportPeriod.previousFinancialYear)
                }
                .pickerStyle(.segmented)
            }

            if result.income.isEmpty && result.deductions.isEmpty
                && result.netCapitalGains == 0 {
                Section {
                    Label("No accounts are tax-tagged yet.", systemImage: "tag.slash")
                    Button("Open Tax Report Options…") { model.presentedPanel = .taxOptions }
                        .help("Mark the income and deduction accounts your tax schedule draws on")
                }
            }

            if !result.income.isEmpty {
                Section("Assessable income") {
                    ForEach(result.income) { line in row(line.name, line.amount) }
                    LabeledContent("Total") { amount(result.assessableIncome, weight: .semibold) }
                }
            }
            if !result.deductions.isEmpty {
                Section("Deductions") {
                    ForEach(result.deductions) { line in row(line.name, line.amount) }
                    LabeledContent("Total") { amount(result.totalDeductions, weight: .semibold) }
                }
            }
            if result.shortTermGains != 0 || result.longTermGains != 0 || result.otherGains != 0 {
                Section("Capital gains (realised)") {
                    row("Held over 12 months", result.longTermGains)
                    row("Held under 12 months", result.shortTermGains)
                    if result.otherGains != 0 { row("Unknown holding period", result.otherGains) }
                    LabeledContent("Net after discount") { amount(result.netCapitalGains, weight: .semibold) }
                }
            }

            Section("Estimated tax") {
                LabeledContent("Taxable income") { amount(result.taxableIncome, weight: .semibold) }
                ForEach(result.bracketTaxes) { slice in
                    row("\(percent(slice.bracket.rate)) on \(AmountFormat.string(slice.taxedAmount, code: code))",
                        slice.tax)
                }
                row("Levy (\(percent(model.currentTaxSettings().levyRate)))", result.levy)
                if result.frankingCredits != 0 { row("Franking credits", -result.frankingCredits) }
                if result.withheld != 0 { row("Tax withheld", -result.withheld) }
                LabeledContent(result.balance >= 0 ? "Estimated owing" : "Estimated refund") {
                    Text(AmountFormat.string(abs(result.balance), code: code))
                        .monospacedDigit()
                        .fontWeight(.bold)
                        .foregroundStyle(result.balance >= 0 ? Color.primary : .green)
                }
            }

            Section {
                DisclosureGroup("Rate table", isExpanded: $showRates) {
                    ratesEditor
                }
                PlanningDisclaimer()
                Text("The levy is applied flat (no low-income phase-in); net capital losses are not offset against income. Franking and withholding accounts are recognised by name.")
                    .scaledFont(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var ratesEditor: some View {
        let settings = model.currentTaxSettings()
        ForEach(settings.brackets) { bracket in
            LabeledContent("Over \(AmountFormat.string(bracket.over, code: code))") {
                Text(percent(bracket.rate)).monospacedDigit()
            }
        }
        LabeledContent("Levy") { Text(percent(settings.levyRate)).monospacedDigit() }
        LabeledContent("CGT discount (>12 months)") {
            Text(percent(settings.longTermDiscount)).monospacedDigit()
        }
        if model.taxSettings != nil {
            Button("Reset to Australian defaults") { model.updateTaxSettings(nil) }
        } else {
            Text("Australian resident rates for \(model.label(for: .currentFinancialYear)). Editable in the book file when rules change.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ label: String, _ value: Decimal) -> some View {
        LabeledContent(label) { amount(value) }
    }

    private func amount(_ value: Decimal, weight: Font.Weight = .regular) -> some View {
        Text(AmountFormat.string(value, code: code))
            .monospacedDigit()
            .fontWeight(weight)
    }

    private func percent(_ rate: Decimal) -> String {
        "\(SpendingInsights.wholePercent(rate * 100))%"
    }
}
