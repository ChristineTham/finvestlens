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

/// Business sheets hold engine `Account` lists; the shared `AccountField`
/// speaks `AccountNode`. Map by GUID through the model's flattened tree.
@MainActor
private func nodes(of accounts: [Account], in model: AppModel) -> [AccountNode] {
    let ids = Set(accounts.map(\.guid))
    return model.postableAccounts.filter { ids.contains($0.id) }
}
import UniformTypeIdentifiers
import FinvestLensEngine

// MARK: - Hub

struct BusinessHub: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isEmbeddedDestination) private var embedded

    private enum Editing: Identifiable {
        case customer, vendor, employee, job
        case term, taxTable, company
        case invoice(InvoiceKind)
        case payment
        case detail(GncGUID)
        var id: String {
            switch self {
            case .customer: "customer"
            case .vendor: "vendor"
            case .employee: "employee"
            case .job: "job"
            case .term: "term"
            case .taxTable: "taxTable"
            case .company: "company"
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
                    Button("New Employee…", systemImage: "person.text.rectangle") { editing = .employee }
                    Button("New Job…", systemImage: "briefcase") { editing = .job }
                        .disabled(model.businessCustomers.isEmpty && model.businessVendors.isEmpty)
                    Button("New Invoice…", systemImage: "doc.badge.plus") { editing = .invoice(.invoice) }
                        .disabled(model.businessCustomers.isEmpty)
                    Button("New Bill…", systemImage: "doc.text") { editing = .invoice(.bill) }
                        .disabled(model.businessVendors.isEmpty)
                    Button("Process Payment…", systemImage: "dollarsign.circle") { editing = .payment }
                        .disabled(model.businessInvoices.isEmpty)
                }
                Section("Setup") {
                    Button("Company Information…", systemImage: "building.columns") { editing = .company }
                    Button("Billing Terms…", systemImage: "calendar.badge.clock") { editing = .term }
                    Button("Tax Tables…", systemImage: "percent") { editing = .taxTable }
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
                if !model.businessEmployees.isEmpty {
                    Section("Employees") {
                        ForEach(model.businessEmployees) { employee in
                            Text(employee.address.name.isEmpty ? employee.username
                                 : employee.address.name)
                        }
                    }
                }
                if !model.businessJobs.isEmpty {
                    Section("Jobs") {
                        ForEach(model.businessJobs) { job in
                            HStack {
                                Text(job.name)
                                Spacer()
                                Text(job.owner.displayName)
                                    .scaledFont(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Business")
            .frame(minWidth: embedded ? nil : 460, minHeight: embedded ? nil : 460)
            .onEscapeCommand { dismiss() }
            .toolbar {
                if !embedded {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
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
                case .employee: EmployeeEditorSheet(model: model)
                case .job: JobEditorSheet(model: model)
                case .term: BillingTermsSheet(model: model)
                case .taxTable: TaxTablesSheet(model: model)
                case .company: CompanyInfoSheet(model: model)
                case .invoice(let kind): InvoiceEditorSheet(model: model, kind: kind)
                case .payment: ProcessPaymentSheet(model: model)
                case .detail(let id): InvoiceDetailSheet(model: model, invoiceID: id)
                }
            }
        }
    }

    private func kindLabel(_ invoice: Invoice) -> String {
        let base = invoice.kind == .invoice ? "Invoice"
            : invoice.kind == .bill ? "Bill" : "Voucher"
        return invoice.isCreditNote ? "Credit Note (\(base.lowercased()))" : base
    }

    private func invoiceRow(_ invoice: Invoice) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(invoice.id) · \(invoice.owner.displayName)").fontWeight(.medium)
                Text(kindLabel(invoice))
                    .scaledFont(.caption)
                    .foregroundStyle(invoice.isCreditNote ? Color.purple : Color.secondary)
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
    @State private var isCreditNote = false

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
                Toggle("Credit note", isOn: $isCreditNote)
                    .help(isInvoice
                          ? "Reduces what the customer owes instead of increasing it"
                          : "Reduces what you owe the vendor instead of increasing it")
                Section("Lines") {
                    ForEach($lines) { $line in
                        VStack(spacing: 6) {
                            AccountField(nodes: nodes(of: lineAccounts, in: model),
                                         selection: $line.accountID)
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
            id: docID.isEmpty ? "\(isInvoice ? (isCreditNote ? "CN" : "INV") : "BILL")-\(model.businessInvoices.count + 1)" : docID,
            kind: kind, isCreditNote: isCreditNote,
            ownerType: ownerType, ownerID: ownerID, lines: inputs) else { return }
        if postNow { model.postInvoice(invoiceID) }
        dismiss()
    }
}

// MARK: - Invoice detail

struct InvoiceDetailSheet: View {
    @Environment(\.appDateFormat) private var dateFormat
    @Bindable var model: AppModel
    let invoiceID: GncGUID
    @Environment(\.dismiss) private var dismiss
    @State private var paying = false
    @State private var exporting = false
    @State private var pdfDocument: PDFReportDocument?

    private var invoice: Invoice? { model.book?.invoice(with: invoiceID) }
    private var code: String { model.reportCurrency.mnemonic }

    var body: some View {
        NavigationStack {
            if let invoice {
                Form {
                    LabeledContent("Document", value: invoice.id)
                    if invoice.isCreditNote {
                        LabeledContent("Type") {
                            Text("Credit Note").foregroundStyle(.purple).fontWeight(.medium)
                        }
                    }
                    LabeledContent(invoice.kind == .invoice ? "Customer" : "Vendor",
                                   value: invoice.owner.displayName)
                    LabeledContent("Opened", value: dateFormat.long(invoice.dateOpened))
                    if let due = invoice.dueDate {
                        LabeledContent("Due", value: dateFormat.long(due))
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
                    ToolbarItem(placement: .secondaryAction) {
                        Menu("Save PDF…", systemImage: "square.and.arrow.down") {
                            Button("Standard Invoice") { exportPDF(invoice, layout: .standard) }
                            Button("Australian Tax Invoice") { exportPDF(invoice, layout: .taxInvoice) }
                        }
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
                .fileExporter(isPresented: $exporting, document: pdfDocument,
                              contentType: .pdf, defaultFilename: invoice.id) { _ in }
            } else {
                Text("This invoice no longer exists.").padding()
            }
        }
    }

    private func exportPDF(_ invoice: Invoice, layout: InvoiceLayout = .standard) {
        let view = PrintableInvoice(invoice: invoice, company: model.companyInfo,
                                    outstanding: invoice.isPosted ? model.outstanding(invoiceID) : nil,
                                    code: code, layout: layout)
        guard let data = ReportExport.pdf(view) else { return }
        pdfDocument = PDFReportDocument(data: data)
        exporting = true
    }
}

// MARK: - Printable invoice

/// Which invoice layout to render (`FR-BUS-03`). The Australian *Tax Invoice*
/// mirrors GnuCash's `taxinvoice.scm`: the ATO-required "Tax Invoice" wording,
/// the seller's ABN, a per-line GST rate column, and GST-labelled totals.
enum InvoiceLayout: Sendable { case standard, taxInvoice }

/// A static, print-ready rendering of an invoice — a company header, bill-to,
/// line items, and totals — for `ImageRenderer` (VStack, not List).
struct PrintableInvoice: View {
    let invoice: Invoice
    let company: CompanyInfo
    let outstanding: Decimal?
    let code: String
    var layout: InvoiceLayout = .standard

    private var isTax: Bool { layout == .taxInvoice }
    private func money(_ d: Decimal) -> String { AmountFormat.string(d, code: code) }
    private var title: String {
        if invoice.isCreditNote { return isTax ? "ADJUSTMENT NOTE" : "CREDIT NOTE" }
        if isTax { return "TAX INVOICE" }
        return invoice.kind == .invoice ? "INVOICE" : invoice.kind == .bill ? "BILL" : "VOUCHER"
    }

    /// The line's GST rate for the tax-invoice column: the tax table's combined
    /// percentage, or "—" when the line is not taxable.
    private func gstRate(_ entry: InvoiceEntry) -> String {
        guard entry.taxable, let table = entry.taxTable, table.totalPercentage != 0 else { return "—" }
        return "\(table.totalPercentage.formatted())%"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    if !company.name.isEmpty {
                        Text(company.name).font(.title2.bold())
                    }
                    forEachLine([company.addressLine1, company.addressLine2,
                                 company.phone, company.email, company.website,
                                 company.taxID.isEmpty ? ""
                                    : "\(isTax ? "ABN" : "Tax ID"): \(company.taxID)"])
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(title).font(.title.bold()).foregroundStyle(.secondary)
                    Text("No. \(invoice.id)").font(.headline)
                }
            }

            Divider()

            HStack(alignment: .top, spacing: 40) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(invoice.kind == .invoice ? "Bill To" : "From")
                        .font(.caption.bold()).foregroundStyle(.secondary)
                    Text(invoice.owner.displayName).fontWeight(.medium)
                    let addr = invoice.owner.address
                    forEachLine([addr.line1, addr.line2, addr.email])
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    labelled("Opened", AppDateFormat.current.long(invoice.dateOpened))
                    if let posted = invoice.datePosted {
                        labelled("Posted", AppDateFormat.current.long(posted))
                    }
                    if let due = invoice.dueDate {
                        labelled("Due", AppDateFormat.current.long(due))
                    }
                }
            }

            VStack(spacing: 0) {
                HStack {
                    Text("Description").fontWeight(.semibold)
                    Spacer()
                    Text("Qty").fontWeight(.semibold).frame(width: 60, alignment: .trailing)
                    Text("Price").fontWeight(.semibold).frame(width: 90, alignment: .trailing)
                    if isTax {
                        Text("GST Rate").fontWeight(.semibold).frame(width: 70, alignment: .trailing)
                    }
                    Text("Amount").fontWeight(.semibold).frame(width: 90, alignment: .trailing)
                }
                .padding(.vertical, 4)
                Divider()
                ForEach(invoice.entries) { entry in
                    HStack {
                        Text(entry.entryDescription.isEmpty ? (entry.account?.name ?? "Line")
                             : entry.entryDescription)
                        Spacer()
                        Text(entry.quantity.formatted()).frame(width: 60, alignment: .trailing)
                        Text(money(entry.price)).frame(width: 90, alignment: .trailing)
                        if isTax {
                            Text(gstRate(entry)).frame(width: 70, alignment: .trailing)
                        }
                        Text(money(entry.total)).frame(width: 90, alignment: .trailing)
                    }
                    .padding(.vertical, 3)
                    Divider()
                }
            }
            .monospacedDigit()

            HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    totalRow(isTax ? "Subtotal (excl GST)" : "Subtotal", invoice.subtotal)
                    totalRow(isTax ? "GST" : "Tax", invoice.taxTotal)
                    totalRow(isTax ? "Total (inc GST)" : "Total", invoice.total, bold: true)
                    if let outstanding {
                        totalRow("Outstanding", outstanding, bold: true)
                    }
                }
                .frame(width: 240)
            }

            if isTax {
                Text("Total price includes GST of \(money(invoice.taxTotal)).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.black)
    }

    @ViewBuilder private func forEachLine(_ lines: [String]) -> some View {
        ForEach(lines.filter { !$0.isEmpty }, id: \.self) { line in
            Text(line).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func labelled(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout)
        }
    }

    private func totalRow(_ label: String, _ amount: Decimal, bold: Bool = false) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(money(amount)).monospacedDigit()
        }
        .fontWeight(bold ? .bold : .regular)
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
                LabeledContent(isCustomer ? "Deposit to" : "Pay from") {
                    AccountField(nodes: nodes(of: bankAccounts, in: model), selection: $fromAccountID)
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

// MARK: - Employee editor

struct EmployeeEditorSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var id = ""
    @State private var username = ""
    @State private var name = ""
    @State private var email = ""
    @State private var line1 = ""
    @FocusState private var usernameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("ID (e.g. 000001)", text: $id)
                TextField("Username", text: $username).focused($usernameFocused)
                Section("Contact") {
                    TextField("Full name", text: $name)
                    TextField("Address line", text: $line1)
                    TextField("Email", text: $email)
                }
            }
            .navigationTitle("New Employee")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { focusSoon { usernameFocused = true } }
        }
    }

    private func add() {
        let address = BusinessAddress(name: name, line1: line1, email: email)
        model.addEmployee(id: id, username: username, address: address)
        dismiss()
    }
}

// MARK: - Job editor

struct JobEditorSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var id = ""
    @State private var name = ""
    @State private var reference = ""
    @State private var owner: OwnerRef?
    @FocusState private var nameFocused: Bool

    /// A customer or vendor a job can belong to.
    private struct OwnerRef: Hashable {
        var type: OwnerType
        var guid: GncGUID
    }
    private var owners: [(OwnerRef, String)] {
        model.businessCustomers.map { (OwnerRef(type: .customer, guid: $0.guid), "\($0.name) (customer)") }
        + model.businessVendors.map { (OwnerRef(type: .vendor, guid: $0.guid), "\($0.name) (vendor)") }
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("ID (e.g. 000001)", text: $id)
                TextField("Name", text: $name).focused($nameFocused)
                TextField("Reference", text: $reference)
                Picker("For", selection: $owner) {
                    Text("Choose…").tag(OwnerRef?.none)
                    ForEach(owners, id: \.0) { Text($0.1).tag(OwnerRef?.some($0.0)) }
                }
            }
            .navigationTitle("New Job")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(owner == nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { focusSoon { nameFocused = true } }
        }
    }

    private func add() {
        guard let owner else { return }
        model.addJob(id: id, name: name, reference: reference,
                     ownerType: owner.type, ownerID: owner.guid)
        dismiss()
    }
}

