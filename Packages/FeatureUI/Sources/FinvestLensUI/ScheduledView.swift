//
//  ScheduledView.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import FinvestLensEngine

/// Lists scheduled transactions, shows what's due, and posts due instances
/// (`FR-SCH-01/03`).
struct ScheduledView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingAdd = false

    private var scheduled: [ScheduledTransaction] { model.scheduledTransactions }
    private var due: [ScheduledTransactionService.PendingInstance] { model.pendingScheduled() }

    var body: some View {
        NavigationStack {
            List {
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
                            _ = model.postDueScheduled()
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
                                    Text("paused").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Text(recurrenceSummary(sx.recurrence))
                                .font(.caption).foregroundStyle(.secondary)
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
        }
        .frame(minWidth: 500, minHeight: 420)
    }

    private func recurrenceSummary(_ recurrence: Recurrence) -> String {
        let unit: String
        switch recurrence.period {
        case .daily: unit = "day"
        case .weekly: unit = "week"
        case .monthly: unit = "month"
        case .yearly: unit = "year"
        }
        let every = recurrence.interval == 1 ? "Every \(unit)" : "Every \(recurrence.interval) \(unit)s"
        return "\(every), from \(recurrence.startDate.formatted(.dateTime.year().month().day()))"
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
                    TextField("Amount", text: $amountText)
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
                        ForEach(RecurrencePeriod.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    Stepper("Every \(interval)", value: $interval, in: 1...52)
                    DatePicker("Starting", selection: $startDate, displayedComponents: .date)
                }
            }
            .navigationTitle("New Scheduled Transaction")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(!isValid)
                }
            }
        }
    }

    private var isValid: Bool {
        guard let fromID, let toID, fromID != toID else { return false }
        guard let amount = Decimal(string: amountText), amount != 0 else { return false }
        return !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func add() {
        guard let fromID, let toID, let amount = Decimal(string: amountText) else { return }
        let sx = ScheduledTransaction(
            name: name,
            currency: model.reportCurrency,
            description: name,
            recurrence: Recurrence(period: period, interval: interval, startDate: startDate),
            splits: [
                ScheduledSplit(accountGUID: toID, value: amount),
                ScheduledSplit(accountGUID: fromID, value: -amount),
            ]
        )
        model.addScheduledTransaction(sx)
        dismiss()
    }
}
