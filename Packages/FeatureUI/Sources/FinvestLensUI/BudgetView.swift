//
//  BudgetView.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import FinvestLensEngine
import FinvestLensReports

/// Shows this month's budget-vs-actual with progress bars (`FR-BUD-02`).
struct BudgetView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingEdit = false
    @State private var showingSuggest = false

    private var budget: Budget? { model.budgets.first }

    var body: some View {
        NavigationStack {
            Group {
                if let budget {
                    let actuals = model.budgetActuals(budget)
                    if actuals.isEmpty {
                        ContentUnavailableView("No budget lines", systemImage: "chart.bar.doc.horizontal",
                                               description: Text("Edit the budget to set amounts for your expense accounts."))
                    } else {
                        List {
                            if let summary = model.budgetSummary(budget), summary.incomeBudget != 0 {
                                Section("Zero-based") {
                                    let code = model.reportCurrency.mnemonic
                                    LabeledContent("Income budgeted", value: AmountFormat.string(summary.incomeBudget, code: code))
                                    LabeledContent("Expenses budgeted", value: AmountFormat.string(summary.expenseBudget, code: code))
                                    HStack {
                                        Text("To allocate").fontWeight(.medium)
                                        Spacer()
                                        Text(AmountFormat.string(summary.unallocated, code: code))
                                            .monospacedDigit()
                                            .foregroundStyle(summary.unallocated == 0 ? .green : .orange)
                                    }
                                }
                            }
                            Section {
                                ForEach(actuals) { actual in
                                    BudgetRow(actual: actual, code: model.reportCurrency.mnemonic)
                                }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView {
                        Label("No budget", systemImage: "chart.bar")
                    } description: {
                        Text("Create a monthly budget to track spending.")
                    } actions: {
                        Button("Create Budget") { model.addBudget(Budget(name: "Monthly")) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Budget")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if model.isIntelligenceAvailable {
                    ToolbarItem {
                        Button("Suggest Budget", systemImage: "sparkles") { showingSuggest = true }
                            .help("Propose a monthly budget from your spending with Apple Intelligence")
                            .sheet(isPresented: $showingSuggest) {
                                BudgetSuggestSheet(model: model)
                            }
                    }
                }
                if let budget {
                    ToolbarItem {
                        Button("Auto-budget", systemImage: "wand.and.stars.inverse") {
                            model.autoBudget(budget.id, months: 3)
                        }
                    }
                    ToolbarItem {
                        Button("Edit Amounts", systemImage: "slider.horizontal.3") { showingEdit = true }
                            .sheet(isPresented: $showingEdit) {
                                EditBudgetSheet(model: model, budget: budget)
                            }
                    }
                }
            }
        }
        .frame(minWidth: 500, minHeight: 420)
    }
}

private struct BudgetRow: View {
    let actual: BudgetActual
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(actual.accountName)
                if actual.carryover != 0 {
                    Text("rollover \(AmountFormat.string(actual.carryover, code: code))")
                        .scaledFont(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 4).background(.secondary.opacity(0.15)).clipShape(Capsule())
                }
                Spacer()
                Text("\(AmountFormat.string(actual.actual, code: code)) of \(AmountFormat.string(actual.effectiveBudget, code: code))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(1.0, max(0, actual.fractionUsed ?? 0)))
                .tint(actual.isOverBudget ? .red : .accentColor)
            if actual.isOverBudget {
                Text("Over by \(AmountFormat.string(-actual.remaining, code: code))")
                    .scaledFont(.caption).foregroundStyle(.red)
            } else {
                Text("\(AmountFormat.string(actual.remaining, code: code)) remaining")
                    .scaledFont(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Edits the budgeted monthly amount for each expense account.
struct EditBudgetSheet: View {
    @Bindable var model: AppModel
    let budget: Budget
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appFontScale) private var appFontScale
    private var amountWidth: CGFloat { 100 * appFontScale }

    @State private var amounts: [GncGUID: String] = [:]
    @State private var rollovers: [GncGUID: Bool] = [:]
    /// nil edits the flat amount (every period); an index edits that period.
    @State private var selectedPeriod: Int?

    private var incomeAccounts: [AccountNode] {
        model.postableAccounts.filter { $0.typeName == "Income" }
    }
    private var expenseAccounts: [AccountNode] {
        model.postableAccounts.filter { $0.typeName == "Expense" }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Period", selection: $selectedPeriod) {
                        Text("Every period").tag(Int?.none)
                        ForEach(0..<budget.numPeriods, id: \.self) { p in
                            Text("Period \(p + 1)").tag(Int?.some(p))
                        }
                    }
                    .onChange(of: selectedPeriod) { _, _ in loadAmounts() }
                }
                if !incomeAccounts.isEmpty {
                    Section("Income") {
                        ForEach(incomeAccounts) { node in
                            HStack {
                                Text(node.name)
                                Spacer()
                                TextField("0", text: binding(for: node.id))
                                    .multilineTextAlignment(.trailing).frame(width: amountWidth)
                            }
                        }
                    }
                }
                Section("Expenses") {
                    if expenseAccounts.isEmpty {
                        Text("No expense accounts yet.").foregroundStyle(.secondary)
                    }
                    ForEach(expenseAccounts) { node in
                        HStack {
                            Text(node.name)
                            Spacer()
                            Toggle("Rollover", isOn: rolloverBinding(for: node.id))
                                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                            TextField("0", text: binding(for: node.id))
                                .multilineTextAlignment(.trailing).frame(width: amountWidth)
                        }
                    }
                }
            }
            .navigationTitle("Edit Budget")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .onAppear(perform: loadAmounts)
        }
    }

    private func loadAmounts() {
        amounts = [:]
        for node in incomeAccounts + expenseAccounts {
            let line = budget.lines.first { $0.accountGUID == node.id }
            if let period = selectedPeriod {
                // Only show a value where this period has an explicit override.
                if let amount = line?.periodAmounts[period] {
                    amounts[node.id] = NSDecimalNumber(decimal: amount).stringValue
                }
            } else if let amount = line?.amount {
                amounts[node.id] = NSDecimalNumber(decimal: amount).stringValue
            }
            rollovers[node.id] = line?.rollover ?? false
        }
    }

    private func binding(for id: GncGUID) -> Binding<String> {
        Binding(get: { amounts[id] ?? "" }, set: { amounts[id] = $0 })
    }
    private func rolloverBinding(for id: GncGUID) -> Binding<Bool> {
        Binding(get: { rollovers[id] ?? false }, set: { rollovers[id] = $0 })
    }

    private func save() {
        var updated = budget
        if let period = selectedPeriod {
            // Edit only this period's overrides, preserving flat amounts and
            // every other period.
            for (id, text) in amounts where Decimal(string: text) != nil {
                updated.setAmount(Decimal(string: text)!, for: id, period: period)
            }
        } else {
            // Flat amounts (every period), keeping any per-period overrides.
            var byID = Dictionary(budget.lines.map { ($0.accountGUID, $0) },
                                  uniquingKeysWith: { a, _ in a })
            var lines: [BudgetLine] = []
            for (id, text) in amounts {
                guard let amount = Decimal(string: text), amount != 0 else { continue }
                var line = byID[id] ?? BudgetLine(accountGUID: id, amount: 0)
                line.amount = amount
                line.rollover = rollovers[id] ?? false
                lines.append(line)
                byID[id] = nil
            }
            updated.lines = lines
        }
        model.updateBudget(updated)
        dismiss()
    }
}
