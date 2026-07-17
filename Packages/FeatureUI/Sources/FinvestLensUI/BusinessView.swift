//
//  BusinessView.swift
//  FinvestLens — FeatureUI
//
//  The Business surface (`FR-BUS-*`): a hub listing customers, vendors and
//  invoices, with editors to create parties and invoices/bills, post them to
//  A/R–A/P, and record payments. Aging lives in the report scaffold.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import FinvestLensEngine

// MARK: - Hub

struct BusinessHub: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private enum Editing: Identifiable {
        case customer, vendor
        case invoice(InvoiceKind)
        case payment
        case detail(GncGUID)
        var id: String {
            switch self {
            case .customer: "customer"
            case .vendor: "vendor"
            case .invoice(let k): "invoice-\(k.rawValue)"
            case .payment: "payment"
            case .detail(let id): "detail-\(id.hexString)"
            }
        }
    }
    @State private var editing: Editing?

    private var code: String { model.reportCurrency.mnemonic }

    var body: some View {
        NavigationStack {
            List {
                Section("New") {
                    Button("New Customer…", systemImage: "person.badge.plus") { editing = .customer }
                    Button("New Vendor…", systemImage: "building.2") { editing = .vendor }
                    Button("New Invoice…", systemImage: "doc.badge.plus") { editing = .invoice(.invoice) }
                        .disabled(model.businessCustomers.isEmpty)
                    Button("New Bill…", systemImage: "doc.text") { editing = .invoice(.bill) }
                        .disabled(model.businessVendors.isEmpty)
                    Button("Process Payment…", systemImage: "dollarsign.circle") { editing = .payment }
                        .disabled(model.businessInvoices.isEmpty)
                }
                if !model.businessInvoices.isEmpty {
                    Section("Invoices & Bills") {
                        ForEach(model.businessInvoices) { invoice in
                            Button { editing = .detail(invoice.guid) } label: {
                                invoiceRow(invoice)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Section("Customers") {
                    if model.businessCustomers.isEmpty {
                        Text("No customers yet.").foregroundStyle(.secondary)
                    }
                    ForEach(model.businessCustomers) { customer in
                        HStack {
                            Text(customer.name)
                            Spacer()
                            let owed = outstanding(forOwner: customer.guid)
                            if owed != 0 {
                                Text(AmountFormat.string(owed, code: code))
                                    .monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Vendors") {
                    if model.businessVendors.isEmpty {
                        Text("No vendors yet.").foregroundStyle(.secondary)
                    }
                    ForEach(model.businessVendors) { vendor in
                        HStack {
                            Text(vendor.name)
                            Spacer()
                            let owed = outstanding(forOwner: vendor.guid)
                            if owed != 0 {
                                Text(AmountFormat.string(owed, code: code))
                                    .monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Business")
            .frame(minWidth: 460, minHeight: 460)
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("New Customer…") { editing = .customer }
                        Button("New Vendor…") { editing = .vendor }
                        Divider()
                        Button("New Invoice…") { editing = .invoice(.invoice) }
                            .disabled(model.businessCustomers.isEmpty)
                        Button("New Bill…") { editing = .invoice(.bill) }
                            .disabled(model.businessVendors.isEmpty)
                        Divider()
                        Button("Process Payment…") { editing = .payment }
                    } label: {
                        Label("New", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $editing) { item in
                switch item {
                case .customer: PartyEditorSheet(model: model, isCustomer: true)
                case .vendor: PartyEditorSheet(model: model, isCustomer: false)
                case .invoice(let kind): InvoiceEditorSheet(model: model, kind: kind)
                case .payment: ProcessPaymentSheet(model: model)
                case .detail(let id): InvoiceDetailSheet(model: model, invoiceID: id)
                }
            }
        }
    }

    private func invoiceRow(_ invoice: Invoice) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(invoice.id) · \(invoice.owner.displayName)").fontWeight(.medium)
                Text(invoice.kind == .invoice ? "Invoice"
                     : invoice.kind == .bill ? "Bill" : "Voucher")
                    .scaledFont(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(AmountFormat.string(invoice.total, code: code)).monospacedDigit()
                if !invoice.isPosted {
                    Text("Draft").scaledFont(.caption).foregroundStyle(.orange)
                } else {
                    let owed = model.outstanding(invoice.guid)
                    Text(owed == 0 ? "Paid" : "Owing \(AmountFormat.string(owed, code: code))")
                        .scaledFont(.caption)
                        .foregroundStyle(owed == 0 ? .green : .secondary)
                }
            }
        }
    }

    private func outstanding(forOwner guid: GncGUID) -> Decimal {
        (model.book?.invoices(forOwner: guid) ?? [])
            .reduce(0) { $0 + model.outstanding($1.guid) }
    }
}

// MARK: - Party editor

struct PartyEditorSheet: View {
    @Bindable var model: AppModel
    let isCustomer: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var id = ""
    @State private var name = ""
    @State private var email = ""
    @State private var line1 = ""
    @State private var termsID: GncGUID?
    @State private var taxTableID: GncGUID?
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("ID (e.g. 000001)", text: $id)
                TextField("Name", text: $name).focused($nameFocused)
                Section("Contact") {
                    TextField("Address line", text: $line1)
                    TextField("Email", text: $email)
                }
                Section("Defaults") {
                    Picker("Terms", selection: $termsID) {
                        Text("None").tag(GncGUID?.none)
                        ForEach(model.businessTerms) { term in
                            Text(term.name).tag(GncGUID?.some(term.guid))
                        }
                    }
                    Picker("Tax table", selection: $taxTableID) {
                        Text("None").tag(GncGUID?.none)
                        ForEach(model.businessTaxTables) { table in
                            Text(table.name).tag(GncGUID?.some(table.guid))
                        }
                    }
                }
            }
            .navigationTitle(isCustomer ? "New Customer" : "New Vendor")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { focusSoon { nameFocused = true } }
        }
    }

    private func add() {
        let address = BusinessAddress(name: name, line1: line1, email: email)
        let terms = termsID.flatMap { model.book?.billTerm(with: $0) }
        let table = taxTableID.flatMap { model.book?.taxTable(with: $0) }
        if isCustomer {
            model.addCustomer(id: id, name: name, address: address, terms: terms, taxTable: table)
        } else {
            model.addVendor(id: id, name: name, address: address, terms: terms, taxTable: table)
        }
        dismiss()
    }
}

// MARK: - Invoice editor

private struct LineDraft: Identifiable {
    let id = UUID()
    var accountID: GncGUID?
    var description = ""
    var quantity = "1"
    var price = ""
    var taxable = false
    var taxTableID: GncGUID?
}

struct InvoiceEditorSheet: View {
    @Bindable var model: AppModel
    let kind: InvoiceKind
    @Environment(\.dismiss) private var dismiss

    @State private var docID = ""
    @State private var ownerID: GncGUID?
    @State private var lines: [LineDraft] = [LineDraft()]
    @State private var postNow = true

    private var isInvoice: Bool { kind == .invoice }
    private var owners: [(GncGUID, String)] {
        isInvoice ? model.businessCustomers.map { ($0.guid, $0.name) }
                  : model.businessVendors.map { ($0.guid, $0.name) }
    }
    private var lineAccounts: [Account] {
        (model.book?.accounts ?? []).filter {
            !$0.isPlaceholder && $0.type == (isInvoice ? .income : .expense)
        }
    }

    private func dec(_ s: String) -> Decimal { Decimal(string: s.trimmingCharacters(in: .whitespaces)) ?? 0 }

    private var total: Decimal {
        lines.reduce(Decimal(0)) { running, line in
            let sub = dec(line.quantity) * dec(line.price)
            let table = line.taxTableID.flatMap { model.book?.taxTable(with: $0) }
            let tax = (line.taxable && table != nil) ? sub * table!.totalPercentage / 100 : 0
            return running + sub + tax
        }
    }
    private var canSave: Bool {
        ownerID != nil && lines.contains { $0.accountID != nil && dec($0.price) != 0 }
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Document number", text: $docID)
                Picker(isInvoice ? "Customer" : "Vendor", selection: $ownerID) {
                    Text("Choose…").tag(GncGUID?.none)
                    ForEach(owners, id: \.0) { Text($0.1).tag(GncGUID?.some($0.0)) }
                }
                Section("Lines") {
                    ForEach($lines) { $line in
                        VStack(spacing: 6) {
                            Picker("Account", selection: $line.accountID) {
                                Text("Choose…").tag(GncGUID?.none)
                                ForEach(lineAccounts) { Text($0.name).tag(GncGUID?.some($0.guid)) }
                            }
                            TextField("Description", text: $line.description)
                            HStack {
                                TextField("Qty", text: $line.quantity).frame(width: 60)
                                TextField("Price", text: $line.price)
                            }
                            Toggle("Taxable", isOn: $line.taxable)
                            if line.taxable {
                                Picker("Tax table", selection: $line.taxTableID) {
                                    Text("None").tag(GncGUID?.none)
                                    ForEach(model.businessTaxTables) {
                                        Text($0.name).tag(GncGUID?.some($0.guid))
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .onDelete { lines.remove(atOffsets: $0) }
                    Button("Add Line") { lines.append(LineDraft()) }
                }
                Section {
                    HStack {
                        Text("Total").fontWeight(.bold)
                        Spacer()
                        Text(AmountFormat.string(total, code: model.reportCurrency.mnemonic))
                            .monospacedDigit().fontWeight(.bold)
                    }
                    Toggle("Post immediately", isOn: $postNow)
                }
            }
            .navigationTitle(isInvoice ? "New Invoice" : "New Bill")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!canSave)
                }
            }
        }
    }

    private func save() {
        guard let ownerID else { return }
        let ownerType: OwnerType = isInvoice ? .customer : .vendor
        let inputs = lines.compactMap { line -> AppModel.InvoiceLineInput? in
            guard let account = line.accountID, dec(line.price) != 0 else { return nil }
            return .init(accountID: account, description: line.description,
                         quantity: dec(line.quantity), price: dec(line.price),
                         taxable: line.taxable, taxTableID: line.taxTableID)
        }
        guard let invoiceID = model.createInvoice(
            id: docID.isEmpty ? "\(isInvoice ? "INV" : "BILL")-\(model.businessInvoices.count + 1)" : docID,
            kind: kind, ownerType: ownerType, ownerID: ownerID, lines: inputs) else { return }
        if postNow { model.postInvoice(invoiceID) }
        dismiss()
    }
}

// MARK: - Invoice detail

struct InvoiceDetailSheet: View {
    @Bindable var model: AppModel
    let invoiceID: GncGUID
    @Environment(\.dismiss) private var dismiss
    @State private var paying = false

    private var invoice: Invoice? { model.book?.invoice(with: invoiceID) }
    private var code: String { model.reportCurrency.mnemonic }

    var body: some View {
        NavigationStack {
            if let invoice {
                Form {
                    LabeledContent("Document", value: invoice.id)
                    LabeledContent(invoice.kind == .invoice ? "Customer" : "Vendor",
                                   value: invoice.owner.displayName)
                    LabeledContent("Opened", value: invoice.dateOpened.formatted(date: .abbreviated, time: .omitted))
                    if let due = invoice.dueDate {
                        LabeledContent("Due", value: due.formatted(date: .abbreviated, time: .omitted))
                    }
                    Section("Lines") {
                        ForEach(invoice.entries) { entry in
                            HStack {
                                Text(entry.entryDescription.isEmpty ? (entry.account?.name ?? "Line")
                                     : entry.entryDescription)
                                Spacer()
                                Text(AmountFormat.string(entry.total, code: code)).monospacedDigit()
                            }
                        }
                    }
                    Section {
                        LabeledContent("Subtotal", value: AmountFormat.string(invoice.subtotal, code: code))
                        LabeledContent("Tax", value: AmountFormat.string(invoice.taxTotal, code: code))
                        LabeledContent("Total", value: AmountFormat.string(invoice.total, code: code))
                        if invoice.isPosted {
                            LabeledContent("Outstanding",
                                           value: AmountFormat.string(model.outstanding(invoiceID), code: code))
                        }
                    }
                }
                .navigationTitle(invoice.id)
                .onEscapeCommand { dismiss() }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        if !invoice.isPosted {
                            Button("Post") { model.postInvoice(invoiceID) }
                        } else if model.outstanding(invoiceID) > 0 {
                            Button("Record Payment") { paying = true }
                        } else {
                            Button("Unpost") { model.unpostInvoice(invoiceID) }
                        }
                    }
                }
                .sheet(isPresented: $paying) {
                    ProcessPaymentSheet(model: model,
                                        presetOwner: (invoice.owner.type, invoice.owner.guid),
                                        presetAmount: model.outstanding(invoiceID))
                }
            } else {
                Text("This invoice no longer exists.").padding()
            }
        }
    }
}

// MARK: - Process payment

struct ProcessPaymentSheet: View {
    @Bindable var model: AppModel
    var presetOwner: (OwnerType, GncGUID)?
    var presetAmount: Decimal?
    @Environment(\.dismiss) private var dismiss

    @State private var isCustomer = true
    @State private var ownerID: GncGUID?
    @State private var amount = ""
    @State private var fromAccountID: GncGUID?

    private var owners: [(GncGUID, String)] {
        isCustomer ? model.businessCustomers.map { ($0.guid, $0.name) }
                   : model.businessVendors.map { ($0.guid, $0.name) }
    }
    private var bankAccounts: [Account] {
        (model.book?.accounts ?? []).filter {
            !$0.isPlaceholder && ($0.type == .bank || $0.type == .cash || $0.type == .asset)
        }
    }
    private func dec(_ s: String) -> Decimal { Decimal(string: s.trimmingCharacters(in: .whitespaces)) ?? 0 }

    var body: some View {
        NavigationStack {
            Form {
                if presetOwner == nil {
                    Picker("Paying party", selection: $isCustomer) {
                        Text("Customer receipt").tag(true)
                        Text("Vendor payment").tag(false)
                    }
                    .pickerStyle(.segmented)
                    Picker(isCustomer ? "Customer" : "Vendor", selection: $ownerID) {
                        Text("Choose…").tag(GncGUID?.none)
                        ForEach(owners, id: \.0) { Text($0.1).tag(GncGUID?.some($0.0)) }
                    }
                }
                TextField("Amount", text: $amount)
                Picker(isCustomer ? "Deposit to" : "Pay from", selection: $fromAccountID) {
                    Text("Choose…").tag(GncGUID?.none)
                    ForEach(bankAccounts) { Text($0.name).tag(GncGUID?.some($0.guid)) }
                }
            }
            .navigationTitle("Process Payment")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { apply() }
                        .disabled(ownerID == nil || fromAccountID == nil || dec(amount) <= 0)
                }
            }
            .onAppear {
                if let preset = presetOwner {
                    isCustomer = preset.0 == .customer
                    ownerID = preset.1
                }
                if let presetAmount, amount.isEmpty { amount = "\(presetAmount)" }
            }
        }
    }

    private func apply() {
        guard let ownerID, let fromAccountID else { return }
        model.processPayment(ownerType: isCustomer ? .customer : .vendor, ownerID: ownerID,
                             amount: dec(amount), fromAccountID: fromAccountID)
        dismiss()
    }
}
