//
//  ReportsHome.swift
//  FinvestLens — FeatureUI
//
//  The reports surface, redesigned (docs/reports.md).
//
//  Reports live in the main window's detail pane, like the dashboard — not a
//  detached window. Entering shows a *gallery* (favourites, then the catalogue
//  grouped), and nothing is computed until a report is chosen: on a 46k-
//  transaction book, work the user didn't ask for is seconds of spinner before
//  they have even said what they want. A chosen report computes in a task when
//  its parameters settle — never in `body` — and renders as a document.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import FinvestLensEngine
import FinvestLensReports

// MARK: - Catalogue

/// Every report the app can produce, with the metadata the gallery and the
/// parameter bar need.
public enum ReportKind: String, CaseIterable, Identifiable, Codable {
    case balanceSheet = "Balance Sheet"
    case incomeStatement = "Income Statement"
    case equityStatement = "Equity Statement"
    case trialBalance = "Trial Balance"
    case accountSummary = "Account Summary"
    case netWorth = "Net Worth"
    case cashFlow = "Cash Flow"
    case incomeExpense = "Income & Expense"
    case averageBalance = "Average Balance"
    case transactions = "Transactions"
    case reconcile = "Reconciliation"
    case forecast = "Forecast"
    case portfolio = "Portfolio"
    case investmentLots = "Investment Lots"
    case priceScatter = "Price Scatter"
    case capitalGains = "Capital Gains"
    case receivableAging = "Receivable Aging"
    case payableAging = "Payable Aging"
    case customerSummary = "Customer Summary"
    case vendorSummary = "Vendor Summary"
    case employeeSummary = "Employee Summary"
    case jobSummary = "Job Summary"

    public var id: String { rawValue }

    enum Group: String, CaseIterable {
        case statements = "Statements"
        case activity = "Activity"
        case investments = "Investments"
        case business = "Business"
    }

    var group: Group {
        switch self {
        case .balanceSheet, .incomeStatement, .equityStatement, .trialBalance,
             .accountSummary, .netWorth, .cashFlow, .incomeExpense:
            .statements
        case .averageBalance, .transactions, .reconcile, .forecast:
            .activity
        case .portfolio, .investmentLots, .priceScatter, .capitalGains:
            .investments
        case .receivableAging, .payableAging, .customerSummary,
             .vendorSummary, .employeeSummary, .jobSummary:
            .business
        }
    }

    /// The kinds rendered as documents through ``ReportDocumentView``. The
    /// rest keep their existing interactive views inside the new navigation.
    var usesScaffold: Bool {
        group == .statements || self == .averageBalance || group == .business
    }

    /// Point-in-time reports read the period's *end* as their as-of date, so
    /// one period selector serves both shapes.
    var isAsOf: Bool {
        switch self {
        case .balanceSheet, .trialBalance, .accountSummary, .receivableAging,
             .payableAging, .customerSummary, .vendorSummary, .employeeSummary,
             .jobSummary: true
        default: false
        }
    }

    var usesDepth: Bool { self == .accountSummary }
    var usesAccounts: Bool { self == .cashFlow || self == .averageBalance }
    /// Whether the report takes an interval size (the average-balance report).
    var usesStep: Bool { self == .averageBalance }
    /// Whether the report can show prior periods as comparison columns.
    /// The statement kinds carry their own prior-year comparative column
    /// (report-redesign §3.1 rule 7), so the stepper is gone for them.
    var usesCompare: Bool { false }

