//
//  GoalsView.swift
//  FinvestLens — FeatureUI
//
//  Savings goals / piggy banks (`FR-GOAL-01`). Each goal earmarks part of an
//  asset account toward a named target; money is set aside or released without
//  moving it between accounts. Goals are grouped by their optional group name.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import FinvestLensEngine

struct GoalsView: View {
    @Environment(\.appDateFormat) private var dateFormat
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isEmbeddedDestination) private var embedded

    @State private var editing: SavingsGoal?
    @State private var creating = false
    @State private var adjusting: SavingsGoal?

    private var code: String { model.reportCurrency.mnemonic }

    /// Goals by group, ungrouped first, each group's goals in saved order.
    private var groups: [(name: String, goals: [SavingsGoal])] {
        let byGroup = Dictionary(grouping: model.savingsGoals) { $0.group }
        return byGroup.keys.sorted { ($0.isEmpty ? "" : $0) < ($1.isEmpty ? "" : $1) }
            .map { (name: $0, goals: byGroup[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.savingsGoals.isEmpty {
                    ContentUnavailableView {
                        Label("No savings goals", systemImage: "banknote")
                    } description: {
                        Text("Set aside part of an account toward a target — a holiday, an emergency fund, a deposit.")
                    } actions: {
                        Button("New Goal") { creating = true }.buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(groups, id: \.name) { group in
                            Section(group.name.isEmpty ? "Goals" : group.name) {
                                ForEach(group.goals) { goal in
                                    GoalRow(goal: goal, code: code,
                                            accountName: goal.accountGUID.flatMap { model.accountName($0) })
                                        .contentShape(Rectangle())
                                        .onTapGesture { editing = goal }
                                        .contextMenu {
                                            Button("Add / Withdraw Money…") { adjusting = goal }
                                            Button("Edit…") { editing = goal }
                                            Button("Delete", role: .destructive) {
                                                model.deleteSavingsGoal(goal.id)
                                            }
                                        }
                                        .swipeActions {
                                            Button("Delete", role: .destructive) {
                                                model.deleteSavingsGoal(goal.id)
                                            }
                                            Button("Money") { adjusting = goal }.tint(.blue)
                                        }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Savings Goals")
            .onEscapeCommand { dismiss() }
            .toolbar {
                if !embedded {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                    }
                }
                ToolbarItem {
                    Button("New Goal", systemImage: "plus") { creating = true }
                        .disabled(model.goalEligibleAccounts.isEmpty)
                }
            }
            .sheet(isPresented: $creating) { GoalEditorSheet(model: model, goal: nil) }
            .sheet(item: $editing) { goal in GoalEditorSheet(model: model, goal: goal) }
            .sheet(item: $adjusting) { goal in GoalAdjustSheet(model: model, goal: goal) }
        }
        .frame(minWidth: embedded ? nil : 460, minHeight: embedded ? nil : 420)
    }
}

/// One goal: name, linked account, a progress bar, and the figures.
private struct GoalRow: View {
    @Environment(\.appDateFormat) private var dateFormat
    let goal: SavingsGoal
    let code: String
    let accountName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(goal.name).fontWeight(.medium)
                if goal.isComplete {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                }
                Spacer()
                Text(AmountFormat.string(goal.savedAmount, code: code)
                     + " / " + AmountFormat.string(goal.targetAmount, code: code))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            ProgressView(value: goal.fractionComplete)
                .tint(goal.isComplete ? .green : .accentColor)
            HStack {
                if let accountName { Text(accountName).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if goal.remaining > 0 {
                    Text("\(AmountFormat.string(goal.remaining, code: code)) to go")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let date = goal.targetDate {
                    Text("by \(dateFormat.long(date))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Creates or edits a goal.
private struct GoalEditorSheet: View {
    @Bindable var model: AppModel
    let goal: SavingsGoal?
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var accountID: GncGUID?
    @State private var target = ""
    @State private var hasDate = false
    @State private var date = Date()
    @State private var group = ""

    private func dec(_ s: String) -> Decimal { Decimal(string: s.trimmingCharacters(in: .whitespaces)) ?? 0 }
    private var isValid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && accountID != nil }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                LabeledContent("Account") {
                    AccountField(nodes: model.goalEligibleAccounts, selection: $accountID)
                }
                TextField("Target amount", text: $target)
                Toggle("Target date", isOn: $hasDate)
                if hasDate {
                    DatePicker("By", selection: $date, displayedComponents: .date)
                }
                TextField("Group (optional)", text: $group)
            }
            .formStyle(.grouped)
            .navigationTitle(goal == nil ? "New Goal" : "Edit Goal")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!isValid)
                }
            }
            .onAppear(perform: load)
        }
        .frame(minWidth: 380, minHeight: 300)
    }

    private func load() {
        guard let goal else { return }
        name = goal.name; accountID = goal.accountGUID
        target = goal.targetAmount == 0 ? "" : "\(goal.targetAmount)"
        hasDate = goal.targetDate != nil
        date = goal.targetDate ?? Date()
        group = goal.group
    }

    private func save() {
        var edited = goal ?? SavingsGoal(name: name)
        edited.name = name.trimmingCharacters(in: .whitespaces)
        edited.accountGUID = accountID
        edited.targetAmount = dec(target)
        edited.targetDate = hasDate ? date : nil
        edited.group = group.trimmingCharacters(in: .whitespaces)
        if goal == nil { model.addSavingsGoal(edited) } else { model.updateSavingsGoal(edited) }
        dismiss()
    }
}

/// Adds money to or withdraws money from a goal's set-aside total.
private struct GoalAdjustSheet: View {
    @Bindable var model: AppModel
    let goal: SavingsGoal
    @Environment(\.dismiss) private var dismiss

    @State private var amount = ""
    @State private var adding = true

    private var code: String { model.reportCurrency.mnemonic }
    private func dec(_ s: String) -> Decimal { Decimal(string: s.trimmingCharacters(in: .whitespaces)) ?? 0 }

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("Goal", value: goal.name)
                LabeledContent("Set aside now",
                               value: AmountFormat.string(goal.savedAmount, code: code))
                Picker("Direction", selection: $adding) {
                    Text("Add money").tag(true)
                    Text("Withdraw").tag(false)
                }
                .pickerStyle(.segmented)
                TextField("Amount", text: $amount)
            }
            .formStyle(.grouped)
            .navigationTitle("Add / Withdraw")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        model.adjustSavingsGoal(goal.id, by: adding ? dec(amount) : -dec(amount))
                        dismiss()
                    }
                    .disabled(dec(amount) <= 0)
                }
            }
        }
        .frame(minWidth: 340, minHeight: 240)
    }
}
