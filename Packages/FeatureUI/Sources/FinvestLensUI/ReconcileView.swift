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
    @Environment(\.appDateFormat) private var dateFormat
    @Bindable var model: AppModel
    let accountID: GncGUID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appFontScale) private var appFontScale
    private var dateWidth: CGFloat { 96 * appFontScale }

    @State private var statementDate = Date()
    @State private var endingBalanceText = ""
    /// Outcome of re-opening a reconciliation (setup form only).
    @State private var autoClearMessage: String?
    /// What the opening (or a re-run) auto-clear did — an inline status line,
    /// not an alert: it is the flow's first move, not an interruption (RD3).
    @State private var autoClearStatus: String?
    /// The opening auto-clear runs once per window, not once per body pass.
    @State private var didOpeningAutoClear = false

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
                    Text("The most recent reconciliation was \(dateFormat.long(last)). Re-opening reverts those splits to cleared so you can reconcile the statement again (FR-REC-03).")
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
            headline(session)
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
                            Text(dateFormat.short(item.date))
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
        // The opening move (RD3): auto-clear runs the moment the session
        // starts, and the flow becomes "review what's left" instead of
        // "tick 43 boxes". Nothing reaches the book until Finish, so an
        // answer you disagree with costs unticking, not an undo.
        .task {
            guard !didOpeningAutoClear else { return }
            didOpeningAutoClear = true
            runAutoClear(total: session.items.count)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { model.cancelReconcile(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            ToolbarItem {
                // Re-run after hand edits; the opening run already happened.
                Button("Auto-clear", systemImage: "wand.and.stars") {
                    runAutoClear(total: model.reconcileSession?.items.count ?? 0)
                }
                .help("Tick the transactions that add up to the statement balance")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Finish") {
                    if model.finishReconcile() { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!session.isBalanced)
                .help(session.isBalanced
                      ? "Mark the ticked transactions reconciled"
                      : "Finish unlocks when the difference reaches zero")
            }
        }
    }

    /// Runs the solver and turns its outcome into the status line under the
    /// headline — "matched 41 of 43", or the reason it declined to guess.
    private func runAutoClear(total: Int) {
        switch model.autoClear() {
        case .success(let matched):
            let session = model.reconcileSession
            if session?.isBalanced == true {
                autoClearStatus = matched == total
                    ? "All \(total) transaction\(total == 1 ? "" : "s") match the statement."
                    : "Matched \(matched) of \(total) — the statement balances. Review, then Finish."
            } else {
                autoClearStatus = "Matched \(matched) of \(total) automatically — review the rest."
            }
        case .failure(let failure):
            autoClearStatus = model.describe(failure)
        }
    }

    /// The one number that is the job (RD3): the difference remaining, live,
    /// with Finish's why-not built in.
    private func headline(_ session: ReconcileSessionState) -> some View {
        HStack(alignment: .firstTextBaseline) {
            if session.isBalanced {
                Label("Balanced — ready to Finish", systemImage: "checkmark.seal.fill")
                    .scaledFont(.title3, weight: .semibold)
                    .foregroundStyle(.green)
            } else {
                Text("Difference remaining")
                    .scaledFont(.title3, weight: .semibold)
                Text(AmountFormat.string(session.difference, code: session.currencyCode))
                    .scaledFont(.title3, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(.red)
                    .contentTransition(.numericText())
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .animation(.default, value: session.isBalanced)
    }

    private func summary(_ session: ReconcileSessionState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 24) {
                stat("Starting", session.startingBalance, session.currencyCode)
                stat("Cleared", session.clearedBalance, session.currencyCode)
                stat("Statement", session.statementBalance, session.currencyCode)
            }
            if let autoClearStatus {
                Label(autoClearStatus, systemImage: "wand.and.stars")
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 10)
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
