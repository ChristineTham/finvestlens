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
    @Environment(\.appDateFormat) private var dateFormat
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
                    Text(dateFormat.short(doc.date))
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

// MARK: - Tax Report Options

/// Flag income/expense accounts as tax-related, give them a tax category code,
/// and see the resulting tax schedule for a period (GnuCash's Edit ▸ Tax Report
/// Options plus its tax schedule). Flags round-trip with GnuCash via the
/// `tax-related` / `tax-US` account slots.
struct TaxOptionsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var year = TaxOptionsView.defaultYear

    private static var defaultYear: Int {
        // A fixed default; the picker covers the useful range either side.
        2026
    }

    private var range: (from: Date, to: Date) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let from = cal.date(from: DateComponents(year: year, month: 1, day: 1))!
        let to = cal.date(from: DateComponents(year: year, month: 12, day: 31))!
        return (from, to)
    }

    private var accounts: [AppModel.TaxAccount] {
        model.taxAccounts(from: range.from, to: range.to)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Tax year", selection: $year) {
                    ForEach((2015...2030).reversed(), id: \.self) { Text(String($0)).tag($0) }
                }
                .pickerStyle(.menu).fixedSize().padding(8)
                Divider()
                List {
                    let flagged = accounts.filter(\.taxRelated)
                    if !flagged.isEmpty {
                        Section("Tax schedule \(String(year))") {
                            ForEach(flagged) { row in scheduleRow(row) }
                        }
                    }
                    Section("Accounts") {
                        ForEach(accounts) { row in accountRow(row) }
                    }
                }
            }
            .navigationTitle("Tax Report Options")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 480)
    }

    private func scheduleRow(_ row: AppModel.TaxAccount) -> some View {
        HStack {
            Text(row.name).scaledFont(.body)
            if let code = row.taxCode {
                Text(code).scaledFont(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            Spacer()
            Text(AmountFormat.string(row.periodBalance, code: row.currencyCode))
                .monospacedDigit().scaledFont(.body)
        }
    }

    private func accountRow(_ row: AppModel.TaxAccount) -> some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(
                get: { row.taxRelated },
                set: { model.setAccountTax(id: row.id, related: $0, code: row.taxCode) })) {
                    Text(row.name).scaledFont(.body)
                }
                .checkboxToggleStyle()
            Spacer()
            if row.taxRelated {
                TextField("Code", text: Binding(
                    get: { row.taxCode ?? "" },
                    set: { model.setAccountTax(id: row.id, related: true,
                                               code: $0.isEmpty ? nil : $0) }))
                    .frame(width: 110).scaledFont(.caption)
            }
        }
    }
}

// MARK: - Period-end Close Book

