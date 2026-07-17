//
//  ParityViews.swift
//  FinvestLens — FeatureUI
//
//  GnuCash-parity tools that surface existing engine capability:
//  the book-wide Linked Documents list (Tools ▸ Transaction Linked Documents)
//  and the Loan Repayment Calculator (Tools ▸ Loan Repayment Calculator).
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import FinvestLensEngine

// MARK: - Linked Documents

/// Every transaction with an attached document, in one list — the roll-up
/// GnuCash offers so links aren't reachable only one register row at a time.
struct LinkedDocumentsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var editingTransactionID: GncGUID?

    var body: some View {
        NavigationStack {
            Group {
                let docs = model.linkedDocuments()
                if docs.isEmpty {
                    ContentUnavailableView("No linked documents", systemImage: "paperclip",
                        description: Text("Attach a receipt or invoice to a transaction and it appears here."))
                } else {
                    List(docs) { doc in
                        row(doc)
                    }
                }
            }
            .navigationTitle("Linked Documents")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $editingTransactionID) { id in
                TransactionEditorSheet(model: model, editingID: id)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    private func row(_ doc: AppModel.LinkedDocument) -> some View {
        HStack(spacing: 10) {
            Image(systemName: doc.isWeb ? "link" : (doc.exists ? "doc.fill" : "doc.badge.gearshape"))
                .foregroundStyle(doc.exists ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(doc.description.isEmpty ? "(no description)" : doc.description)
                    .scaledFont(.body)
                HStack(spacing: 6) {
                    Text(doc.date, format: .dateTime.year().month().day())
                    Text("·")
                    Text(doc.displayName).lineLimit(1).truncationMode(.middle)
                    if !doc.exists && !doc.isWeb {
                        Text("· missing").foregroundStyle(.red)
                    }
                }
                .scaledFont(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open") { model.openLinkedDocument(for: doc.id) }
                .buttonStyle(.borderless)
                .disabled(!doc.exists)
            Button("Edit") { editingTransactionID = doc.id }
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Loan Repayment Calculator

/// A fixed-rate loan calculator (GnuCash's Tools ▸ Loan Repayment Calculator).
/// Pure arithmetic — it never reads or writes the book.
struct LoanCalculatorView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var principal = 300_000.0
    @State private var ratePercent = 6.0
    @State private var years = 30.0
    @State private var paymentsPerYear = 12
    @State private var showSchedule = false

    private var loan: LoanCalculator {
        LoanCalculator(principal: Decimal(principal),
                       annualRatePercent: Decimal(ratePercent),
                       years: years, paymentsPerYear: paymentsPerYear)
    }

    private var code: String { model.reportCurrency.mnemonic }

    var body: some View {
        NavigationStack {
            Form {
                Section("Loan") {
                    LabeledContent("Amount") {
                        TextField("Amount", value: $principal, format: .number)
                            .multilineTextAlignment(.trailing).frame(width: 140)
                    }
                    LabeledContent("Annual rate %") {
                        TextField("Rate", value: $ratePercent, format: .number)
                            .multilineTextAlignment(.trailing).frame(width: 140)
                    }
                    LabeledContent("Years") {
                        TextField("Years", value: $years, format: .number)
                            .multilineTextAlignment(.trailing).frame(width: 140)
                    }
                    Picker("Payments / year", selection: $paymentsPerYear) {
                        Text("Monthly (12)").tag(12)
                        Text("Fortnightly (26)").tag(26)
                        Text("Weekly (52)").tag(52)
                        Text("Quarterly (4)").tag(4)
                    }
                }
                Section("Result") {
                    LabeledContent("Payment") {
                        Text(AmountFormat.string(loan.payment, code: code)).monospacedDigit().bold()
                    }
                    LabeledContent("Number of payments") { Text("\(loan.numberOfPayments)") }
                    LabeledContent("Total paid") {
                        Text(AmountFormat.string(loan.totalPaid, code: code)).monospacedDigit()
                    }
                    LabeledContent("Total interest") {
                        Text(AmountFormat.string(loan.totalInterest, code: code)).monospacedDigit()
                    }
                    DisclosureGroup("Amortisation schedule", isExpanded: $showSchedule) {
                        if showSchedule { scheduleTable }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Loan Calculator")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 460)
    }

    private var scheduleTable: some View {
        // Bounded: a 30-year weekly loan is ~1,560 uniform rows — fine for a Table.
        Table(loan.schedule()) {
            TableColumn("#") { Text("\($0.number)") }.width(36)
            TableColumn("Payment") { Text(AmountFormat.string($0.payment, code: code)).monospacedDigit() }
            TableColumn("Interest") { Text(AmountFormat.string($0.interest, code: code)).monospacedDigit() }
            TableColumn("Principal") { Text(AmountFormat.string($0.principal, code: code)).monospacedDigit() }
            TableColumn("Balance") { Text(AmountFormat.string($0.balance, code: code)).monospacedDigit() }
        }
        .frame(minHeight: 220)
    }
}
