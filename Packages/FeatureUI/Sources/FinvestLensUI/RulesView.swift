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
///
/// Grouped, because the model is: rules live in ordered, switchable groups, and
/// this view used to flatten them away with `flatMap(\.rules)` — a book could
/// carry groups but nobody could make one, see one, or turn one off.
struct RulesView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing: RuleEditorTarget?
    @State private var showingApply = false
    @State private var renamingGroup: UUID?
    @State private var groupName = ""

    private var isEmpty: Bool { model.ruleGroups.allSatisfy(\.rules.isEmpty) }

    var body: some View {
        NavigationStack {
            Group {
                if model.ruleGroups.isEmpty {
                    ContentUnavailableView("No rules", systemImage: "wand.and.stars",
                                           description: Text("Rules auto-categorise transactions when you import."))
                } else {
                    list
                }
            }
            .navigationTitle("Rules")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem {
                    Button("Apply to History", systemImage: "clock.arrow.circlepath") {
                        showingApply = true
                    }
                    .disabled(isEmpty)
                }
                ToolbarItem {
                    Menu {
                        Button("Add Rule…") { editing = .new(groupID: model.ruleGroups.first?.id) }
                        Button("Add Group") { model.addRuleGroup(named: "New Group") }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $editing) { target in
                RuleEditorSheet(model: model, target: target)
            }
            .sheet(isPresented: $showingApply) { ApplyRulesSheet(model: model) }
            .alert("Rename Group", isPresented: Binding(
                get: { renamingGroup != nil },
                set: { if !$0 { renamingGroup = nil } })) {
                TextField("Name", text: $groupName)
                Button("Cancel", role: .cancel) { renamingGroup = nil }
                Button("Rename") {
                    if let id = renamingGroup { model.renameRuleGroup(id, to: groupName) }
                    renamingGroup = nil
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    private var list: some View {
        List {
            ForEach(model.ruleGroups) { group in
                Section {
                    ForEach(group.rules) { rule in
                        row(rule, in: group)
                    }
                    .onDelete { offsets in
                        for index in offsets { model.deleteRule(group.rules[index].id) }
                    }
                    // Rules are evaluated in order and `stopProcessing` cuts the
                    // rest off, so this is a setting, not decoration.
                    .onMove { model.moveRules(inGroup: group.id, from: $0, to: $1) }
                    if group.rules.isEmpty {
                        Text("No rules in this group.")
                            .scaledFont(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    HStack {
                        Toggle(isOn: Binding(
                            get: { group.isActive },
                            set: { model.setRuleGroupActive(group.id, $0) })) {
                            Text(group.name)
                        }
                        .checkboxToggleStyle()
                        Spacer()
                        Menu {
                            Button("Add Rule…") { editing = .new(groupID: group.id) }
                            Button("Rename…") {
                                groupName = group.name
                                renamingGroup = group.id
                            }
                            Button("Delete Group", role: .destructive) {
                                model.deleteRuleGroup(group.id)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
            }
            .onMove { model.moveRuleGroups(from: $0, to: $1) }
        }
    }

    private func row(_ rule: Rule, in group: RuleGroup) -> some View {
        HStack {
            Toggle(isOn: Binding(
                get: { rule.isActive },
                set: { model.setRuleActive(rule.id, $0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.name).fontWeight(.medium)
                    Text(Self.summary(rule, accountName: accountName, goalName: goalName))
                        .scaledFont(.caption).foregroundStyle(.secondary)
                }
            }
            .checkboxToggleStyle()
            Spacer()
        }
        // A group that is off means none of its rules run, whatever their own
        // switches say — show that rather than let a ticked rule inside an
        // unticked group look live.
        .opacity(group.isActive && rule.isActive ? 1 : 0.5)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { editing = .existing(rule) }
        .contextMenu {
            Button("Edit…") { editing = .existing(rule) }
            Button("Delete", role: .destructive) { model.deleteRule(rule.id) }
        }
    }

    /// The rule in words. Every part the engine honours has to show up here, or
    /// the list would say two different rules are the same one.
    static func summary(_ rule: Rule, accountName: (GncGUID) -> String,
                        goalName: (GncGUID) -> String = { _ in "goal" }) -> String {
        let conditions = rule.triggers
            .map { "\($0.field.rawValue) \($0.op.rawValue) “\($0.value)”" }
            .joined(separator: rule.matchAll ? " and " : " or ")
        let actions = rule.actions.map { action -> String in
            switch action {
            case .setAccount(let id): "→ \(accountName(id))"
            case .setNotes(let notes): "notes “\(notes)”"
            case .setTags(let tags): "tag \(tags.joined(separator: ", "))"
            case .setDescription(let text): "rename “\(text)”"
            case .allocateToGoal(let id): "→ goal “\(goalName(id))”"
            }
        }.joined(separator: ", ")
        let tail = rule.stopProcessing ? ", then stop" : ""
        return "If \(conditions) \(actions)\(tail)"
    }

    private func accountName(_ id: GncGUID) -> String {
        model.postableAccounts.first { $0.id == id }?.name ?? "?"
    }

    private func goalName(_ id: GncGUID) -> String {
        model.savingsGoals.first { $0.id == id }?.name ?? "?"
    }
}

/// What the rule editor is opened on: a new rule in a group, or an existing one.
enum RuleEditorTarget: Identifiable {
    case new(groupID: UUID?)
    case existing(Rule)

    var id: String {
        switch self {
        case .new(let groupID): "new-\(groupID?.uuidString ?? "first")"
        case .existing(let rule): "edit-\(rule.id.uuidString)"
        }
    }
}

/// Previews and applies the document's rules to existing transactions
/// (`FR-RULE-02`).
struct ApplyRulesSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var proposals: [RuleApplication] = []
    @State private var applied = false

    var body: some View {
        NavigationStack {
            Group {
                if applied {
                    ContentUnavailableView("Done", systemImage: "checkmark.circle",
                                           description: Text("Applied \(proposals.count) change\(proposals.count == 1 ? "" : "s")."))
                } else if proposals.isEmpty {
                    ContentUnavailableView("Nothing to change", systemImage: "clock.arrow.circlepath",
                                           description: Text("No historical transactions match your rules, or they’re already categorised."))
                } else {
                    List(proposals) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.description).fontWeight(.medium)
                            if let proposed = item.proposedCategory {
                                Text("\(item.currentCategory ?? "—") → \(proposed)")
                                    .scaledFont(.caption).foregroundStyle(.secondary)
                            }
                            if let notes = item.proposedNotes {
                                Text("Notes: \(notes)").scaledFont(.caption2).foregroundStyle(.secondary)
                            }
                            if let goal = item.proposedGoalName {
                                Text("Allocate \(AmountFormat.string(item.allocateAmount, code: model.reportCurrency.mnemonic)) → goal “\(goal)”")
                                    .scaledFont(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Apply Rules")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(applied ? "Close" : "Cancel") { dismiss() }
                }
                if !applied && !proposals.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Apply \(proposals.count)") {
                            model.applyHistoricalRules(proposals)
                            applied = true
                        }
                    }
                }
            }
            .onAppear { proposals = model.previewHistoricalRules() }
        }
        .frame(minWidth: 460, minHeight: 360)
    }
}

/// Creates or edits a rule, offering everything the engine honours.
///
/// It used to hard-code one trigger and `setAccount`, so multi-trigger AND/OR
/// rules rendered ("and"/"or" in the summary) but could not be made, and
/// `setNotes` — engine-supported, applied by Apply to History, previewed in its
/// sheet — had no way to be created at all.
struct RuleEditorSheet: View {
    @Bindable var model: AppModel
    var target: RuleEditorTarget
    @Environment(\.dismiss) private var dismiss

    @State private var loaded = false
    @State private var name = ""
    @State private var triggers: [RuleTrigger] = [RuleTrigger(field: .description,
                                                              op: .contains, value: "")]
    @State private var matchAll = true
    @State private var accountID: GncGUID?
    @State private var setsNotes = false
    @State private var notes = ""
    @State private var setsTags = false
    @State private var tagsText = ""
    @State private var setsDescription = false
    @State private var descriptionText = ""
    @State private var goalID: GncGUID?
    @State private var stopProcessing = false

    private var isEditing: Bool { if case .existing = target { true } else { false } }
    private var validTriggers: [RuleTrigger] { triggers.filter { !$0.value.isEmpty } }
    private var isValid: Bool {
        !validTriggers.isEmpty && (accountID != nil
            || (setsNotes && !notes.isEmpty)
            || (setsTags && !tagsText.trimmingCharacters(in: .whitespaces).isEmpty)
            || (setsDescription && !descriptionText.isEmpty)
            || goalID != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach($triggers) { $trigger in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Picker("Field", selection: $trigger.field) {
                                    ForEach(RuleField.allCases, id: \.self) {
                                        Text($0.rawValue.capitalized).tag($0)
                                    }
                                }
                                .labelsHidden()
                                Picker("Condition", selection: $trigger.op) {
                                    ForEach(RuleOperator.allCases, id: \.self) {
                                        Text($0.rawValue).tag($0)
                                    }
                                }
                                .labelsHidden()
                            }
                            TextField("Value", text: $trigger.value, prompt: Text("Value"))
                                .labelsHidden()
                        }
                    }
                    .onDelete { offsets in
                        triggers.remove(atOffsets: offsets)
                        if triggers.isEmpty {
                            triggers = [RuleTrigger(field: .description, op: .contains, value: "")]
                        }
                    }
                    Button("Add Condition", systemImage: "plus") {
                        triggers.append(RuleTrigger(field: .description, op: .contains, value: ""))
                    }
                } header: {
                    HStack {
                        Text("When")
                        Spacer()
                        if triggers.count > 1 {
                            Picker("Match", selection: $matchAll) {
                                Text("all conditions").tag(true)
                                Text("any condition").tag(false)
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                }

                Section("Then") {
                    Picker("Set account", selection: $accountID) {
                        Text("Leave account alone").tag(GncGUID?.none)
                        ForEach(model.postableAccounts) { Text($0.fullName).tag(GncGUID?.some($0.id)) }
                    }
                    Toggle("Set notes", isOn: $setsNotes)
                    if setsNotes {
                        TextField("Notes", text: $notes, prompt: Text("Notes"))
                            .labelsHidden()
                    }
                    Toggle("Add tags", isOn: $setsTags)
                    if setsTags {
                        TextField("Tags", text: $tagsText, prompt: Text("comma-separated"))
                            .labelsHidden()
                    }
                    Toggle("Rename description", isOn: $setsDescription)
                    if setsDescription {
                        TextField("Description", text: $descriptionText, prompt: Text("New description"))
                            .labelsHidden()
                    }
                    if !model.savingsGoals.isEmpty {
                        Picker("Allocate to goal", selection: $goalID) {
                            Text("Don’t allocate").tag(GncGUID?.none)
                            ForEach(model.savingsGoals) { Text($0.name).tag(GncGUID?.some($0.id)) }
                        }
                    }
                    Toggle("Stop processing further rules", isOn: $stopProcessing)
                }

                Section("Name") {
                    TextField("Optional name", text: $name)
                }
            }
            .navigationTitle(isEditing ? "Edit Rule" : "New Rule")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Add") { commit() }
                        .disabled(!isValid)
                }
            }
            .onAppear(perform: loadIfNeeded)
        }
        .frame(minWidth: 520, minHeight: 460)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard case .existing(let rule) = target else { return }
        name = rule.name
        triggers = rule.triggers.isEmpty
            ? [RuleTrigger(field: .description, op: .contains, value: "")]
            : rule.triggers
        matchAll = rule.matchAll
        stopProcessing = rule.stopProcessing
        for action in rule.actions {
            switch action {
            case .setAccount(let id): accountID = id
            case .setNotes(let text): setsNotes = true; notes = text
            case .setTags(let tags): setsTags = true; tagsText = tags.joined(separator: ", ")
            case .setDescription(let text): setsDescription = true; descriptionText = text
            case .allocateToGoal(let id): goalID = id
            }
        }
    }

    private func commit() {
        var actions: [RuleAction] = []
        if let accountID { actions.append(.setAccount(accountID)) }
        if setsNotes, !notes.isEmpty { actions.append(.setNotes(notes)) }
        if setsTags {
            let tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !tags.isEmpty { actions.append(.setTags(tags)) }
        }
        if setsDescription, !descriptionText.isEmpty { actions.append(.setDescription(descriptionText)) }
        if let goalID { actions.append(.allocateToGoal(goalID)) }

        let fallback = validTriggers
            .map { "\($0.field.rawValue) \($0.op.rawValue) “\($0.value)”" }
            .joined(separator: matchAll ? " and " : " or ")
        let ruleName = name.isEmpty ? fallback : name

        switch target {
        case .new(let groupID):
            model.addRule(Rule(name: ruleName, triggers: validTriggers, matchAll: matchAll,
                               actions: actions, stopProcessing: stopProcessing),
                          toGroup: groupID)
        case .existing(let rule):
            var updated = rule
            updated.name = ruleName
            updated.triggers = validTriggers
            updated.matchAll = matchAll
            updated.actions = actions
            updated.stopProcessing = stopProcessing
            model.updateRule(updated)
        }
        dismiss()
    }
}
