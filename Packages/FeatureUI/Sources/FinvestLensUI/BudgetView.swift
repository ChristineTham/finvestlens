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
                        List(actuals) { actual in
                            BudgetRow(actual: actual, code: model.reportCurrency.mnemonic)
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
                Spacer()
                Text("\(AmountFormat.string(actual.actual, code: code)) of \(AmountFormat.string(actual.budgeted, code: code))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(1.0, max(0, actual.fractionUsed ?? 0)))
                .tint(actual.isOverBudget ? .red : .accentColor)
            if actual.isOverBudget {
                Text("Over by \(AmountFormat.string(-actual.remaining, code: code))")
                    .font(.caption).foregroundStyle(.red)
            } else {
                Text("\(AmountFormat.string(actual.remaining, code: code)) remaining")
                    .font(.caption).foregroundStyle(.secondary)
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

    @State private var amounts: [GncGUID: String] = [:]

    private var expenseAccounts: [AccountNode] {
        model.postableAccounts.filter { $0.typeName == "Expense" }
    }

    var body: some View {
        NavigationStack {
            Form {
                if expenseAccounts.isEmpty {
                    Text("No expense accounts yet.").foregroundStyle(.secondary)
                }
                ForEach(expenseAccounts) { node in
                    HStack {
                        Text(node.name)
                        Spacer()
                        TextField("0", text: binding(for: node.id))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
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
                for node in expenseAccounts {
                    if let amount = budget.amount(for: node.id) {
                        amounts[node.id] = NSDecimalNumber(decimal: amount).stringValue
                    }
                }
            }
        }
    }

    private func binding(for id: GncGUID) -> Binding<String> {
        Binding(get: { amounts[id] ?? "" }, set: { amounts[id] = $0 })
    }

    private func save() {
        var updated = budget
        updated.lines = []
        for (id, text) in amounts {
            if let amount = Decimal(string: text), amount != 0 {
                updated.setAmount(amount, for: id)
            }
        }
        model.updateBudget(updated)
        dismiss()
    }
}