    var icon: String {
        switch self {
        case .balanceSheet: "scalemass"
        case .incomeStatement: "arrow.left.arrow.right"
        case .equityStatement: "building.columns"
        case .trialBalance: "checkmark.seal"
        case .accountSummary: "list.bullet.indent"
        case .netWorth: "chart.line.uptrend.xyaxis"
        case .cashFlow: "arrow.triangle.branch"
        case .incomeExpense: "chart.bar"
        case .averageBalance: "chart.bar.xaxis"
        case .transactions: "list.bullet.rectangle"
        case .reconcile: "checkmark.circle"
        case .forecast: "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .portfolio: "chart.pie"
        case .investmentLots: "shippingbox"
        case .priceScatter: "chart.dots.scatter"
        case .capitalGains: "percent"
        case .receivableAging: "person.crop.circle.badge.clock"
        case .payableAging: "building.2.crop.circle.badge.clock"
        case .customerSummary: "person.2.badge.gearshape"
        case .vendorSummary: "building.2"
        case .employeeSummary: "person.text.rectangle"
        case .jobSummary: "briefcase"
        }
    }

    var blurb: String {
        switch self {
        case .balanceSheet: "Where you stand: assets, liabilities, equity"
        case .incomeStatement: "What the period earned and spent"
        case .equityStatement: "How your capital moved, and why"
        case .trialBalance: "Every balance, and proof the books balance"
        case .accountSummary: "The whole chart of accounts, to a depth"
        case .netWorth: "Net worth over time"
        case .cashFlow: "Where the money came from and went"
        case .incomeExpense: "Spending and income by category and month"
        case .averageBalance: "Average balance over time, by interval"
        case .transactions: "An account's postings over a period"
        case .reconcile: "Reconciled, cleared, and outstanding"
        case .forecast: "Projected balances from scheduled transactions"
        case .portfolio: "Holdings, allocation, and value"
        case .investmentLots: "Purchase lots and cost basis"
        case .priceScatter: "Price history for a security"
        case .capitalGains: "Realised gains by disposal"
        case .receivableAging: "What customers owe, by how overdue"
        case .payableAging: "What you owe vendors, by how overdue"
        case .customerSummary: "Sales and receivables by customer"
        case .vendorSummary: "Bills and payables by vendor"
        case .employeeSummary: "Expense vouchers and payables by employee"
        case .jobSummary: "Charges and outstanding by job"
        }
    }

    /// A fresh configuration for this kind, under the book's defaults.
    @MainActor
    func defaultConfiguration(for model: AppModel) -> ReportConfiguration {
        ReportConfiguration(kind: rawValue,
                            period: model.defaultReportPeriod,
                            accountIDs: nil,
                            depth: usesDepth ? 2 : nil,
                            step: usesStep ? .month : nil)
    }
}

// MARK: - Home

/// The last few reports opened — "my" reports without the ceremony of
/// favouriting (F12). Desk state: UserDefaults, never the book.
enum ReportRecents {
    static let key = "reports.recents"
    static let limit = 5

    static func record(_ kind: ReportKind) {
        var kinds = load().filter { $0 != kind }
        kinds.insert(kind, at: 0)
        UserDefaults.standard.set(kinds.prefix(limit).map(\.rawValue).joined(separator: "|"),
                                  forKey: key)
    }

    static func load() -> [ReportKind] {
        (UserDefaults.standard.string(forKey: key) ?? "")
            .split(separator: "|")
            .compactMap { ReportKind(rawValue: String($0)) }
    }
}

/// The reports destination: the gallery, or the report that is open.
struct ReportsHome: View {
    @Bindable var model: AppModel
    @State private var openConfiguration: ReportConfiguration? {
        didSet {
            if let raw = openConfiguration?.kind, let kind = ReportKind(rawValue: raw) {
                ReportRecents.record(kind)
            }
        }
    }

    var body: some View {
        Group {
            if let configuration = openConfiguration {
                ReportScreen(model: model, configuration: configuration) {
                    openConfiguration = nil
                }
            } else {
                ReportGallery(model: model) { configuration in
                    openConfiguration = configuration
                }
            }
        }
        .onAppear {
            // A menu item may ask to jump straight to one report.
            if let kind = model.pendingReportKind {
                model.pendingReportKind = nil
                openConfiguration = kind.defaultConfiguration(for: model)
            }
        }
    }
}

