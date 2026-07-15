//
//  FindSheet.swift
//  FinvestLens — FeatureUI
//
//  GnuCash's Edit ▸ Find… (⌘F), which it heads "Split Search".
//
//  A criterion is a field, a comparator and a value, and the three move
//  together: picking a different field replaces the whole criterion with a
//  fresh one, because a date has no use for "contains". That is why the editor
//  holds ``FindTest`` values rather than three loose pickers — the illegal
//  combinations cannot be built, so they cannot be rendered.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import FinvestLensEngine

/// The field selector — one flat list, as GnuCash shows it, spanning the
/// separate typed cases underneath.
enum FindFieldChoice: String, CaseIterable, Identifiable, Hashable {
    case description, notes, memo, descriptionNotesOrMemo, number, action
    case datePosted, reconciledDate
    case value, shares, sharePrice
    case reconcile, account, balanced

    var id: String { rawValue }

    var label: String {
        switch self {
        case .description: FindTextField.description.label
        case .notes: FindTextField.notes.label
        case .memo: FindTextField.memo.label
        case .descriptionNotesOrMemo: FindTextField.descriptionNotesOrMemo.label
        case .number: FindTextField.number.label
        case .action: FindTextField.action.label
        case .datePosted: FindDateField.posted.label
        case .reconciledDate: FindDateField.reconciled.label
        case .value: FindNumberField.value.label
        case .shares: FindNumberField.shares.label
        case .sharePrice: FindNumberField.sharePrice.label
        case .reconcile: "Reconcile"
        case .account: "Account"
        case .balanced: "Balanced"
        }
    }

    /// The choice a test represents, for showing an existing criterion.
    init(_ test: FindTest) {
        switch test {
        case .text(let f, _, _, _):
            switch f {
            case .description: self = .description
            case .notes: self = .notes
            case .memo: self = .memo
            case .descriptionNotesOrMemo: self = .descriptionNotesOrMemo
            case .number: self = .number
            case .action: self = .action
            }
        case .date(let f, _, _):
            self = f == .posted ? .datePosted : .reconciledDate
        case .number(let f, _, _):
            switch f {
            case .value: self = .value
            case .shares: self = .shares
            case .sharePrice: self = .sharePrice
            }
        case .reconcile: self = .reconcile
        case .account: self = .account
        case .balanced: self = .balanced
        }
    }

    /// A fresh test for this field, used when the field picker changes. The old
    /// comparator and value are dropped rather than coerced: "contains 500"
    /// becoming "value contains 500" would be a guess at what the user meant.
    func defaultTest(today: Date = Date()) -> FindTest {
        switch self {
        case .description: .text(.description, .contains, "", matchCase: false)
        case .notes: .text(.notes, .contains, "", matchCase: false)
        case .memo: .text(.memo, .contains, "", matchCase: false)
        case .descriptionNotesOrMemo: .text(.descriptionNotesOrMemo, .contains, "", matchCase: false)
        case .number: .text(.number, .contains, "", matchCase: false)
        case .action: .text(.action, .contains, "", matchCase: false)
        case .datePosted: .date(.posted, .isOnOrAfter, today)
        case .reconciledDate: .date(.reconciled, .isOnOrAfter, today)
        case .value: .number(.value, .greaterThanOrEqual, 0)
        case .shares: .number(.shares, .greaterThanOrEqual, 0)
        case .sharePrice: .number(.sharePrice, .greaterThanOrEqual, 0)
        case .reconcile: .reconcile(.isOneOf, [.notReconciled])
        case .account: .account(.isOneOf, [])
        case .balanced: .balanced(false)
        }
    }
}

struct FindSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var criteria: [FindCriterion] = []
    @State private var matchAll = true
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Search for splits where", selection: $matchAll) {
                        Text("all criteria are met").tag(true)
                        Text("any criterion is met").tag(false)
                    }
                    .pickerStyle(.menu)
                }
                Section("Criteria") {
                    ForEach($criteria) { $criterion in
                        FindCriterionRow(
                            criterion: $criterion,
                            accounts: model.postableAccounts,
                            accountTree: model.accountTree,
                            onRemove: { criteria.removeAll { $0.id == criterion.id } },
                            canRemove: criteria.count > 1)
                    }
                    Button("Add Criterion", systemImage: "plus") {
                        criteria.append(FindCriterion(
                            test: FindFieldChoice.description.defaultTest()))
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Find Transaction")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Find") {
                        model.runFind(FindQuery(criteria: criteria, matchAll: matchAll))
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(criteria.isEmpty)
                }
            }
            .onAppear(perform: loadIfNeeded)
        }
        .frame(minWidth: 720, minHeight: 380)
    }

    /// Re-opening Find shows the query you ran, the way GnuCash keeps its
    /// criteria on screen — you almost always want to adjust it, not retype it.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let query = model.findQuery, !query.criteria.isEmpty {
            criteria = query.criteria
            matchAll = query.matchAll
        } else {
            criteria = [FindCriterion(
                test: FindFieldChoice.descriptionNotesOrMemo.defaultTest())]
        }
    }
}