/// Moves income and expense balances into an equity account as of a date, so
/// the profit-and-loss accounts start the next period at zero (GnuCash's
/// Tools ▸ Close Book). Previews the effect before posting; the post is one
/// undoable action.
struct CloseBookView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var date = Date()
    @State private var equityID: GncGUID?
    @State private var description = "Closing Entries"
    @State private var posted: Int?

    private var equityChoices: [(id: GncGUID, name: String)] { model.equityAccountChoices }
    private var code: String { model.reportCurrency.mnemonic }

    private var preview: (accounts: Int, byCurrency: [AppModel.ClosingCurrencyPreview])? {
        guard let equityID else { return nil }
        return model.closingPreview(asOf: date, equityID: equityID)
    }

    var body: some View {
        NavigationStack {
            Form {
                if equityChoices.isEmpty {
                    ContentUnavailableView("No equity account", systemImage: "building.columns",
                        description: Text("Create an equity account (e.g. Retained Earnings) to close into."))
                } else {
                    Section("Close as of") {
                        DatePicker("Date", selection: $date, displayedComponents: .date)
                        Picker("Into equity", selection: $equityID) {
                            Text("Choose…").tag(GncGUID?.none)
                            ForEach(equityChoices, id: \.id) { choice in
                                Text(choice.name).tag(GncGUID?.some(choice.id))
                            }
                        }
                        TextField("Description", text: $description)
                    }
                    Section("Preview") {
                        if let preview {
                            LabeledContent("Accounts to close") { Text("\(preview.accounts)") }
                            // One net per currency — a multi-currency book closes
                            // into a balanced transaction per currency.
                            ForEach(preview.byCurrency) { row in
                                LabeledContent("Net to equity (\(row.currencyCode))") {
                                    Text(AmountFormat.string(row.netToEquity, code: row.currencyCode))
                                        .monospacedDigit()
                                }
                            }
                            if preview.accounts == 0 {
                                Text("Nothing has a balance to close as of this date.")
                                    .foregroundStyle(.secondary).scaledFont(.caption)
                            } else if preview.byCurrency.count > 1 {
                                Text("Spans \(preview.byCurrency.count) currencies — one closing transaction each.")
                                    .foregroundStyle(.secondary).scaledFont(.caption)
                            }
                        } else {
                            Text("Choose an equity account to preview.")
                                .foregroundStyle(.secondary).scaledFont(.caption)
                        }
                    }
                    if let posted {
                        Section {
                            Label("Closed \(posted) account\(posted == 1 ? "" : "s"). Undo with ⌘Z.",
                                  systemImage: "checkmark.circle")
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Close Book")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close Book") {
                        if let equityID { posted = model.closeBook(asOf: date, equityID: equityID,
                                                                   description: description) }
                    }
                    .disabled(equityID == nil || (preview?.accounts ?? 0) == 0)
                }
            }
        }
        .frame(minWidth: 460, minHeight: 420)
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
    @State private var showingCreatePayment = false

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
                Section {
                    Button("Create Scheduled Payment…") { showingCreatePayment = true }
                        .disabled(model.postableAccounts.count < 3)
                    Text("Generates a scheduled transaction (GnuCash's Mortgage/Loan assistant): the fixed payment, split into a variable **interest** amount — you enter each period from the schedule above — and the remaining **principal**.")
                        .scaledFont(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Loan Calculator")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingCreatePayment) {
                CreateLoanPaymentSheet(model: model, loan: loan, onCreated: { dismiss() })
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

/// Picks the accounts for a loan-payment scheduled transaction and creates it
/// (GnuCash's Mortgage/Loan assistant, `FR-SCH-04`).
struct CreateLoanPaymentSheet: View {
    @Bindable var model: AppModel
    let loan: LoanCalculator
    var onCreated: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = "Loan payment"
    @State private var startDate = Date()
    @State private var fromID: GncGUID?
    @State private var principalID: GncGUID?
    @State private var interestID: GncGUID?

    private var isValid: Bool {
        guard let fromID, let principalID, let interestID else { return false }
        return Set([fromID, principalID, interestID]).count == 3
            && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Payment") {
                    TextField("Name", text: $name)
                    DatePicker("First payment", selection: $startDate, displayedComponents: .date)
                    LabeledContent("Amount") {
                        Text(AmountFormat.string(loan.payment, code: model.reportCurrency.mnemonic))
                            .monospacedDigit()
                    }
                }
                Section("Accounts") {
                    accountPicker("Pay from", $fromID)
                    accountPicker("Principal (liability)", $principalID)
                    accountPicker("Interest (expense)", $interestID)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Scheduled Loan Payment")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        guard let fromID, let principalID, let interestID else { return }
                        let sx = loan.scheduledPayment(
                            name: name, currency: model.reportCurrency, startDate: startDate,
                            from: fromID, principal: principalID, interest: interestID)
                        model.addScheduledTransaction(sx)
                        dismiss()
                        onCreated()
                    }
                    .disabled(!isValid)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 320)
    }

    private func accountPicker(_ label: String, _ selection: Binding<GncGUID?>) -> some View {
        Picker(label, selection: selection) {
            Text("—").tag(GncGUID?.none)
            ForEach(model.postableAccounts) { Text($0.fullName).tag(GncGUID?.some($0.id)) }
        }
    }
}
