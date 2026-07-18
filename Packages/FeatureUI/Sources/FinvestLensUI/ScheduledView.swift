//
//  ScheduledView.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import FinvestLensEngine
import FinvestLensReports

/// Lists scheduled transactions, shows what's due, and posts due instances
/// (`FR-SCH-01/03`).
struct ScheduledView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingAdd = false
    @State private var promptingVariables = false
    @State private var variableInputs: [String: String] = [:]

    private var scheduled: [ScheduledTransaction] { model.scheduledTransactions }
    private var due: [ScheduledTransactionService.PendingInstance] { model.pendingScheduled() }
    private var bills: [BillReminder] { model.billReminders().filter { $0.status != .paid } }

    var body: some View {
        NavigationStack {
            List {
                if !bills.isEmpty {
                    Section("Bills & Calendar") {
                        ForEach(bills) { bill in
                            HStack {
                                billBadge(bill.status)
                                Text(bill.name)
                                Text(bill.dueDate, format: .dateTime.year().month().day())
                                    .scaledFont(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(AmountFormat.string(bill.amount, code: model.reportCurrency.mnemonic))
                                    .monospacedDigit()
                            }
                        }
                    }
                }

                if !due.isEmpty {
                    Section("Due now (\(due.count))") {
                        ForEach(due) { instance in
                            HStack {
                                Text(instance.name)
                                Spacer()
                                Text(instance.date, format: .dateTime.year().month().day())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button("Enter \(due.count) Due Transaction\(due.count == 1 ? "" : "s")") {
                            if model.dueVariableNames().isEmpty {
                                _ = model.postDueScheduled()
                            } else {
                                variableInputs = Dictionary(uniqueKeysWithValues:
                                    model.dueVariableNames().map { ($0, "") })
                                promptingVariables = true
                            }
                        }
                    }
                }

                Section("Scheduled") {
                    if scheduled.isEmpty {
                        Text("No scheduled transactions.").foregroundStyle(.secondary)
                    }
                    ForEach(scheduled) { sx in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(sx.name).fontWeight(.medium)
                                if !sx.isEnabled {
                                    Text("paused").scaledFont(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Text(recurrenceSummary(sx.recurrence))
                                .scaledFont(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { model.deleteScheduledTransaction(scheduled[index].id) }
                    }
                }
            }
            .navigationTitle("Scheduled")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem {
                    Button("Add", systemImage: "plus") { showingAdd = true }
                        .disabled(model.postableAccounts.count < 2)
                }
            }
            .sheet(isPresented: $showingAdd) { AddScheduledSheet(model: model) }
            .sheet(isPresented: $promptingVariables) {
                NavigationStack {
                    Form {
                        Section("Values for this run") {
                            ForEach(variableInputs.keys.sorted(), id: \.self) { name in
                                LabeledContent(name) {
                                    TextField(name, text: Binding(
                                        get: { variableInputs[name] ?? "" },
                                        set: { variableInputs[name] = $0 }))
                                        .multilineTextAlignment(.trailing)
                                        .frame(maxWidth: 160)
                                }
                            }
                        }
                        Text("These scheduled transactions use formulas (FR-SCH-02). Enter the amounts for each variable; they apply to every instance posted now.")
                            .scaledFont(.caption).foregroundStyle(.secondary)
                    }
                    .navigationTitle("Formula Values")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { promptingVariables = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Post") {
                                var vars: [String: Decimal] = [:]
                                for (name, text) in variableInputs {
                                    vars[name] = AmountExpression.evaluate(text) ?? 0
                                }
                                _ = model.postDueScheduled(variables: vars)
                                promptingVariables = false
                            }
                            .disabled(variableInputs.values.contains { AmountExpression.evaluate($0) == nil })
                        }
                    }
                }
                .frame(minWidth: 360, minHeight: 240)
            }
        }
        .frame(minWidth: 500, minHeight: 420)
    }

    private func recurrenceSummary(_ recurrence: Recurrence) -> String {
        let from = recurrence.startDate.formatted(.dateTime.year().month().day())
        if recurrence.period == .once { return "Once, on \(from)" }
        let unit = recurrence.period.unitNoun
        let every = recurrence.interval == 1 ? "Every \(unit)" : "Every \(recurrence.interval) \(unit)s"
        let qualifier: String
        switch recurrence.period {
        case .endOfMonth: qualifier = " (last day)"
        case .nthWeekday: qualifier = " (same weekday)"
        case .lastWeekday: qualifier = " (last weekday)"
        default: qualifier = ""
        }
        return "\(every)\(qualifier), from \(from)"
    }

    @ViewBuilder
    private func billBadge(_ status: BillStatus) -> some View {
        let (label, color): (String, Color) = switch status {
        case .overdue: ("Overdue", .red)
        case .dueSoon: ("Due soon", .orange)
        case .upcoming: ("Upcoming", .secondary)
        case .paid: ("Paid", .green)
        }
        Text(label).scaledFont(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.2)).foregroundStyle(color).clipShape(Capsule())
    }
}

/// Adds a simple two-account scheduled transfer template.
struct AddScheduledSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var amountText = ""
    @State private var fromID: GncGUID?
    @State private var toID: GncGUID?
    @State private var period: RecurrencePeriod = .monthly
    @State private var interval = 1
    @State private var startDate = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Name", text: $name)
                    TextField("Amount or formula", text: $amountText)
                    if !formulaVariables.isEmpty {
                        Text("Formula — you'll be asked for \(formulaVariables.joined(separator: ", ")) each time it's due.")
                            .scaledFont(.caption).foregroundStyle(.secondary)
                    } else if let value = evaluatedAmount, value != Decimal(string: amountText) {
                        Text("= \(AmountFormat.string(value, code: model.reportCurrency.mnemonic))")
                            .scaledFont(.caption).foregroundStyle(.secondary)
                    }
                    Picker("From", selection: $fromID) {
                        Text("—").tag(GncGUID?.none)
                        ForEach(model.postableAccounts) { Text($0.fullName).tag(GncGUID?.some($0.id)) }
                    }
                    Picker("To", selection: $toID) {
                        Text("—").tag(GncGUID?.none)
                        ForEach(model.postableAccounts) { Text($0.fullName).tag(GncGUID?.some($0.id)) }
                    }
                }
                Section("Schedule") {
                    Picker("Repeats", selection: $period) {
                        ForEach(RecurrencePeriod.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Stepper("Every \(interval)", value: $interval, in: 1...52)
                    DatePicker("Starting", selection: $startDate, displayedComponents: .date)
                }
            }
            .navigationTitle("New Scheduled Transaction")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(!isValid)
                }
            }
        }
    }

    /// The amount field evaluated as an arithmetic expression (`FR-SCH-02`);
    /// `nil` when it isn't a valid expression or references variables.
    private var evaluatedAmount: Decimal? { AmountExpression.evaluate(amountText) }
    /// Variable names in the amount field (non-empty makes it a formula).
    private var formulaVariables: [String] { AmountExpression.variables(in: amountText).sorted() }

    private var isValid: Bool {
        guard let fromID, let toID, fromID != toID else { return false }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if !formulaVariables.isEmpty { return true }                 // a variable formula
        return evaluatedAmount != nil && evaluatedAmount != 0        // a number or arithmetic
    }

    private func add() {
        guard let fromID, let toID else { return }
        let toSplit: ScheduledSplit
        let fromSplit: ScheduledSplit
        if formulaVariables.isEmpty {
            guard let amount = evaluatedAmount else { return }
            toSplit = ScheduledSplit(accountGUID: toID, value: amount)
            fromSplit = ScheduledSplit(accountGUID: fromID, value: -amount)
        } else {
            let f = amountText.trimmingCharacters(in: .whitespaces)
            toSplit = ScheduledSplit(accountGUID: toID, value: 0, formula: f)
            fromSplit = ScheduledSplit(accountGUID: fromID, value: 0, formula: "-(\(f))")
        }
        let sx = ScheduledTransaction(
            name: name,
            currency: model.reportCurrency,
            description: name,
            recurrence: Recurrence(period: period, interval: interval, startDate: startDate),
            splits: [toSplit, fromSplit]
        )
        model.addScheduledTransaction(sx)
        dismiss()
    }
}
