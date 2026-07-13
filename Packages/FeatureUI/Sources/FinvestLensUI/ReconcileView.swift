//
//  ReconcileView.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import FinvestLensEngine

/// The reconciliation workflow: enter a statement, tick off items until the
/// difference is zero, then finish (`FR-REC-01`).
struct ReconcileView: View {
    @Bindable var model: AppModel
    let accountID: GncGUID
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric private var dateWidth: CGFloat = 96

    @State private var statementDate = Date()
    @State private var endingBalanceText = ""

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
            DatePicker("Statement date", selection: $statementDate, displayedComponents: .date)
            TextField("Statement ending balance", text: $endingBalanceText)
                .multilineTextAlignment(.trailing)
        }
        .navigationTitle("Reconcile")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Start") {
                    model.beginReconcile(accountID: accountID, statementDate: statementDate,
                                         statementBalance: Decimal(string: endingBalanceText) ?? 0)
                }
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
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { model.cancelReconcile(); dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Finish") {
                    if model.finishReconcile() { dismiss() }
                }
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
