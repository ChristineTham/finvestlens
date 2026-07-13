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

    private var incomeAccounts: [AccountNode] {
        model.postableAccounts.filter { $0.typeName == "Income" }
    }
    private var expenseAccounts: [AccountNode] {
        model.postableAccounts.filter { $0.typeName == "Expense" }
    }

    var body: some View {
        NavigationStack {
            Form {
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .onAppear {
                for node in incomeAccounts + expenseAccounts {
                    if let amount = budget.amount(for: node.id) {
                        amounts[node.id] = NSDecimalNumber(decimal: amount).stringValue
                    }
                    rollovers[node.id] = budget.lines.first { $0.accountGUID == node.id }?.rollover ?? false
                }
            }
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
        updated.lines = []
        for (id, text) in amounts {
            if let amount = Decimal(string: text), amount != 0 {
                updated.setAmount(amount, for: id)
                updated.setRollover(rollovers[id] ?? false, for: id)
            }
        }
        model.updateBudget(updated)
        dismiss()
    }
}
