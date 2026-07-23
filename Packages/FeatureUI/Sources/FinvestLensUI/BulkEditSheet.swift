//
//  BulkEditSheet.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import FinvestLensEngine

/// Bulk edit of the selected transactions: each field has an enable toggle, and
/// only enabled fields are applied — uniformly, to every selected transaction —
/// while everything else is left exactly as it is. One undoable action.
struct BulkEditSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var setDate = false
    @State private var date = Date()
    @State private var setDescription = false
    @State private var descriptionText = ""
    @State private var setTransfer = false
    @State private var transferID: GncGUID?
    @State private var setMemo = false
    @State private var memoText = ""
    @State private var setNotes = false
    @State private var notesText = ""
    @State private var setReconcile = false
    @State private var reconcile: ReconcileState = .cleared

    private var splitIDs: Set<GncGUID> { model.selectedSplitIDs }
    private var transactionCount: Int { model.selectedTransactionIDs.count }
    /// How many of the selection the Transfer change can apply to (simple
    /// two-leg transactions — the same rule as inline editing).
    private var simpleCount: Int {
        splitIDs.filter { model.isSimpleTransfer(splitID: $0) }.count
    }

    private var anythingEnabled: Bool {
        setDate || setDescription || setTransfer || setMemo || setNotes || setReconcile
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Enabled fields apply uniformly to all \(transactionCount) selected transaction\(transactionCount == 1 ? "" : "s"); everything else is kept as it is.")
                        .scaledFont(.callout)
                        .foregroundStyle(.secondary)
                }
                Section("Set") {
                    HStack {
                        Toggle("Date", isOn: $setDate)
                        Spacer()
                        DatePicker("", selection: $date, displayedComponents: .date)
                            .labelsHidden()
                            .disabled(!setDate)
                    }
                    HStack {
                        Toggle("Description", isOn: $setDescription)
                        TextField("Description", text: $descriptionText)
                            .multilineTextAlignment(.trailing)
                            .disabled(!setDescription)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Toggle("Transfer account", isOn: $setTransfer)
                            Spacer()
                            AccountField(nodes: model.postableAccounts, selection: $transferID)
                                .frame(maxWidth: 220)
                                .disabled(!setTransfer)
                        }
                        if setTransfer, simpleCount < splitIDs.count {
                            Text("Applies to the \(simpleCount) simple transfer\(simpleCount == 1 ? "" : "s") — multi-split, security and multi-currency transactions are left unchanged.")
                                .scaledFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Toggle("Memo", isOn: $setMemo)
                        TextField("Empty clears", text: $memoText)
                            .multilineTextAlignment(.trailing)
                            .disabled(!setMemo)
                    }
                    HStack {
                        Toggle("Notes", isOn: $setNotes)
                        TextField("Empty clears", text: $notesText)
                            .multilineTextAlignment(.trailing)
                            .disabled(!setNotes)
                    }
                    HStack {
                        Toggle("Reconcile state", isOn: $setReconcile)
                        Spacer()
                        Picker("", selection: $reconcile) {
                            ForEach(ReconcileState.allCases, id: \.self) { state in
                                Text(ReconcileBadge.word(state.rawValue)).tag(state)
                            }
                        }
                        .labelsHidden()
                        .disabled(!setReconcile)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Bulk Edit")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply to \(transactionCount)") {
                        apply()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!anythingEnabled || (setTransfer && transferID == nil)
                              || (setDescription && descriptionText.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
        }
        .frame(minWidth: 460, minHeight: 380)
    }

    private func apply() {
        var edit = AppModel.BulkTransactionEdit()
        if setDate { edit.date = date }
        if setDescription { edit.description = descriptionText }
        if setTransfer { edit.transferAccountID = transferID }
        if setMemo { edit.memo = memoText }
        if setNotes { edit.notes = notesText }
        if setReconcile { edit.reconcile = reconcile }
        model.applyBulkEdit(edit, toSplits: splitIDs)
    }
}