// MARK: - Billing terms

struct BillingTermsSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var kind: BillTerm.Kind = .days
    @State private var dueDays = "30"
    @FocusState private var nameFocused: Bool

    private func int(_ s: String) -> Int { Int(s.trimmingCharacters(in: .whitespaces)) ?? 0 }

    var body: some View {
        NavigationStack {
            Form {
                if !model.businessTerms.isEmpty {
                    Section("Existing") {
                        ForEach(model.businessTerms) { term in
                            HStack {
                                Text(term.name)
                                Spacer()
                                Text(term.kind == .days ? "Net \(term.dueDays)"
                                     : "Day \(term.dueDays) proximo")
                                    .scaledFont(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("New term") {
                    TextField("Name (e.g. Net 30)", text: $name).focused($nameFocused)
                    Picker("Due", selection: $kind) {
                        Text("Days after posting").tag(BillTerm.Kind.days)
                        Text("Proximo (day of next month)").tag(BillTerm.Kind.proximo)
                    }
                    TextField(kind == .days ? "Days" : "Day of month", text: $dueDays)
                }
            }
            .navigationTitle("Billing Terms")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || int(dueDays) <= 0)
                }
            }
            .onAppear { focusSoon { nameFocused = true } }
        }
    }

    private func add() {
        model.addBillTerm(name: name, kind: kind, dueDays: int(dueDays))
        name = ""; dueDays = kind == .days ? "30" : "1"
    }
}

// MARK: - Tax tables

struct TaxTablesSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var accountID: GncGUID?
    @State private var percentage = "10"
    @FocusState private var nameFocused: Bool

    private func dec(_ s: String) -> Decimal { Decimal(string: s.trimmingCharacters(in: .whitespaces)) ?? 0 }
    /// Tax collected is a liability (GST payable) or, for purchases, an asset.
    private var taxAccounts: [Account] {
        (model.book?.accounts ?? []).filter {
            !$0.isPlaceholder && ($0.type == .liability || $0.type == .asset || $0.type == .expense)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if !model.businessTaxTables.isEmpty {
                    Section("Existing") {
                        ForEach(model.businessTaxTables) { table in
                            HStack {
                                Text(table.name)
                                Spacer()
                                Text("\(table.totalPercentage.formatted())%")
                                    .scaledFont(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("New tax table") {
                    TextField("Name (e.g. GST)", text: $name).focused($nameFocused)
                    LabeledContent("Tax account") {
                        AccountField(nodes: nodes(of: taxAccounts, in: model), selection: $accountID)
                    }
                    TextField("Percentage", text: $percentage)
                }
            }
            .navigationTitle("Tax Tables")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                                  || accountID == nil || dec(percentage) <= 0)
                }
            }
            .onAppear { focusSoon { nameFocused = true } }
        }
    }

    private func add() {
        guard let accountID else { return }
        model.addTaxTable(name: name, accountID: accountID, percentage: dec(percentage))
        name = ""
    }
}

// MARK: - Company information

struct CompanyInfoSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var info = CompanyInfo()
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Company") {
                    TextField("Company name", text: $info.name).focused($nameFocused)
                    TextField("Contact person", text: $info.contact)
                    TextField("Tax ID / ABN", text: $info.taxID)
                }
                Section("Address") {
                    TextField("Address line 1", text: $info.addressLine1)
                    TextField("Address line 2", text: $info.addressLine2)
                }
                Section("Contact") {
                    TextField("Phone", text: $info.phone)
                    TextField("Email", text: $info.email)
                    TextField("Website", text: $info.website)
                }
            }
            .navigationTitle("Company Information")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.updateCompanyInfo(info)
                        dismiss()
                    }
                }
            }
            .onAppear {
                info = model.companyInfo
                focusSoon { nameFocused = true }
            }
        }
    }
}
