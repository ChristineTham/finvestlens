//
//  TimeMileageView.swift
//  FinvestLens — FeatureUI
//
//  Billable time & mileage tracking (`FR-PLAN-14`): log hours or distance
//  against a customer, then gather the unbilled entries onto an invoice.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import FinvestLensEngine

struct TimeMileageView: View {
    @Environment(\.appDateFormat) private var dateFormat
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isEmbeddedDestination) private var embedded

    @State private var editing: BillableEntry?
    @State private var creating = false
    @State private var billingCustomer: Customer?

    private var code: String { model.reportCurrency.mnemonic }

    private var unbilled: [BillableEntry] {
        model.billableEntries.filter { !$0.billed }.sorted { $0.date < $1.date }
    }
    private var billed: [BillableEntry] {
        model.billableEntries.filter { $0.billed }.sorted { $0.date > $1.date }
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.billableEntries.isEmpty {
                    ContentUnavailableView {
                        Label("No time or mileage", systemImage: "clock.badge")
                    } description: {
                        Text("Log billable hours or travel, then gather them onto a customer invoice.")
                    } actions: {
                        Button("Log Entry") { creating = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.businessCustomers.isEmpty)
                    }
                } else {
                    List {
                        if !unbilled.isEmpty {
                            Section("Unbilled") {
                                ForEach(unbilled) { entry in row(entry) }
                            }
                            if !model.customersWithUnbilledEntries.isEmpty {
                                Section("Bill a customer") {
                                    ForEach(model.customersWithUnbilledEntries, id: \.guid) { customer in
                                        Button {
                                            billingCustomer = customer
                                        } label: {
                                            let entries = model.unbilledEntries(forCustomer: customer.guid)
                                            let total = entries.reduce(Decimal(0)) { $0 + $1.amount }
                                            LabeledContent(customer.name,
                                                value: "\(entries.count) entries · "
                                                    + AmountFormat.string(total, code: code))
                                        }
                                    }
                                }
                            }
                        }
                        if !billed.isEmpty {
                            Section("Billed") {
                                ForEach(billed) { entry in row(entry) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Time & Mileage")
            .onEscapeCommand { dismiss() }
            .toolbar {
                if !embedded {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                    }
                }
                ToolbarItem {
                    Button("Log Entry", systemImage: "plus") { creating = true }
                        .disabled(model.businessCustomers.isEmpty)
                }
            }
            .sheet(isPresented: $creating) { BillableEntrySheet(model: model, entry: nil) }
            .sheet(item: $editing) { entry in BillableEntrySheet(model: model, entry: entry) }
            .sheet(item: $billingCustomer) { customer in
                BillCustomerSheet(model: model, customer: customer)
            }
        }
        .frame(minWidth: embedded ? nil : 480, minHeight: embedded ? nil : 440)
    }

    @ViewBuilder
    private func row(_ entry: BillableEntry) -> some View {
        let customer = entry.customerID.flatMap { id in model.businessCustomers.first { $0.guid == id } }
        Button { editing = entry } label: {
            HStack {
                Image(systemName: entry.kind == .time ? "clock" : "car")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.detail.isEmpty ? entry.kind.rawValue.capitalized : entry.detail)
                    Text("\(customer?.name ?? "—") · \(dateFormat.short(entry.date))")
                        .scaledFont(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(AmountFormat.string(entry.amount, code: code)).monospacedDigit()
                    Text("\(entry.quantity.formatted()) × \(AmountFormat.string(entry.rate, code: code))")
                        .scaledFont(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .swipeActions {
            Button("Delete", role: .destructive) { model.deleteBillableEntry(entry.id) }
        }
    }
}

/// Logs or edits a billable entry.
private struct BillableEntrySheet: View {
    @Bindable var model: AppModel
    let entry: BillableEntry?
    @Environment(\.dismiss) private var dismiss

    @State private var kind: BillableEntry.Kind = .time
    @State private var date = Date()
    @State private var customerID: GncGUID?
    @State private var detail = ""
    @State private var quantity = ""
    @State private var rate = ""
    @State private var incomeID: GncGUID?

    private var incomeAccounts: [AccountNode] {
        model.postableAccounts.filter { $0.isType(.income) }
    }
    private func dec(_ s: String) -> Decimal { Decimal(string: s.trimmingCharacters(in: .whitespaces)) ?? 0 }
    private var isValid: Bool { customerID != nil && dec(quantity) > 0 }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Kind", selection: $kind) {
                    ForEach(BillableEntry.Kind.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                DatePicker("Date", selection: $date, displayedComponents: .date)
                Picker("Customer", selection: $customerID) {
                    Text("Choose…").tag(GncGUID?.none)
                    ForEach(model.businessCustomers, id: \.guid) { Text($0.name).tag(GncGUID?.some($0.guid)) }
                }
                TextField("Description", text: $detail)
                TextField(kind.quantityLabel, text: $quantity)
                TextField("Rate", text: $rate)
                LabeledContent("Income account") {
                    AccountField(prompt: "Choose at billing", nodes: incomeAccounts,
                                 selection: $incomeID)
                }
                if dec(quantity) > 0 {
                    LabeledContent("Amount", value: AmountFormat.string(
                        dec(quantity) * dec(rate), code: model.reportCurrency.mnemonic))
                }
            }
            .formStyle(.grouped)
            .navigationTitle(entry == nil ? "Log Entry" : "Edit Entry")
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
        .frame(minWidth: 380, minHeight: 380)
    }

    private func load() {
        guard let entry else { return }
        kind = entry.kind; date = entry.date; customerID = entry.customerID
        detail = entry.detail
        quantity = entry.quantity == 0 ? "" : "\(entry.quantity)"
        rate = entry.rate == 0 ? "" : "\(entry.rate)"
        incomeID = entry.incomeAccountID
    }

    private func save() {
        var edited = entry ?? BillableEntry()
        edited.kind = kind; edited.date = date; edited.customerID = customerID
        edited.detail = detail.trimmingCharacters(in: .whitespaces)
        edited.quantity = dec(quantity); edited.rate = dec(rate)
        edited.incomeAccountID = incomeID
        if entry == nil { model.addBillableEntry(edited) } else { model.updateBillableEntry(edited) }
        dismiss()
    }
}

/// Confirms the invoice number and gathers a customer's unbilled entries.
private struct BillCustomerSheet: View {
    @Bindable var model: AppModel
    let customer: Customer
    @Environment(\.dismiss) private var dismiss

    @State private var invoiceNumber = ""
    @State private var fallbackIncomeID: GncGUID?
    @State private var error: String?

    private var code: String { model.reportCurrency.mnemonic }
    private var entries: [BillableEntry] { model.unbilledEntries(forCustomer: customer.guid) }
    private var needsFallback: Bool { entries.contains { $0.incomeAccountID == nil } }
    private var incomeAccounts: [AccountNode] {
        model.postableAccounts.filter { $0.isType(.income) }
    }
    private var isValid: Bool {
        !invoiceNumber.trimmingCharacters(in: .whitespaces).isEmpty
            && (!needsFallback || fallbackIncomeID != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Customer", value: customer.name)
                    LabeledContent("Entries", value: "\(entries.count)")
                    LabeledContent("Total", value: AmountFormat.string(
                        entries.reduce(Decimal(0)) { $0 + $1.amount }, code: code))
                }
                TextField("Invoice number", text: $invoiceNumber)
                if needsFallback {
                    LabeledContent("Income account for un-assigned entries") {
                        AccountField(nodes: incomeAccounts, selection: $fallbackIncomeID)
                    }
                }
                if let error {
                    Text(error).scaledFont(.caption).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Create Invoice")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create Invoice") { create() }.disabled(!isValid)
                }
            }
        }
        .frame(minWidth: 400, minHeight: 300)
    }

    private func create() {
        let created = model.createInvoiceFromUnbilled(
            customerID: customer.guid, invoiceNumber: invoiceNumber,
            fallbackIncomeID: fallbackIncomeID)
        if created == nil {
            error = "Couldn't create the invoice — check the entries have an income account."
        } else {
            dismiss()
        }
    }
}