/// One criterion: field, comparator, value, and Remove — GnuCash's row.
struct FindCriterionRow: View {
    @Binding var criterion: FindCriterion
    /// Flat, for naming a chosen account; `accountTree` is what the picker shows.
    let accounts: [AccountNode]
    let accountTree: [AccountNode]
    let onRemove: () -> Void
    let canRemove: Bool

    @State private var accountPickerShown = false

    private var choice: FindFieldChoice { FindFieldChoice(criterion.test) }

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { choice },
                set: { criterion.test = $0.defaultTest() })
            ) {
                ForEach(FindFieldChoice.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(width: 220)

            editor

            Spacer(minLength: 0)

            Button("Remove", systemImage: "minus.circle", action: onRemove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(!canRemove)
                .help("Remove this criterion")
        }
    }

    @ViewBuilder
    private var editor: some View {
        switch criterion.test {
        case .text(let field, let comparator, let needle, let matchCase):
            Picker("", selection: Binding(
                get: { comparator },
                set: { criterion.test = .text(field, $0, needle, matchCase: matchCase) })
            ) {
                ForEach(TextComparator.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(width: 170)

            TextField("", text: Binding(
                get: { needle },
                set: { criterion.test = .text(field, comparator, $0, matchCase: matchCase) }))
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 140)

            Toggle("Match case", isOn: Binding(
                get: { matchCase },
                set: { criterion.test = .text(field, comparator, needle, matchCase: $0) }))

        case .date(let field, let comparator, let value):
            Picker("", selection: Binding(
                get: { comparator },
                set: { criterion.test = .date(field, $0, value) })
            ) {
                ForEach(DateComparator.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(width: 170)

            DatePicker("", selection: Binding(
                get: { value },
                set: { criterion.test = .date(field, comparator, $0) }),
                displayedComponents: .date)
                .labelsHidden()

        case .number(let field, let comparator, let value):
            Picker("", selection: Binding(
                get: { comparator },
                set: { criterion.test = .number(field, $0, value) })
            ) {
                ForEach(NumberComparator.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(width: 210)

            TextField("", value: Binding(
                get: { value },
                set: { criterion.test = .number(field, comparator, $0) }),
                format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
                .monospacedDigit()

        case .reconcile(let comparator, let states):
            Picker("", selection: Binding(
                get: { comparator },
                set: { criterion.test = .reconcile($0, states) })
            ) {
                ForEach(SetComparator.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(width: 70)

            ForEach(ReconcileState.allCases, id: \.self) { state in
                Toggle(ReconcileLabel.name(state), isOn: Binding(
                    get: { states.contains(state) },
                    set: { on in
                        var next = states
                        if on { next.insert(state) } else { next.remove(state) }
                        criterion.test = .reconcile(comparator, next)
                    }))
            }

        case .account(let comparator, let ids):
            Picker("", selection: Binding(
                get: { comparator },
                set: { criterion.test = .account($0, ids) })
            ) {
                ForEach(SetComparator.allCases, id: \.self) { Text($0.accountLabel).tag($0) }
            }
            .labelsHidden()
            .frame(width: 190)

            // A tree behind a button, as GnuCash does it — 559 accounts is far
            // too many for an inline menu.
            Button(accountLabel(ids)) { accountPickerShown = true }
                .frame(width: 200)
                .popover(isPresented: $accountPickerShown) {
                    AccountMatchPicker(tree: accountTree, selection: Binding(
                        get: { ids },
                        set: { criterion.test = .account(comparator, $0) }))
                }

        case .balanced(let want):
            Picker("", selection: Binding(
                get: { want },
                set: { criterion.test = .balanced($0) })
            ) {
                Text("is balanced").tag(true)
                Text("is not balanced").tag(false)
            }
            .labelsHidden()
            .frame(width: 170)
        }
    }

    private func accountLabel(_ ids: Set<GncGUID>) -> String {
        switch ids.count {
        case 0: "Choose…"
        case 1: accounts.first { $0.id == ids.first }?.name ?? "1 account"
        default: "\(ids.count) accounts"
        }
    }
}

/// The user-facing name of a reconcile state, matching GnuCash's Find dialog.
enum ReconcileLabel {
    static func name(_ state: ReconcileState) -> String {
        switch state {
        case .notReconciled: "Not Cleared"
        case .cleared: "Cleared"
        case .reconciled: "Reconciled"
        case .frozen: "Frozen"
        case .voided: "Voided"
        }
    }
}
