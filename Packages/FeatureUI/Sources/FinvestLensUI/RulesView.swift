//
//  RulesView.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import FinvestLensEngine
import FinvestLensRules

/// Lists and manages the document's categorisation rules (`FR-RULE-01`).
struct RulesView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingAdd = false

    private var rules: [Rule] { model.ruleGroups.flatMap(\.rules) }

    var body: some View {
        NavigationStack {
            Group {
                if rules.isEmpty {
                    ContentUnavailableView("No rules", systemImage: "wand.and.stars",
                                           description: Text("Rules auto-categorise transactions when you import."))
                } else {
                    List {
                        ForEach(rules) { rule in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.name).fontWeight(.medium)
                                Text(summary(rule)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets { model.deleteRule(rules[index].id) }
                        }
                    }
                }
            }
            .navigationTitle("Rules")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem {
                    Button("Add Rule", systemImage: "plus") { showingAdd = true }
                }
            }
            .sheet(isPresented: $showingAdd) { AddRuleSheet(model: model) }
        }
        .frame(minWidth: 480, minHeight: 400)
    }

    private func summary(_ rule: Rule) -> String {
        let conditions = rule.triggers
            .map { "\($0.field.rawValue) \($0.op.rawValue) “\($0.value)”" }
            .joined(separator: rule.matchAll ? " and " : " or ")
        let action = rule.actions.compactMap { action -> String? in
            if case .setAccount(let id) = action {
                return "→ \(accountName(id))"
            }
            return nil
        }.joined(separator: ", ")
        return "If \(conditions) \(action)"
    }

    private func accountName(_ id: GncGUID) -> String {
        model.postableAccounts.first { $0.id == id }?.name ?? "?"
    }
}

/// Adds a single-condition categorisation rule.
struct AddRuleSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var field: RuleField = .description
    @State private var op: RuleOperator = .contains
    @State private var value = ""
    @State private var accountID: GncGUID?

    var body: some View {
        NavigationStack {
            Form {
                Section("When") {
                    Picker("Field", selection: $field) {
                        ForEach(RuleField.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    Picker("Condition", selection: $op) {
                        ForEach(RuleOperator.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    TextField("Value", text: $value)
                }
                Section("Then set account") {
                    Picker("Account", selection: $accountID) {
                        Text("—").tag(GncGUID?.none)
                        ForEach(model.postableAccounts) { Text($0.fullName).tag(GncGUID?.some($0.id)) }
                    }
                }
                Section("Name") {
                    TextField("Optional name", text: $name)
                }
            }
            .navigationTitle("New Rule")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(value.isEmpty || accountID == nil)
                }
            }
        }
    }

    private func add() {
        guard let accountID else { return }
        let ruleName = name.isEmpty ? "\(field.rawValue) \(op.rawValue) “\(value)”" : name
        model.addRule(Rule(
            name: ruleName,
            triggers: [RuleTrigger(field: field, op: op, value: value)],
            actions: [.setAccount(accountID)]
        ))
        dismiss()
    }
}
