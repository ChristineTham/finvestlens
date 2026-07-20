//
//  ReconcileView.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import TipKit
import FinvestLensEngine

/// Public window host for the reconcile flow — a dedicated window (HIG: a
/// prolonged multistep task isn't a sheet), so the account register stays
/// visible in the main window behind it. Closing the window ends the flow.
public struct ReconcileWindow: View {
    @Bindable var model: AppModel
    let accountID: GncGUID
    public init(model: AppModel, accountID: GncGUID) {
        self.model = model
        self.accountID = accountID
    }
    public var body: some View {
        ReconcileView(model: model, accountID: accountID)
    }
}

/// The reconciliation workflow: enter a statement, tick off items until the
/// difference is zero, then finish (`FR-REC-01`).
struct ReconcileView: View {
    @Bindable var model: AppModel
    let accountID: GncGUID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appFontScale) private var appFontScale
    private var dateWidth: CGFloat { 96 * appFontScale }

    @State private var statementDate = Date()
    @State private var endingBalanceText = ""
    /// Why an auto-clear did not happen. Worth saying out loud: "nothing
    /// changed" and "two answers, so I won't guess" look identical otherwise.
    @State private var autoClearMessage: String?

    var body: some View {
        NavigationStack {
            if let session = model.reconcileSession, session.accountID == accountID {
                reconciling(session)
            } else {
                setupForm
            }
        }
        .frame(minWidth: 480, minHeight: 440)
    }

    // MARK: Setup

    private var setupForm: some View {
        Form {
            TipView(ReconcileTip())
            DatePicker("Statement date", selection: $statementDate, displayedComponents: .date)
            TextField("Statement ending balance", text: $endingBalanceText)
                .multilineTextAlignment(.trailing)

            if let last = model.lastReconciliationDate(accountID: accountID) {
                Section {
                    Button("Re-open Last Reconciliation…") {
                        let reverted = model.reopenLastReconciliation(accountID: accountID)
                        autoClearMessage = reverted > 0
                            ? "Re-opened \(reverted) reconciled split\(reverted == 1 ? "" : "s") — they're now cleared and can be reconciled again."
                            : "Nothing to re-open."
                    }
                    Text("The most recent reconciliation was \(last, format: .dateTime.year().month().day()). Re-opening reverts those splits to cleared so you can reconcile the statement again (FR-REC-03).")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Reconcile")
        .alert("Reconciliation", isPresented: Binding(
            get: { autoClearMessage != nil }, set: { if !$0 { autoClearMessage = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(autoClearMessage ?? "") }
        .onEscapeCommand { dismiss() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Start") {
                    model.beginReconcile(accountID: accountID, statementDate: statementDate,
                                         statementBalance: Decimal(string: endingBalanceText) ?? 0)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(Decimal(string: endingBalanceText) == nil)
            }
        }
    }

    // MARK: Reconciling

    private func reconciling(_ session: ReconcileSessionState) -> some View {
        VStack(spacing: 0) {
            summary(session)
            Divider()
            List {
                ForEach(session.items) { item in
                    Button {
                        model.toggleReconcileItem(item.id)
                    } label: {
                        HStack {
                            Image(systemName: item.isCleared ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(item.isCleared ? Color.accentColor : Color.secondary)
                                .accessibilityHidden(true)
                            Text(item.date, format: .dateTime.year().month().day())
                                .foregroundStyle(.secondary)
                                .frame(width: dateWidth, alignment: .leading)
                            Text(item.description)
                            Spacer()
                            Text(AmountFormat.string(item.amount, code: session.currencyCode))
                                .monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(item.isCleared ? "Cleared" : "Not cleared")
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Reconcile \(session.accountName)")
        .onEscapeCommand { model.cancelReconcile(); dismiss() }
        .alert("Auto-clear", isPresented: Binding(
            get: { autoClearMessage != nil },
            set: { if !$0 { autoClearMessage = nil } })) {
            Button("OK", role: .cancel) { autoClearMessage = nil }
        } message: {
            Text(autoClearMessage ?? "")
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { model.cancelReconcile(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            ToolbarItem {
                // Only ticks the boxes — nothing reaches the book until Finish,
                // so an answer you disagree with costs a Cancel, not an undo.
                Button("Auto-clear", systemImage: "wand.and.stars") {
                    switch model.autoClear() {
                    case .success: break
                    case .failure(let failure): autoClearMessage = model.describe(failure)
                    }
                }
                .help("Tick the transactions that add up to the statement balance")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Finish") {
                    if model.finishReconcile() { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!session.isBalanced)
            }
        }
    }

    private func summary(_ session: ReconcileSessionState) -> some View {
        HStack(spacing: 24) {
            stat("Starting", session.startingBalance, session.currencyCode)
            stat("Cleared", session.clearedBalance, session.currencyCode)
            stat("Statement", session.statementBalance, session.currencyCode)
            stat("Difference", session.difference, session.currencyCode,
                 highlight: session.isBalanced ? .green : .red)
        }
        .padding()
    }

    private func stat(_ label: String, _ amount: Decimal, _ code: String,
                      highlight: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).scaledFont(.caption).foregroundStyle(.secondary)
            Text(AmountFormat.string(amount, code: code))
                .monospacedDigit()
                .foregroundStyle(highlight)
        }
    }
}