/// Favourites, then the catalogue. Choosing computes nothing by itself — the
/// report screen does, once parameters settle.
struct ReportGallery: View {
    @Bindable var model: AppModel
    let open: (ReportConfiguration) -> Void
    @State private var settingsShown = false
    @State private var packShown = false
    @State private var reviewShown = false

    private let columns = [GridItem(.adaptive(minimum: 210), spacing: 12)]

    /// Reads through @AppStorage so a new recent re-renders the row.
    @AppStorage(ReportRecents.key) private var recentsRaw = ""
    private var recents: [ReportKind] {
        recentsRaw.split(separator: "|").compactMap { ReportKind(rawValue: String($0)) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !recents.isEmpty {
                    Text("Recent").scaledFont(.title2).fontWeight(.semibold)
                    HStack(spacing: 8) {
                        ForEach(recents) { kind in
                            Button {
                                open(kind.defaultConfiguration(for: model))
                            } label: {
                                Label(kind.rawValue, systemImage: kind.icon)
                                    .scaledFont(.callout)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(.quaternary.opacity(0.5), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                    }
                }
                if !model.savedReports.isEmpty {
                    Text("Favourites").scaledFont(.title2).fontWeight(.semibold)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(model.savedReports) { saved in
                            favouriteCard(saved)
                        }
                    }
                }
                Text("Present").scaledFont(.title2).fontWeight(.semibold)
                Button {
                    reviewShown = true
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Financial Review", systemImage: "play.rectangle.fill")
                            .scaledFont(.headline)
                        Text("The period as a results deck — one message per slide, charts, callouts, on-device insights")
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: 440, alignment: .leading)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                Text("Tax Time").scaledFont(.title2).fontWeight(.semibold)
                Button {
                    packShown = true
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Financial Year Pack", systemImage: "doc.on.doc.fill")
                            .scaledFont(.headline)
                        Text("P&L, balance sheet, capital gains, dividends & franking — one PDF")
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: 440, alignment: .leading)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                ForEach(ReportKind.Group.allCases, id: \.self) { group in
                    Text(group.rawValue).scaledFont(.title2).fontWeight(.semibold)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(ReportKind.allCases.filter { $0.group == group }) { kind in
                            catalogueCard(kind)
                        }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Reports")
        .sheet(isPresented: $packShown) { FinancialYearPackSheet(model: model) }
        .sheet(isPresented: $reviewShown) { FinancialReviewSheet(model: model) }
        .onAppear {
            if model.financialYearPackRequested {
                model.financialYearPackRequested = false
                packShown = true
            }
            if model.financialReviewRequested {
                model.financialReviewRequested = false
                reviewShown = true
            }
        }
        .onChange(of: model.financialYearPackRequested) {
            if model.financialYearPackRequested {
                model.financialYearPackRequested = false
                packShown = true
            }
        }
        .onChange(of: model.financialReviewRequested) {
            if model.financialReviewRequested {
                model.financialReviewRequested = false
                reviewShown = true
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Report Settings", systemImage: "gearshape") { settingsShown = true }
                    .help("Financial year and default period")
                    .popover(isPresented: $settingsShown) {
                        ReportSettingsPopover(model: model)
                    }
            }
        }
    }

    private func favouriteCard(_ saved: SavedReport) -> some View {
        Button {
            open(saved.configuration)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label(saved.name, systemImage: "bookmark.fill")
                    .scaledFont(.headline)
                    .lineLimit(1)
                Text("\(saved.configuration.kind) · \(model.label(for: saved.configuration.period))")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete Favourite", role: .destructive) {
                model.deleteReportFavourite(saved.id)
            }
        }
    }

    private func catalogueCard(_ kind: ReportKind) -> some View {
        Button {
            open(kind.defaultConfiguration(for: model))
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label(kind.rawValue, systemImage: kind.icon)
                    .scaledFont(.headline)
                    .lineLimit(1)
                Text(kind.blurb)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

/// Book-scoped report preferences, edited where they are used.
struct ReportSettingsPopover: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Picker("Financial year starts", selection: Binding(
                get: { model.financialYearStartMonth },
                set: { month in
                    var settings = model.reportSettings
                    settings.financialYearStartMonth = month
                    model.updateReportSettings(settings)
                })) {
                ForEach(1...12, id: \.self) { month in
                    Text(Calendar.current.monthSymbols[month - 1]).tag(month)
                }
            }
            Picker("Default period", selection: Binding(
                get: { model.defaultReportPeriod },
                set: { period in
                    var settings = model.reportSettings
                    settings.defaultPeriod = period
                    model.updateReportSettings(settings)
                })) {
                ForEach(ReportPeriod.named, id: \.self) { period in
                    Text(period.name).tag(period)
                }
            }
            Text("Stored in this book, so its financial-year convention travels with it.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(minWidth: 340)
    }
}

// MARK: - Period selector

/// The timescale, as a menu of named periods with their resolved labels, plus
/// a custom range.
struct PeriodSelector: View {
    @Bindable var model: AppModel
    @Binding var period: ReportPeriod
    @State private var customShown = false
    @State private var customFrom = Date()
    @State private var customTo = Date()

    var body: some View {
        Menu {
            ForEach(ReportPeriod.named, id: \.self) { candidate in
                Button {
                    period = candidate
                } label: {
                    if candidate == period {
                        Label(menuLabel(candidate), systemImage: "checkmark")
                    } else {
                        Text(menuLabel(candidate))
                    }
                }
            }
            Divider()
            Button("Custom Range…") {
                let resolved = model.resolve(period)
                customFrom = resolved.from == .distantPast ? Date() : resolved.from
                customTo = resolved.to
                customShown = true
            }
        } label: {
            Label(model.label(for: period), systemImage: "calendar")
        }
        .fixedSize()
        .popover(isPresented: $customShown) {
            Form {
                DatePicker("From", selection: $customFrom, displayedComponents: .date)
                DatePicker("To", selection: $customTo, displayedComponents: .date)
                Button("Apply") {
                    period = .custom(from: customFrom, to: customTo)
                    customShown = false
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            .frame(minWidth: 300)
        }
    }

    /// "Last financial year — FY 2025–26": the rule and what it means today.
    private func menuLabel(_ candidate: ReportPeriod) -> String {
        "\(candidate.name) — \(model.label(for: candidate))"
    }
}

// MARK: - Report screen

/// One report: parameter bar, then the computed document (or the interactive
/// view, for the kinds that keep one).
struct ReportScreen: View {
    @Bindable var model: AppModel
    @State var configuration: ReportConfiguration
    let close: () -> Void

    @State private var document: ReportDocument?
    @State private var statement: Statement?
    @State private var savePromptShown = false
    @State private var savingName = ""
    @State private var exporting = false
    @State private var pdfDocument: PDFReportDocument?

    private var kind: ReportKind? { ReportKind(rawValue: configuration.kind) }

    /// The kinds that render as annual-report statements (report-redesign
    /// §3.2) rather than the generic document scaffold.
    private var isStatementKind: Bool {
        kind == .balanceSheet || kind == .incomeStatement || kind == .equityStatement
    }

    var body: some View {
        VStack(spacing: 0) {
            parameterBar
            Divider()
            content
        }
        .navigationTitle(configuration.kind)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("All Reports", systemImage: "chevron.backward", action: close)
                    .help("Back to the report gallery")
            }
            ToolbarItemGroup {
                Button("Save as Favourite", systemImage: "bookmark") {
                    savingName = configuration.kind
                    savePromptShown = true
                }
                .help("Save this report and its settings as a favourite")
                if document != nil || statement != nil {
                    Button("PDF", systemImage: "arrow.up.doc") { exportPDF() }
                        .help("Export this report as a PDF")
                }
            }
        }
        .alert("Save Report", isPresented: $savePromptShown) {
            TextField("Name", text: $savingName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                model.saveReportFavourite(configuration, named: savingName)
            }
        } message: {
            Text("Saving with an existing name replaces that favourite.")
        }
        .fileExporter(isPresented: $exporting, document: pdfDocument,
                      contentType: .pdf, defaultFilename: configuration.kind) { _ in }
    }

    @ViewBuilder
    private var parameterBar: some View {
        HStack(spacing: 12) {
            if kind?.usesScaffold == true {
                PeriodSelector(model: model, period: $configuration.period)
            }
            if kind?.usesDepth == true {
                Stepper("Depth: \(configuration.depth ?? 2)", value: Binding(
                    get: { configuration.depth ?? 2 },
                    set: { configuration.depth = $0 }), in: 1...6)
                    .fixedSize()
            }
            if kind?.usesAccounts == true {
                AccountScopeButton(model: model, accountIDs: $configuration.accountIDs)
            }
            if kind?.usesStep == true {
                Picker("Interval", selection: Binding(
                    get: { configuration.step ?? .month },
                    set: { configuration.step = $0 })) {
                    ForEach(AverageBalanceStep.allCases) { step in
                        Text(step.displayName).tag(step)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            if kind?.usesCompare == true, configuration.period.comparisonStride != nil {
                Stepper("Compare: \(configuration.comparePeriods ?? 0)", value: Binding(
                    get: { configuration.comparePeriods ?? 0 },
                    set: { configuration.comparePeriods = $0 }), in: 0...4)
                    .fixedSize()
            }
            Spacer()
        }
        .scaledFont(.body)
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        if isStatementKind {
            if let statement {
                StatementView(statement: statement)
                    .task(id: configuration) { await recomputeStatement() }
            } else {
                ProgressView("Preparing \(configuration.kind)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task(id: configuration) { await recomputeStatement() }
            }
        } else if let kind, kind.usesScaffold {
            if let document {
                ReportDocumentView(model: model, document: document)
                    // Recompute when parameters change — and only then. The
                    // computation never runs in `body`.
                    .task(id: configuration) { await recompute() }
            } else {
                ProgressView("Preparing \(configuration.kind)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task(id: configuration) { await recompute() }
            }
        } else {
            legacyContent
        }
    }

    /// The kinds that keep their interactive views, hosted inside the new
    /// navigation. Their internals migrate to the document scaffold later.
    @ViewBuilder
    private var legacyContent: some View {
        switch kind {
        case .transactions: TransactionReportView(model: model)
        case .reconcile: ReconcileReportView(model: model)
        case .forecast: CashFlowView(model: model)
        case .portfolio: PortfolioView(model: model)
        case .investmentLots: InvestmentLotsView(model: model)
        case .priceScatter: PriceScatterView(model: model)
        case .capitalGains: CapitalGainsView(model: model)
        default:
            ContentUnavailableView("Unknown report", systemImage: "questionmark",
                                   description: Text("This favourite was saved by a newer version."))
        }
    }

    private func recompute() async {
        // One yield so the spinner paints before the (fast, but not free)
        // computation runs.
        await Task.yield()
        document = model.reportDocument(for: configuration)
    }

    private func recomputeStatement() async {
        await Task.yield()
        let (from, to) = model.resolve(configuration.period)
        let label = model.label(for: configuration.period)
        switch kind {
        case .balanceSheet:
            statement = model.financialPositionStatement(asOf: to)
        case .incomeStatement:
            statement = model.incomeStatementStatement(from: from, to: to, periodLabel: label)
        case .equityStatement:
            statement = model.changesInNetWorthStatement(from: from, to: to, periodLabel: label)
        default:
            statement = nil
        }
    }

    private func exportPDF() {
        let data: Data?
        if let statement {
            data = ReportExport.pdf(StatementSheet(statement: statement))
        } else if let document {
            data = ReportExport.pdf(document.printable)
        } else {
            data = nil
        }
        guard let data else { return }
        pdfDocument = PDFReportDocument(data: data)
        exporting = true
    }
}

/// The account scope for reports that take one, behind a button naming the
/// choice — the same tree-with-filter picker Find uses.
struct AccountScopeButton: View {
    @Bindable var model: AppModel
    @Binding var accountIDs: Set<GncGUID>?
    @State private var pickerShown = false

    var body: some View {
        Button(label) { pickerShown = true }
            .popover(isPresented: $pickerShown) {
                AccountMatchPicker(tree: model.accountTree, selection: Binding(
                    get: { accountIDs ?? model.defaultCashFlowAccountIDs },
                    set: { accountIDs = $0 }))
            }
    }

    private var label: String {
        guard let ids = accountIDs else { return "Bank & cash accounts" }
        switch ids.count {
        case 0: return "Choose accounts…"
        case 1: return model.accountName(ids.first!) ?? "1 account"
        default: return "\(ids.count) accounts"
        }
    }
}

// MARK: - Financial Year Pack (6.6b)

import PDFKit

/// The EOFY bundle: pick the financial year, see what the pack will hold,
/// export one PDF — P&L, Balance Sheet, Capital Gains, Dividends & Franking.
struct FinancialYearPackSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var yearIndex = 0
    @State private var pages: [AppModel.FinancialYearPackPage] = []
    @State private var building = false
    @State private var exporting = false
    @State private var exportDocument: PDFReportDocument?

    private var years: [(label: String, from: Date, to: Date)] { model.packFinancialYears() }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Financial year", selection: $yearIndex) {
                    ForEach(Array(years.enumerated()), id: \.offset) { index, year in
                        Text(year.label).tag(index)
                    }
                }
                Section("In this pack") {
                    if building {
                        ProgressView("Building reports…")
                    } else if pages.isEmpty {
                        Text("Nothing to report for this year.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(pages.indices, id: \.self) { index in
                            Label(pages[index].title, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.primary)
                        }
                    }
                }
                Section {
                    Text("One PDF, in reading order — the income statement, statement "
                         + "of financial position, changes in net worth, realised "
                         + "gains, and dividends with franking credits.")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Financial Year Pack")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export PDF…") { export() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(building || pages.isEmpty)
                }
            }
            .task(id: yearIndex) { await build() }
            .fileExporter(isPresented: $exporting, document: exportDocument,
                          contentType: .pdf,
                          defaultFilename: "\(years[min(yearIndex, years.count - 1)].label) Pack") { _ in }
        }
        .frame(minWidth: 440, minHeight: 380)
    }

    private func build() async {
        guard yearIndex < years.count else { return }
        building = true
        defer { building = false }
        await Task.yield()   // paint the spinner before the report builds
        let year = years[yearIndex]
        pages = model.financialYearPackPages(from: year.from, to: year.to,
                                             label: year.label)
    }

    /// Renders each page to PDF — statements through the annual-report
    /// sheet, tabular reports through their printable — and stitches them.
    private func export() {
        let merged = PDFDocument()
        for page in pages {
            let data: Data?
            switch page {
            case .statement(let statement):
                data = ReportExport.pdf(StatementSheet(statement: statement))
            case .document(let document):
                data = ReportExport.pdf(document.printable)
            }
            guard let data, let pdf = PDFDocument(data: data) else { continue }
            for pageIndex in 0..<pdf.pageCount {
                if let page = pdf.page(at: pageIndex) {
                    merged.insert(page, at: merged.pageCount)
                }
            }
        }
        guard merged.pageCount > 0, let data = merged.dataRepresentation() else { return }
        exportDocument = PDFReportDocument(data: data)
        exporting = true
    }
}
