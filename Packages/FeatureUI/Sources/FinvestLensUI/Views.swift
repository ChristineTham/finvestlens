//
//  Views.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import TipKit
import UniformTypeIdentifiers
import FinvestLensEngine
import FinvestLensIntelligence
import FinvestLensPersistence
#if os(macOS)
import AppKit

/// Direct NSOpenPanel wrapper for macOS. SwiftUI's `.fileImporter` does not
/// reliably present in this app's window setup (menu-triggered bindings are
/// dropped), so macOS uses the same AppKit-panel pattern as DocumentDialogs;
/// iOS keeps `.fileImporter`.
@MainActor
enum MacFilePanel {
    static func open(types: [UTType], title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = title
        panel.allowedContentTypes = types
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func openMultiple(types: [UTType], title: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = title
        panel.allowedContentTypes = types
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func chooseDirectory(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
#endif

extension View {
    /// A checkbox toggle style on macOS; the platform default (a switch) on iOS,
    /// where `.checkbox` is unavailable.
    @ViewBuilder func checkboxToggleStyle() -> some View {
        #if os(macOS)
        toggleStyle(.checkbox)
        #else
        self
        #endif
    }
}

/// A GnuCash XML file for `.fileExporter` (export only).
struct GnuCashFileDocument: FileDocument {
    static let contentType = UTType(filenameExtension: "gnucash") ?? .xml
    static var readableContentTypes: [UTType] { [contentType, .xml] }

    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// A UTF-8 CSV file for `.fileExporter` (`FR-XIO-06`, export only).
struct CSVFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }

    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

// MARK: - Embedded destinations

extension EnvironmentValues {
    /// True when a view that was designed as a modal sheet is instead shown
    /// inline as a sidebar destination — it should then hide its Done/Cancel
    /// dismissal chrome and drop its sheet-sizing frame.
    @Entry public var isEmbeddedDestination: Bool = false
}

// MARK: - Formatting

enum AmountFormat {
    static func string(_ value: Decimal, code: String) -> String {
        value.formatted(.currency(code: code))
    }

    /// A VoiceOver-friendly reading of a signed money value: the magnitude in
    /// words plus "debit"/"credit", so a dense numeric cell isn't read as a
    /// bare stream of digits with an ambiguous minus sign.
    static func spoken(_ value: Decimal, code: String) -> String {
        let money = abs(value).formatted(.currency(code: code))
        if value == 0 { return money }
        return "\(money), \(value < 0 ? "debit" : "credit")"
    }
}

/// Applies keyboard focus a beat after a sheet finishes presenting, so very
/// fast input (or automation) can't precede the field gaining focus.
@MainActor
func focusSoon(_ apply: @escaping @MainActor () -> Void) {
    Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(120))
        apply()
    }
}

public extension AppModel {
    /// Flattened, non-placeholder accounts usable as transfer endpoints.
    var postableAccounts: [AccountNode] {
        func flatten(_ nodes: [AccountNode]) -> [AccountNode] {
            nodes.flatMap { [$0] + flatten($0.children ?? []) }
        }
        return flatten(accountTree).filter { !$0.isPlaceholder }
    }
}

// MARK: - Lock screen

/// Gates a locked book behind device authentication (`NFR-07`).
public struct LockView: View {
    @Bindable var model: AppModel
    @State private var failed = false
    @Environment(\.appFontScale) private var appFontScale
    private var iconSize: CGFloat { 48 * appFontScale }

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill").font(.system(size: iconSize)).foregroundStyle(.tint)
            Text("This book is locked").scaledFont(.title2, weight: .bold)
            Text("Authenticate to view your accounts.").foregroundStyle(.secondary)
            Button {
                Task { failed = !(await model.unlock()) }
            } label: {
                Label("Unlock", systemImage: "touchid").frame(minWidth: 160)
            }
            .buttonStyle(.borderedProminent)
            if failed {
                Text("Authentication failed. Try again.").scaledFont(.caption).foregroundStyle(.red)
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await model.unlock() }   // prompt immediately on appear
    }
}

/// Shown while a book is being read. The read runs off the main actor, so this
/// view actually animates — the point of it is that a large book no longer looks
/// like a click that did nothing.
///
/// The bar is determinate once the loader has sized the book, and indeterminate
/// until then: the first report cannot arrive before the row counts are in, and
/// a bar sitting at zero says "stuck" where a spinner says "working".
public struct OpeningBookView: View {
    let url: URL
    let progress: BookLoadProgress?
    @Environment(\.appFontScale) private var appFontScale

    public init(url: URL, progress: BookLoadProgress? = nil) {
        self.url = url
        self.progress = progress
    }

    private var bookName: String { url.deletingPathExtension().lastPathComponent }

    /// "Reading transactions… 12,000 of 46,553" — the count is what makes the
    /// wait legible: it says the book is big, not that the app is hung.
    private var detail: String {
        guard let progress else { return "Reading accounts, transactions and prices." }
        guard progress.total > 0 else { return progress.stage.label + "…" }
        return "\(progress.stage.label)… \(progress.completed.formatted(.number)) of \(progress.total.formatted(.number))"
    }

    public var body: some View {
        VStack(spacing: 16) {
            if let progress {
                ProgressView(value: progress.fraction, total: 1)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 320)
                    // No implicit animation. SwiftUI would ease the fill toward
                    // each new value over ~0.25s, and the main actor goes busy
                    // the instant the read ends — so the last ease never
                    // finishes and the bar strands part-way (measured: it sat at
                    // 93% under "102,706 of 102,706"). Painting the reported
                    // number is both honest and what actually shows up.
                    .animation(nil, value: progress.fraction)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: 320)
            }
            Text("Opening \(bookName)…")
                .scaledFont(.title3, weight: .semibold)
            Text(detail)
                .foregroundStyle(.secondary)
                .scaledFont(.callout)
                .monospacedDigit()
                .animation(nil, value: detail)   // the digits update, not slide
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Opening \(bookName)")
        .accessibilityValue(progress.map { "\(Int($0.fraction * 100)) percent" } ?? "")
    }
}

// MARK: - Root

/// The main document view: accounts sidebar + register (or search results).
/// Tool panels are routed through ``AppModel/presentedPanel`` so the menu bar
/// and toolbar share one entry point per panel.
public struct FinvestLensRootView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var showingExport = false
    @State private var exportDocument: GnuCashFileDocument?
    @State private var showingCSVExport = false
    @State private var csvDocument: CSVFileDocument?
    @State private var csvFilename = "Export"
    @State private var importPayload: ImportPayload?
    @State private var offeredOnboarding = false
    @State private var smartPayload: SmartImportPayload?
    @State private var statementProgress: (done: Int, total: Int)?
    @State private var statementError: String?

    public init(model: AppModel) {
        self.model = model
    }

    /// The detail pane: search results, or the selected sidebar destination.
    /// Areas that used to be modal sheets are shown inline here (HIG).
    @ViewBuilder
    private var detailPane: some View {
        if model.isSearching {
            SearchResultsView(model: model)
        } else {
            destinationView
                // Areas that were modal sheets suppress their Done/sheet chrome
                // via this flag when shown inline.
                .environment(\.isEmbeddedDestination, true)
        }
    }

    @ViewBuilder
    private var destinationView: some View {
        switch model.sidebarSelection ?? .dashboard {
        case .dashboard: DashboardView(model: model)
        case .account: RegisterView(model: model)
        case .reports: ReportsHome(model: model)
        case .budgets: BudgetView(model: model)
        case .scheduled: ScheduledView(model: model)
        case .rules: RulesView(model: model)
        case .goals: GoalsView(model: model)
        case .prices: PricesView(model: model)
        case .business: BusinessHub(model: model)
        case .timeMileage: TimeMileageView(model: model)
        }
    }

    public var body: some View {
        NavigationSplitView {
            AccountsSidebar(model: model)
                .navigationTitle("Accounts")
        } detail: {
            detailPane
        }
        .searchable(text: $model.searchQuery, prompt: "Search transactions")
        .safeAreaInset(edge: .top) {
            if model.externalChangePending {
                ExternalChangeBanner(model: model)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Dashboard", systemImage: "house") {
                    model.selectedAccountID = nil
                    model.isShowingReports = false
                }
                .help("Show the dashboard (⌘D)")
                Button("New Transaction", systemImage: "plus.circle") {
                    model.presentedPanel = .newTransaction
                }
                .help("New transaction (⌘T)")
                .disabled(model.postableAccounts.count < 2)
                Button("New Account", systemImage: "plus.rectangle.on.folder") {
                    model.presentedPanel = .newAccount
                }
                .help("New account (⇧⌘N)")
                Button("Reports", systemImage: "chart.pie") {
                    #if os(macOS)
                    openWindow(id: "reports")
                    #else
                    model.show(.reports)
                    #endif
                }
                .help("Reports (⌘R)")
            }
            ToolbarSpacer(.fixed)
            ToolbarItemGroup {
                Menu {
                    Button("Import Bank File…", systemImage: "square.and.arrow.down.on.square") {
                        model.bankImportRequested = true
                    }
                    Button("Reconcile Account…", systemImage: "checkmark.seal") {
                        model.presentedPanel = .reconcile
                    }
                    .disabled(model.selectedAccountID == nil)
                    Divider()
                    Button("Stock Transaction…", systemImage: "chart.line.uptrend.xyaxis") {
                        model.presentedPanel = .stockTransaction
                    }
                    .disabled(model.securityAccountNodes.isEmpty)
                    Button("Currency Transfer…", systemImage: "dollarsign.arrow.circlepath") {
                        model.presentedPanel = .currencyTransfer
                    }
                    .disabled(model.currencyCommodities.count < 2)
                    Divider()
                    Button("Rules…", systemImage: "wand.and.stars") {
                        model.show(.rules)
                    }
                    Button("Scheduled…", systemImage: "calendar.badge.clock") {
                        model.show(.scheduled)
                    }
                    Button("Budget…", systemImage: "chart.bar.doc.horizontal") {
                        model.show(.budgets)
                    }
                    Button("Prices & Quotes…", systemImage: "tag") {
                        model.show(.prices)
                    }
                    Divider()
                    // Apple Intelligence (on-device model) features.
                    Button("Smart Import PDFs…", systemImage: "doc.viewfinder") {
                        model.smartImportRequested = true
                    }
                    .disabled(!model.isIntelligenceAvailable)
                    .help(model.intelligenceUnavailableReason
                          ?? "Import bank statements, dividend statements, and invoices — each PDF is identified and handled automatically")
                    Button("Auto-Categorise…", systemImage: "sparkles") {
                        model.presentedPanel = .autoCategorize
                    }
                    .help("Assign categories to uncategorised transactions")
                } label: {
                    Label("Tools", systemImage: "wrench.and.screwdriver")
                }
                .help("Rules, scheduled, budget, prices and more")
                Menu {
                    if model.savedSearches.isEmpty {
                        Text("No saved searches")
                    } else {
                        ForEach(model.savedSearches) { search in
                            Menu(search.name) {
                                Button("Apply") { model.applySavedSearch(search.id) }
                                Button("Delete", role: .destructive) { model.deleteSavedSearch(search.id) }
                            }
                        }
                    }
                    Divider()
                    Button("Save Current Search…") { model.presentedPanel = .saveSearch }
                        .disabled(model.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty)
                } label: {
                    Label("Saved Searches", systemImage: "bookmark")
                }
                .help("Saved searches")
            }
        }
        .sheet(item: $model.presentedPanel) { panel in
            switch panel {
            case .newAccount: NewAccountSheet(model: model)
            case .newTransaction: TransactionEditorSheet(model: model)
            case .stockTransaction: StockTransactionSheet(model: model)
            case .currencyTransfer: CurrencyTransferSheet(model: model)
            case .saveSearch: SaveSearchSheet(model: model)
            case .onboarding: OnboardingSheet(model: model)
            case .reconcile:
                if let id = model.selectedAccountID {
                    ReconcileView(model: model, accountID: id)
                }
            case .autoCategorize: AutoCategorizeSheet(model: model)
            case .linkedDocuments: LinkedDocumentsView(model: model)
            case .loanCalculator: LoanCalculatorView(model: model)
            case .closeBook: CloseBookView(model: model)
            case .taxOptions: TaxOptionsView(model: model)
            case .find: FindSheet(model: model)
            case .findAccount: FindAccountSheet(model: model)
            }
        }
        #if os(macOS)
        // macOS: AppKit panels — .fileImporter does not present reliably here.
        .onChange(of: model.bankImportRequested) {
            guard model.bankImportRequested else { return }
            model.bankImportRequested = false
            // Deferred out of the view-update transaction: running a modal
            // panel inside it is silently dropped when triggered from a menu.
            Task { @MainActor in
                if let url = MacFilePanel.open(types: [.commaSeparatedText, .text, .pdf, .data],
                                               title: "Choose a bank file (CSV, QIF, OFX or PDF)") {
                    loadBankFile(url)
                }
            }
        }
        .onChange(of: model.smartImportRequested) {
            guard model.smartImportRequested else { return }
            model.smartImportRequested = false
            Task { @MainActor in
                let urls = MacFilePanel.openMultiple(
                    types: [.pdf],
                    title: "Choose statements, dividend statements, or invoices (PDF)")
                let files = urls.compactMap { url -> (String, Data)? in
                    guard let data = readScoped(url) else { return nil }
                    return (url.lastPathComponent, data)
                }
                if !files.isEmpty {
                    smartPayload = SmartImportPayload(files: files)
                }
            }
        }
        #else
        .fileImporter(isPresented: $model.bankImportRequested,
                      allowedContentTypes: [.commaSeparatedText, .text, .pdf, .data]) { result in
            if case .success(let url) = result { loadBankFile(url) }
        }
        // Anchored to a background view: two fileImporters on the same view
        // clobber each other's presentation.
        .background {
            Color.clear
                .fileImporter(isPresented: $model.smartImportRequested,
                              allowedContentTypes: [.pdf],
                              allowsMultipleSelection: true) { result in
                    if case .success(let urls) = result {
                        let files = urls.compactMap { url -> (String, Data)? in
                            guard let data = readScoped(url) else { return nil }
                            return (url.lastPathComponent, data)
                        }
                        if !files.isEmpty {
                            smartPayload = SmartImportPayload(files: files)
                        }
                    }
                }
        }
        #endif
        .sheet(item: $importPayload) { payload in
            ImportView(model: model, payload: payload)
        }
        .sheet(item: $smartPayload) { payload in
            SmartImportSheet(model: model, payload: payload)
        }
        .overlay {
            if let statementProgress {
                StatementProgressCard(done: statementProgress.done, total: statementProgress.total)
            }
        }
        .alert("Couldn’t read the statement", isPresented: Binding(
            get: { statementError != nil },
            set: { if !$0 { statementError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(statementError ?? "")
        }
        .onAppear(perform: offerOnboardingIfEmpty)
        .onChange(of: model.exportRequested) {
            guard model.exportRequested else { return }
            model.exportRequested = false
            if let data = model.gnuCashExportData() {
                exportDocument = GnuCashFileDocument(data: data)
                showingExport = true
            }
        }
        .fileExporter(isPresented: $showingExport, document: exportDocument,
                      contentType: GnuCashFileDocument.contentType, defaultFilename: "Book") { _ in
            exportDocument = nil
        }
        .onChange(of: model.csvExportRequest) {
            guard let kind = model.csvExportRequest else { return }
            model.csvExportRequest = nil
            let bookName = model.documentURL?.deletingPathExtension().lastPathComponent ?? "FinvestLens"
            csvFilename = kind.filename(book: bookName)
            csvDocument = CSVFileDocument(text: model.csvExport(kind))
            showingCSVExport = true
        }
        .fileExporter(isPresented: $showingCSVExport, document: csvDocument,
                      contentType: .commaSeparatedText, defaultFilename: csvFilename) { _ in
            csvDocument = nil
        }
        .sheet(isPresented: $model.showingHelp) { HelpView() }
        .sheet(item: $model.printCheckRequestTxnID) { txnID in
            CheckPrintSheet(model: model, txnID: txnID)
        }
        .fileImporter(isPresented: Binding(
            get: { model.attachDocumentRequestTxnID != nil },
            set: { if !$0 { model.attachDocumentRequestTxnID = nil } }
        ), allowedContentTypes: [.item]) { result in
            guard let txnID = model.attachDocumentRequestTxnID else { return }
            model.attachDocumentRequestTxnID = nil
            guard case let .success(url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                statementError = "Couldn't read “\(url.lastPathComponent)”."; return
            }
            do {
                _ = try model.attachDocument(named: url.lastPathComponent, data: data, to: txnID)
            } catch {
                statementError = "Couldn't attach the file: \(error.localizedDescription). Set a document folder in Settings ▸ Documents."
            }
        }
    }

    private func loadBankFile(_ url: URL) {
        guard let format = BankFileFormat.forExtension(url.pathExtension),
              let data = readScoped(url) else { return }
        if format == .pdf {
            extractStatement(data)
        } else {
            importPayload = ImportPayload(data: data, format: format)
        }
    }

    private func readScoped(_ url: URL) -> Data? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try? Data(contentsOf: url)
    }

    /// Reads a PDF statement with the on-device model (`FR-AI-01`), showing
    /// page progress, then hands the rows to the normal import review sheet.
    private func extractStatement(_ data: Data) {
        statementProgress = (0, 1)
        Task {
            do {
                let staged = try await model.extractStatementPDF(data) { done, total in
                    Task { @MainActor in statementProgress = (done, total) }
                }
                statementProgress = nil
                if staged.isEmpty {
                    statementError = "No transactions were found in this PDF."
                } else {
                    importPayload = ImportPayload(data: data, format: .pdf, prestaged: staged)
                }
            } catch {
                statementProgress = nil
                statementError = error.localizedDescription
            }
        }
    }

    /// Offers onboarding once per open document when it has no accounts yet.
    private func offerOnboardingIfEmpty() {
        guard !offeredOnboarding else { return }
        offeredOnboarding = true
        if model.isOpen && model.accountTree.isEmpty {
            model.presentedPanel = .onboarding
        }
    }
}

/// Progress card shown while Apple Intelligence reads a PDF statement.
private struct StatementProgressCard: View {
    let done: Int
    let total: Int

    var body: some View {
        VStack(spacing: 10) {
            ProgressView(value: Double(done), total: Double(max(1, total)))
                .frame(width: 200)
            Text("Reading statement… page \(min(done + 1, total)) of \(total)")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 8)
        .accessibilityLabel("Reading statement with Apple Intelligence")
    }
}

/// Banner shown when the shared file changed on another device. Offers a plain
/// reload, and — when the change produced NSFileVersion conflicts — explicit
/// "keep mine" / "use other" resolution (`FR-PLT-02`).
struct ExternalChangeBanner: View {
    @Bindable var model: AppModel

    var body: some View {
        let conflicted = model.hasVersionConflicts
        HStack(spacing: 12) {
            Image(systemName: conflicted
                  ? "exclamationmark.triangle.fill"
                  : "arrow.triangle.2.circlepath.icloud")
            Text(conflicted
                 ? "This book was edited in two places at once."
                 : "This book changed on another device.")
            Spacer()
            if conflicted {
                Button("Keep My Version") { model.resolveConflictsKeepingMine() }
                Button("Use Other Version") { model.resolveConflictsUsingOther() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Reload") { model.reloadFromDisk() }
                    .buttonStyle(.borderedProminent)
                Button("Dismiss") { model.externalChangePending = false }
            }
        }
        .padding(10)
        .background(.yellow.opacity(0.25))
    }
}

/// Offers a starter chart of accounts for a new, empty book (`FR-COA-03`,
/// `FR-PLAN-09`).
struct OnboardingSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appFontScale) private var appFontScale
    private var iconSize: CGFloat { 44 * appFontScale }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "sparkles")
                    .font(.system(size: iconSize)).foregroundStyle(.tint)
                Text("Welcome to your new book").scaledFont(.title2, weight: .bold)
                Text("Start with a ready-made personal chart of accounts — cheque, savings, credit card, income and common expense categories — or begin from scratch.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    model.createStarterAccounts()
                    dismiss()
                } label: {
                    Label("Create Starter Accounts", systemImage: "square.stack.3d.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button("Start Empty") { dismiss() }
            }
            .padding(32)
            .frame(minWidth: 420)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Skip") { dismiss() } }
            }
        }
    }
}

// MARK: - Accounts sidebar

/// Which modal a sidebar account row is presenting.
enum AccountSheet: Identifiable {
    case edit(GncGUID)
    case reconcile(GncGUID)
    case delete(GncGUID)
    case cascade(GncGUID)

    var id: String {
        switch self {
        case .edit(let guid): return "edit-\(guid.hexString)"
        case .reconcile(let guid): return "rec-\(guid.hexString)"
        case .delete(let guid): return "del-\(guid.hexString)"
        case .cascade(let guid): return "casc-\(guid.hexString)"
        }
    }
}

/// GnuCash's Cascade Account Properties: copy this account's colour,
/// placeholder and hidden flags down its subtree (`FR-ACC-02`).
struct CascadeAccountSheet: View {
    @Bindable var model: AppModel
    var accountID: GncGUID
    @Environment(\.dismiss) private var dismiss

    @State private var options = AppModel.CascadeOptions()

    private var name: String { model.accountName(accountID) ?? "this account" }
    private var count: Int { model.descendantCount(of: accountID) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Copy the properties you tick from “\(name)” onto "
                         + "\(DeleteAccountSheet.count(count, "account")) beneath it.")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Colour", isOn: $options.color)
                    Toggle("Placeholder", isOn: $options.isPlaceholder)
                    Toggle("Hidden", isOn: $options.isHidden)
                }
            }
            .navigationTitle("Cascade Properties")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        model.cascadeProperties(from: accountID, options)
                        dismiss()
                    }
                    // Nothing ticked would be a no-op dressed as an action.
                    .disabled(options.isEmpty || count == 0)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 260)
    }
}

/// GnuCash's Delete Account dialog: an account with postings or children can be
/// deleted, but has to say where they go first (`FR-ACC-04`).
struct DeleteAccountSheet: View {
    @Bindable var model: AppModel
    var accountID: GncGUID
    @Environment(\.dismiss) private var dismiss

    @State private var transactionTarget: GncGUID?
    @State private var childTarget: GncGUID?
    @State private var failure: String?

    private var plan: AppModel.AccountDeletionPlan? { model.deletionPlan(for: accountID) }
    private var name: String { model.accountName(accountID) ?? "this account" }

    /// "1 split" / "2,312 splits", grouped for reading.
    ///
    /// Spelled out rather than `^[\(n) split](inflect: true)`: automatic
    /// grammatical agreement resolves only for a localized string resource, and
    /// interpolating it into a `Text` renders the markup itself — this dialog
    /// said "^[2312 split](inflect: true) posted to “ANZ Access”".
    static func count(_ n: Int, _ noun: String) -> String {
        let formatted = NumberFormatter.localizedString(from: NSNumber(value: n),
                                                        number: .decimal)
        return "\(formatted) \(noun)\(n == 1 ? "" : "s")"
    }

    private var isReady: Bool {
        guard let plan else { return false }
        if plan.needsTransactionTarget && transactionTarget == nil { return false }
        if plan.needsChildTarget && childTarget == nil { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                if let plan {
                    if plan.isUnencumbered {
                        Text("“\(name)” is empty and can be deleted.")
                    }
                    if plan.needsTransactionTarget {
                        Section("Transactions") {
                            Text("\(Self.count(plan.splitCount, "split")) posted to “\(name)” "
                                 + "must move to another account.")
                                .scaledFont(.caption)
                                .foregroundStyle(.secondary)
                            Picker("Move to", selection: $transactionTarget) {
                                Text("Choose an account…").tag(GncGUID?.none)
                                ForEach(model.transactionTargets(forDeleting: accountID)) { node in
                                    Text(node.fullName).tag(GncGUID?.some(node.id))
                                }
                            }
                            .labelsHidden()
                        }
                    }
                    if plan.needsChildTarget {
                        Section("Subaccounts") {
                            Text(plan.descendantSplitCount > 0
                                 ? "\(Self.count(plan.childCount, "subaccount")) — carrying "
                                   + "\(Self.count(plan.descendantSplitCount, "split")) — must "
                                   + "move to another parent."
                                 : "\(Self.count(plan.childCount, "subaccount")) must move to "
                                   + "another parent.")
                                .scaledFont(.caption)
                                .foregroundStyle(.secondary)
                            Picker("Reparent to", selection: $childTarget) {
                                Text("Choose an account…").tag(GncGUID?.none)
                                ForEach(model.childTargets(forDeleting: accountID)) { node in
                                    Text(node.fullName).tag(GncGUID?.some(node.id))
                                }
                            }
                            .labelsHidden()
                        }
                    }
                    if let failure {
                        Text(failure).scaledFont(.caption).foregroundStyle(.red)
                    }
                } else {
                    Text("This account no longer exists.")
                }
            }
            .navigationTitle("Delete “\(name)”")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Delete", role: .destructive) { commit() }
                        .disabled(!isReady)
                }
            }
        }
        .frame(minWidth: 460, minHeight: 300)
    }

    private func commit() {
        do {
            try model.deleteAccount(accountID, movingTransactionsTo: transactionTarget,
                                    movingChildrenTo: childTarget)
            dismiss()
        } catch {
            failure = model.describe(error)
        }
    }
}

struct AccountsSidebar: View {
    @Bindable var model: AppModel
    @State private var sheet: AccountSheet?
    @State private var filter = ""
    /// GnuCash's "show hidden accounts". `isHidden` has been settable, stored
    /// and round-tripped all along, and the tree showed every account anyway —
    /// so marking one hidden greyed its name and changed nothing else.
    @AppStorage("showHiddenAccounts") private var showHidden = false
    @Environment(\.appFontScale) private var appFontScale

    private var trimmedFilter: String { filter.trimmingCharacters(in: .whitespaces) }

    private var visibleTree: [AccountNode] {
        showHidden ? model.accountTree : Self.pruningHidden(model.accountTree)
    }

    /// Drops hidden accounts and everything under them. Hiding a parent hides
    /// the subtree, as in GnuCash — a visible child of a hidden parent would
    /// have nowhere to hang.
    static func pruningHidden(_ nodes: [AccountNode]) -> [AccountNode] {
        nodes.compactMap { node in
            guard !node.isHidden else { return nil }
            guard let children = node.children else { return node }
            var copy = node
            copy.children = pruningHidden(children)
            return copy
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("Filter accounts", text: $filter)
                    .textFieldStyle(.roundedBorder)
                Toggle(isOn: $showHidden) {
                    Image(systemName: showHidden ? "eye" : "eye.slash")
                        .accessibilityLabel("Show hidden accounts")
                }
                .toggleStyle(.button)
                .help("Show hidden accounts")
            }
            .padding(8)
            Divider()
            list
        }
        .navigationSplitViewColumnWidth(min: 200 * appFontScale,
                                        ideal: 240 * appFontScale,
                                        max: 400 * appFontScale)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .edit(let id): EditAccountSheet(model: model, accountID: id)
            case .reconcile(let id): ReconcileView(model: model, accountID: id)
            case .delete(let id): DeleteAccountSheet(model: model, accountID: id)
            case .cascade(let id): CascadeAccountSheet(model: model, accountID: id)
            }
        }
    }

    @ViewBuilder
    private var list: some View {
        List(selection: $model.sidebarSelection) {
            // App areas that used to be modal sheets are now destinations shown
            // inline in the detail pane (HIG: minimise modality).
            if trimmedFilter.isEmpty {
                Section {
                    Label("Dashboard", systemImage: "square.grid.2x2").tag(SidebarSelection.dashboard)
                    Label("Reports", systemImage: "chart.pie").tag(SidebarSelection.reports)
                }
                Section("Planning") {
                    Label("Budgets", systemImage: "chart.bar.doc.horizontal").tag(SidebarSelection.budgets)
                    Label("Scheduled", systemImage: "calendar.badge.clock").tag(SidebarSelection.scheduled)
                    Label("Savings Goals", systemImage: "target").tag(SidebarSelection.goals)
                }
                Section("Records") {
                    Label("Business", systemImage: "building.2").tag(SidebarSelection.business)
                    Label("Prices & Quotes", systemImage: "tag").tag(SidebarSelection.prices)
                    Label("Time & Mileage", systemImage: "clock.badge.checkmark").tag(SidebarSelection.timeMileage)
                    Label("Rules", systemImage: "wand.and.stars").tag(SidebarSelection.rules)
                }
            }
            accountsSection
        }
    }

    @ViewBuilder
    private var accountsSection: some View {
        Section("Accounts") {
            if trimmedFilter.isEmpty {
                OutlineGroup(visibleTree, children: \.children) { node in
                    row(node, label: node.name)
                }
            } else {
                // Filtering flattens to matches and shows full names — the same
                // shape as Find's account picker, and the reason typing "cdia"
                // beats opening three disclosure triangles on 559 accounts.
                let matches = AccountMatchPicker.matching(visibleTree, filter: trimmedFilter,
                                                          includingPlaceholders: true)
                if matches.isEmpty {
                    Text("No accounts match “\(trimmedFilter)”.")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(matches) { node in
                        row(node, label: node.fullName)
                    }
                }
            }
        }
    }

    private func row(_ node: AccountNode, label: String) -> some View {
        HStack {
            // GnuCash account colour, shown Finder-tag style.
            if let dot = node.color.flatMap(GnuCashColor.color(from:)) {
                Circle()
                    .fill(dot)
                    .frame(width: 9, height: 9)
                    .accessibilityHidden(true)
            }
            Text(label)
                .scaledFont(.body)
                .foregroundStyle(node.isHidden ? .secondary : .primary)
            Spacer()
            Text(AmountFormat.string(node.balance, code: node.currencyCode))
                .scaledFont(.body)
                .monospacedDigit()
                .foregroundStyle(node.balance < 0 ? .red : .secondary)
        }
        .tag(SidebarSelection.account(node.id))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(AmountFormat.string(node.balance, code: node.currencyCode))
        .contextMenu {
            Button("Edit…") { sheet = .edit(node.id) }
            Button("Reconcile…") { sheet = .reconcile(node.id) }
            // Only where there is a subtree to cascade onto.
            if !(node.children ?? []).isEmpty {
                Button("Cascade Properties…") { sheet = .cascade(node.id) }
            }
            // Always offered. It used to appear only for an account with
            // nothing in it, which on a real book is almost none of them — so
            // the answer to "why can't I delete this?" was a button that wasn't
            // there.
            Button("Delete…", role: .destructive) { sheet = .delete(node.id) }
        }
    }
}

// MARK: - Register

/// Which end of a register to scroll to (`FR-REG-08`).
enum RegisterEnd {
    case oldest, newest
}

struct RegisterView: View {
    @Bindable var model: AppModel
    @State private var selection: Set<GncGUID> = []
    @State private var editingTransactionID: GncGUID?
    @State private var style: RegisterStyle = .basic
    @State private var filterShown = false
    @State private var goToDateShown = false
    /// GnuCash's View ▸ Double Line. A preference rather than per-register
    /// state, as in GnuCash, so it survives moving between accounts.
    @AppStorage("registerDoubleLine") private var doubleLine = false
    /// Set by the ⌘↑/⌘↓ shortcuts; the scrolling view consumes and clears it.
    @State private var jump: RegisterEnd?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Style", selection: $style) {
                    ForEach(RegisterStyle.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .fixedSize()
                if style == .basic {
                    Spacer()
                    if model.selectedAccountHasChildren { subaccountsToggle }
                    doubleLineToggle
                    sortMenu
                    filterButton
                }
            }
            .padding(6)
            Divider()
            content
            if style == .basic, let summary = model.registerSummary {
                Divider()
                summaryBar(summary)
            }
        }
        .navigationTitle(style == .generalLedger ? "General Ledger" : selectedName)
        .background { jumpShortcuts }
        .sheet(isPresented: $filterShown) {
            RegisterFilterSheet(model: model)
        }
        .sheet(isPresented: $goToDateShown) {
            GoToDateSheet(model: model)
        }
    }

    /// GnuCash's Open Subaccounts, as a toggle rather than a second window:
    /// show the whole subtree's postings in this register. Only offered when
    /// the account has something under it — on a leaf it would do nothing.
    private var subaccountsToggle: some View {
        Toggle(isOn: $model.registerIncludesSubaccounts) {
            Label("Subaccounts", systemImage: "list.bullet.indent")
        }
        .toggleStyle(.button)
        .help("Include this account’s subaccounts in the register")
        .popoverTip(SubaccountsTip())
    }

    /// GnuCash's View ▸ Double Line: show each row's notes, memo and action
    /// under its description. Worth having beyond parity — 40% of the
    /// transactions in a real book carry notes, and without this there is
    /// nowhere they are visible.
    private var doubleLineToggle: some View {
        Toggle(isOn: $doubleLine) {
            Label("Double Line", systemImage: "text.alignleft")
        }
        .toggleStyle(.button)
        .help("Show notes, memo and action under each transaction")
    }

    /// GnuCash's View ▸ Sort By, as a menu rather than a dialog — the options
    /// are the point, not the panel.
    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $model.registerSort) {
                ForEach(RegisterSort.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Reverse Order", isOn: $model.registerSortReversed)
        } label: {
            Label(model.registerSort == .standard && !model.registerSortReversed
                  ? "Sort" : "Sort: \(model.registerSort.rawValue)",
                  systemImage: "arrow.up.arrow.down")
        }
        .fixedSize()
        .help("Choose the order transactions are listed in")
    }

    private var filterButton: some View {
        Button {
            filterShown = true
        } label: {
            Label(model.registerFilter.isShowingEverything ? "Filter" : "Filtered",
                  systemImage: model.registerFilter.isShowingEverything
                      ? "line.3.horizontal.decrease.circle"
                      : "line.3.horizontal.decrease.circle.fill")
        }
        .fixedSize()
        .help("Show only some transactions")
    }

    /// Keyboard-only buttons: a register spanning years of history is otherwise
    /// thousands of scroll-wheel ticks end to end. In the journal styles these
    /// move within the loaded page — "oldest" means the oldest entry on screen,
    /// which "Show Earlier" extends.
    private var jumpShortcuts: some View {
        Group {
            Button("Go to Oldest Transaction") { jump = .oldest }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Go to Newest Transaction") { jump = .newest }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Button("Go to Date…") { goToDateShown = true }
                .keyboardShortcut("g", modifiers: .command)
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        switch style {
        case .basic:
            if model.selectedAccountID == nil {
                ContentUnavailableView("Select an account", systemImage: "list.bullet.rectangle",
                                       description: Text("Choose an account to see its transactions."))
            } else if model.registerRows.isEmpty {
                ContentUnavailableView("No transactions", systemImage: "tray",
                                       description: Text("This account has no postings yet."))
            } else {
                registerTable
            }
        case .autoSplit:
            if model.selectedAccountID == nil {
                ContentUnavailableView("Select an account", systemImage: "list.bullet.rectangle",
                                       description: Text("Choose an account to see its transactions."))
            } else {
                JournalView(model: model, accountID: model.selectedAccountID,
                            editingTransactionID: $editingTransactionID, jump: $jump,
                            autoSplit: true)
            }
        case .journal:
            if model.selectedAccountID == nil {
                ContentUnavailableView("Select an account", systemImage: "list.bullet.rectangle",
                                       description: Text("Choose an account to see its transactions."))
            } else {
                JournalView(model: model, accountID: model.selectedAccountID,
                            editingTransactionID: $editingTransactionID, jump: $jump)
            }
        case .generalLedger:
            JournalView(model: model, accountID: nil,
                        editingTransactionID: $editingTransactionID, jump: $jump)
        }
    }

    private var registerTable: some View {
        ScrollViewReader { proxy in
            registerTableBody
                .onAppear { showPendingOrNewest(proxy) }
                .onChange(of: model.selectedAccountID) { showPendingOrNewest(proxy) }
                .onChange(of: model.pendingRegisterSplitID) { showPendingOrNewest(proxy) }
                .onChange(of: jump) { _, target in
                    guard let target else { return }
                    scroll(proxy, to: target)
                    jump = nil
                }
        }
        // GnuCash's blank transaction row, at the foot of the register where
        // GnuCash keeps it. Not in the subtree view: an entry needs to know
        // which single account it is entering into.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let accountID = model.selectedAccountID, !model.registerIncludesSubaccounts {
                VStack(spacing: 0) {
                    Divider()
                    RegisterEntryBar(model: model, accountID: accountID)
                }
            }
        }
    }

    /// Lands on the row a jump asked for, or the newest when nothing did.
    ///
    /// The pending row is consumed whichever way this goes: it names one split
    /// of one account, so leaving it set would let it re-apply to a register it
    /// was never meant for. If it isn't in these rows — a jump made while a
    /// journal style was showing — fall back to the newest rather than nothing.
    private func showPendingOrNewest(_ proxy: ScrollViewProxy) {
        guard let target = model.consumePendingRegisterSelection() else {
            scroll(proxy, to: .newest)
            return
        }
        guard model.registerRows.contains(where: { $0.id == target }) else {
            scroll(proxy, to: .newest)
            return
        }
        selection = [target]
        proxy.scrollTo(target, anchor: .center)
    }

    /// Click-to-sort, kept honest with the Sort menu: both read and write
    /// ``AppModel/registerSort``, so clicking the Date header and picking Date
    /// from the menu are the same setting, and the header arrow shows whichever
    /// way it was set. The comparator itself is never applied — the model sorts,
    /// as it always has, and the binding is just the header's handle on it.
    private var tableSortOrder: Binding<[KeyPathComparator<RegisterRow>]> {
        Binding(
            get: {
                switch model.registerSort {
                case .date: [KeyPathComparator(\RegisterRow.date,
                                               order: model.registerSortReversed ? .reverse : .forward)]
                case .description: [KeyPathComparator(\RegisterRow.description,
                                                      order: model.registerSortReversed ? .reverse : .forward)]
                case .amount: [KeyPathComparator(\RegisterRow.amount,
                                                 order: model.registerSortReversed ? .reverse : .forward)]
                default: []
                }
            },
            set: { comparators in
                guard let first = comparators.first else {
                    model.registerSort = .standard
                    model.registerSortReversed = false
                    return
                }
                if first.keyPath == \RegisterRow.date { model.registerSort = .date }
                else if first.keyPath == \RegisterRow.description { model.registerSort = .description }
                else if first.keyPath == \RegisterRow.amount { model.registerSort = .amount }
                model.registerSortReversed = first.order == .reverse
            })
    }

    private var registerTableBody: some View {
        Table(model.registerRows, selection: $selection, sortOrder: tableSortOrder) {
            TableColumn("Date", value: \.date) { row in
                Text(row.date, format: .dateTime.year().month().day())
                    .scaledFont(.body)
            }
            TableColumn("Description", value: \.description) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.description).scaledFont(.body)
                    // Only when there is something to say: an empty second line
                    // on every row would add height to show nothing.
                    if doubleLine, !row.secondLine.isEmpty {
                        Text(row.secondLine)
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            // Which account a row posted to, which only a subtree register has
            // to answer — in a single-account register every row is the same
            // account and the column would say nothing.
            TableColumn("Account") { row in
                Text(row.accountName).scaledFont(.body).foregroundStyle(.secondary)
            }
            TableColumn("Transfer") { row in
                Text(row.transfer).scaledFont(.body)
            }
            TableColumn("R") { row in
                Button(row.reconcile) { model.cycleReconcileState(splitID: row.id) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Reconciliation status")
                    .accessibilityValue(reconcileWord(row.reconcile))
                    .accessibilityHint("Activate to change")
            }
            TableColumn("Amount", value: \.amount) { row in
                Text(AmountFormat.string(row.amount, code: currencyCode))
                    .scaledFont(.body)
                    .monospacedDigit()
                    .foregroundStyle(row.amount < 0 ? .red : .primary)
                    .accessibilityLabel(AmountFormat.spoken(row.amount, code: currencyCode))
            }
            // Balance has no sort on purpose: each row's balance is the
            // account's balance *as of that posting*, computed in date order —
            // ordering by it would order by an artefact.
            TableColumn("Balance") { row in
                // Absent for a subtree spanning several commodities: a running
                // total of shares and dollars is a number of nothing.
                if let balance = row.runningBalance {
                    Text(AmountFormat.string(balance, code: currencyCode))
                        .scaledFont(.body)
                        .monospacedDigit()
                        .accessibilityLabel("Balance \(AmountFormat.spoken(balance, code: currencyCode))")
                } else {
                    Text("—").foregroundStyle(.tertiary)
                        .accessibilityLabel("No running balance")
                }
            }
        }
        .tableColumnHeaders(.visible)
        // A dense financial table reads better with a crisp cutoff where rows
        // scroll under the glass toolbar than with the default soft fade.
        .scrollEdgeEffectStyle(.hard, for: .top)
        // A VoiceOver rotor to jump straight between unreconciled postings in a
        // long ledger, rather than swiping through every row.
        .accessibilityRotor("Unreconciled") {
            ForEach(model.registerRows) { row in
                if reconcileWord(row.reconcile) == "Not reconciled" {
                    AccessibilityRotorEntry(row.description, id: row.id)
                }
            }
        }
        .contextMenu(forSelectionType: GncGUID.self) { ids in
            TransactionActions(model: model, splitID: ids.first)
        }
        .sheet(item: $model.editingTransactionID) { id in
            TransactionEditorSheet(model: model, editingID: id)
        }
        .sheet(item: $model.schedulingTransactionID) { id in
            ScheduleTransactionSheet(model: model, transactionID: id)
        }
        .onChange(of: selection) { model.selectedSplitID = selection.first }
    }

    /// Rows are ordered oldest first, so the newest posting is the last row.
    private func scroll(_ proxy: ScrollViewProxy, to end: RegisterEnd) {
        let target = end == .newest ? model.registerRows.last?.id : model.registerRows.first?.id
        guard let target else { return }
        proxy.scrollTo(target, anchor: end == .newest ? .bottom : .top)
    }

    private var selectedName: String {
        model.postableAccounts.first { $0.id == model.selectedAccountID }?.name
            ?? model.accountTree.first { $0.id == model.selectedAccountID }?.name
            ?? "Register"
    }

    /// GnuCash's register status strip: the balance under each reconcile lens.
    /// Values come from the engine's existing `BalanceFilter`, so they agree
    /// with the sidebar and the reports to the cent.
    private func summaryBar(_ s: AppModel.RegisterSummary) -> some View {
        func cell(_ label: String, _ value: Decimal) -> some View {
            HStack(spacing: 4) {
                Text(label).foregroundStyle(.secondary)
                Text(AmountFormat.string(value, code: s.currencyCode))
                    .monospacedDigit()
            }
            .scaledFont(.caption)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(label) \(AmountFormat.string(value, code: s.currencyCode))")
        }
        return HStack(spacing: 16) {
            cell("Present:", s.present)
            if s.hasFuture { cell("Future:", s.future) }
            cell("Cleared:", s.cleared)
            cell("Reconciled:", s.reconciled)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.4))
    }

    private var currencyCode: String {
        model.postableAccounts.first { $0.id == model.selectedAccountID }?.currencyCode ?? "AUD"
    }

    private func reconcileWord(_ glyph: String) -> String {
        switch glyph {
        case "c": "Cleared"
        case "y": "Reconciled"
        case "f": "Frozen"
        case "v": "Voided"
        default: "Not reconciled"
        }
    }
}

/// Journal / general-ledger register: each transaction with all its legs.
///
/// Journal / general-ledger register: each transaction's heading followed by
/// its legs, oldest first, opening on the newest.
///
/// A `Table` rather than a `List` of sections. Uniform rows are what make the
/// whole book affordable: AppKit positions row N without laying out the rows
/// before it, so jumping to either end is instant across 46k transactions and
/// no windowing is needed. The nested-section version had to be paged, and
/// scrolling it to the far end never settled.
struct JournalView: View {
    @Bindable var model: AppModel
    let accountID: GncGUID?
    @Binding var editingTransactionID: GncGUID?
    @Binding var jump: RegisterEnd?
    /// GnuCash's Auto-Split Ledger: the same rows, but only the selected
    /// transaction opened out. The two styles differ by which rows are shown and
    /// nothing else, so they are one view.
    var autoSplit = false
    @State private var selection: Set<GncGUID> = []
    @Environment(\.appFontScale) private var appFontScale

    /// The transaction to open out: whichever one the selected row belongs to,
    /// so selecting either a heading or one of its legs keeps it open.
    private var expandedTransactionID: GncGUID? {
        guard autoSplit, let id = selection.first else { return nil }
        return model.journalRows(forAccountID: accountID)
            .first { $0.id == id }?.transactionID
    }

    var body: some View {
        let rows = autoSplit
            ? model.autoSplitRows(forAccountID: accountID, expanding: expandedTransactionID)
            : model.journalRows(forAccountID: accountID)
        if rows.isEmpty {
            ContentUnavailableView("No transactions", systemImage: "tray",
                                   description: Text("No postings to show."))
        } else {
            ScrollViewReader { proxy in
                table(rows)
                    .onAppear { scroll(proxy, to: .newest) }
                    .onChange(of: accountID) { scroll(proxy, to: .newest) }
                    .onChange(of: jump) { _, target in
                        guard let target else { return }
                        scroll(proxy, to: target)
                        jump = nil
                    }
            }
        }
    }

    /// Jumps to the oldest or newest row. Bounded work whatever the distance.
    private func scroll(_ proxy: ScrollViewProxy, to end: RegisterEnd) {
        guard let target = model.journalEdgeRowID(forAccountID: accountID,
                                                  newest: end == .newest) else { return }
        proxy.scrollTo(target, anchor: end == .newest ? .bottom : .top)
    }

    private func table(_ rows: [JournalRow]) -> some View {
        Table(rows, selection: $selection) {
            TableColumn("Date") { row in
                if let date = row.date {
                    Text(date, format: .dateTime.year().month().day())
                        .scaledFont(.body).fontWeight(.medium)
                }
            }
            .width(min: 90, ideal: 100)
            TableColumn("Transaction / Account") { row in
                // Legs are indented under their heading, so the grouping still
                // reads even though the rows are flat.
                Text(row.text)
                    .scaledFont(.body)
                    .fontWeight(row.isHeading ? .medium : (row.isFocusAccount ? .semibold : .regular))
                    .foregroundStyle(row.isHeading ? .primary : .secondary)
                    .padding(.leading, row.isHeading ? 0 : 18 * appFontScale)
            }
            TableColumn("Amount") { row in
                if let amount = row.amount {
                    Text(AmountFormat.string(amount, code: row.currencyCode))
                        .scaledFont(.body)
                        .monospacedDigit()
                        .foregroundStyle(amount < 0 ? .red : .primary)
                }
            }
            .width(min: 100, ideal: 130)
        }
        .contextMenu(forSelectionType: GncGUID.self) { ids in
            // A journal row is a heading or a leg. A heading has no split of its
            // own, so act on the transaction's first leg — the same transaction
            // either way, which is what the operations are about.
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                TransactionActions(model: model, splitID: model.anySplitID(ofTransaction: row.transactionID))
            }
        }
        .sheet(item: $model.editingTransactionID) { id in
            TransactionEditorSheet(model: model, editingID: id)
        }
        .sheet(item: $model.schedulingTransactionID) { id in
            ScheduleTransactionSheet(model: model, transactionID: id)
        }
        .onChange(of: selection) {
            if let id = selection.first, let row = rows.first(where: { $0.id == id }) {
                model.selectedSplitID = model.anySplitID(ofTransaction: row.transactionID)
            } else {
                model.selectedSplitID = nil
            }
        }
    }
}

/// Everything you can do to the selected transaction.
///
/// One definition, used by the Basic register's context menu, the Journal's,
/// the General Ledger's, and the Transaction menu in the menu bar. They were
/// three different lists before — Basic had seven operations, Journal had Edit,
/// and the menu bar had none — and the only way to keep them the same is for
/// there to be one of them.
public struct TransactionActions: View {
    @Bindable var model: AppModel
    /// The split the row stands for. `nil` when nothing is selected, which is
    /// what disables the menu-bar copy.
    var splitID: GncGUID?
    @State private var pasteError: String?

    public init(model: AppModel, splitID: GncGUID?) {
        self.model = model
        self.splitID = splitID
    }

    private var txnID: GncGUID? { splitID.flatMap { model.transactionID(ofSplit: $0) } }

    /// Each item carries its own condition rather than the whole menu being
    /// disabled together: `disabled` is inherited and cannot be undone by a
    /// child, and Paste is the one item here that does not want a selected row —
    /// it wants something on the clipboard.
    private var needsRow: Bool { txnID == nil }

    public var body: some View {
        Group {
            Button("Edit Transaction…") { model.editingTransactionID = txnID }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(needsRow)
            Button("Go to Other Account") {
                if let splitID { model.jumpToOtherAccount(ofSplit: splitID) }
            }
            .keyboardShortcut("j", modifiers: .command)
            .disabled(needsRow)
            Button("Attach File…", systemImage: "paperclip") {
                if let txnID { model.attachDocumentRequestTxnID = txnID }
            }
            .disabled(needsRow)
            Button("Print Check…", systemImage: "printer") {
                if let txnID { model.printCheckRequestTxnID = txnID }
            }
            .disabled(needsRow)
            if let txnID, model.hasLinkedDocument(txnID) {
                Button("Open Linked Document", systemImage: "paperclip.badge.ellipsis") {
                    model.openLinkedDocument(for: txnID)
                }
            }
            Divider()
            reconcileStateMenu
            Divider()
            // Shifted, because ⌘C/⌘X/⌘V belong to whatever text has focus, and
            // taking them would make copying a description impossible.
            Button("Cut Transaction") {
                if let txnID { model.cutTransaction(txnID) }
            }
            .keyboardShortcut("x", modifiers: [.command, .shift])
            .disabled(needsRow)
            Button("Copy Transaction") {
                if let txnID { model.copyTransaction(txnID) }
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(needsRow)
            Button("Paste Transaction") {
                do { _ = try model.pasteTransaction() }
                catch let error as AppModel.PasteError { pasteError = model.describe(error) }
                catch { pasteError = error.localizedDescription }
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .disabled(!model.canPasteTransaction)
            Divider()
            Button("Duplicate Transaction") {
                if let txnID { model.duplicateTransaction(txnID) }
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(needsRow)
            Button("Add Reversing Transaction") {
                if let txnID { _ = model.addReversingTransaction(txnID) }
            }
            .disabled(needsRow)
            Button("Schedule…") { model.schedulingTransactionID = txnID }
                .disabled(needsRow)
            if let txnID, model.isVoided(txnID) {
                Button("Unvoid Transaction") { model.unvoidTransaction(txnID) }
            } else {
                Button("Void Transaction") {
                    if let txnID { model.voidTransaction(txnID) }
                }
                .disabled(needsRow)
            }
            Divider()
            Button("Delete Transaction", role: .destructive) {
                if let txnID { model.deleteTransaction(txnID) }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(needsRow)
        }
        .alert("Paste Transaction", isPresented: Binding(
            get: { pasteError != nil },
            set: { if !$0 { pasteError = nil } })) {
            Button("OK", role: .cancel) { pasteError = nil }
        } message: {
            Text(pasteError ?? "")
        }
    }

    /// Every reconcile state, not just the three the R column cycles through.
    ///
    /// `setReconcileState` has handled all five since it was written, and had no
    /// caller outside its tests — so frozen (`f`) could be imported, stored,
    /// exported and shown, but never set. Clicking the R column still cycles
    /// n → c → y, which is the common path; this is where the other two live.
    /// Voided is absent on purpose: it is not a flag but an operation, and it
    /// has its own Void/Unvoid item that rewrites the whole transaction.
    @ViewBuilder
    private var reconcileStateMenu: some View {
        let current = splitID.flatMap { model.reconcileState(ofSplit: $0) }
        Menu("Reconcile State") {
            Picker("Reconcile State", selection: Binding(
                get: { current ?? .notReconciled },
                set: { state in
                    if let splitID { model.setReconcileState(splitID: splitID, to: state) }
                }
            )) {
                ForEach(ReconcileState.settableInRegister, id: \.self) { state in
                    Text(state.label).tag(state)
                }
            }
            .pickerStyle(.inline)
        }
        .disabled(splitID == nil || current == .voided)
    }
}

/// GnuCash's blank transaction row, as an entry bar at the foot of the register
/// (`FR-REG-05`).
///
/// Date, description, transfer account, amount, Return — and the row appears
/// above with focus back in the description, because the point of entering at
/// the register is entering the *next* one too. QuickFill fills the transfer
/// and amount from the last transaction with the same description, which is
/// most of most people's entries.
struct RegisterEntryBar: View {
    @Bindable var model: AppModel
    let accountID: GncGUID

    @State private var date = Date()
    @State private var descriptionText = ""
    @State private var transferID: GncGUID?
    @State private var amountText = ""
    @FocusState private var descriptionFocused: Bool
    @Environment(\.appFontScale) private var appFontScale

    private var amount: Decimal? { EditableSplit.strictDecimal(
        amountText.trimmingCharacters(in: .whitespaces)) }
    private var canCommit: Bool {
        transferID != nil && (amount ?? 0) != 0
            && !descriptionText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        HStack(spacing: 8) {
            DatePicker("", selection: $date, displayedComponents: .date)
                .labelsHidden()
                .fixedSize()

            TextField("Description", text: $descriptionText)
                .textFieldStyle(.roundedBorder)
                .focused($descriptionFocused)
                .frame(minWidth: 140)

            // QuickFill: the last transaction with this description, offered
            // rather than applied — autofilling on a prefix match would race
            // the typing it is matching.
            let suggestions = model.descriptionSuggestions(prefix: descriptionText)
            Menu {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button(suggestion) { applySuggestion(suggestion) }
                }
            } label: {
                Image(systemName: "wand.and.stars")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(suggestions.isEmpty)
            .help("Fill from a recent transaction with this description")

            Picker("", selection: $transferID) {
                Text("Transfer from…").tag(GncGUID?.none)
                ForEach(model.postableAccounts.filter { $0.id != accountID }) { node in
                    Text(node.fullName).tag(GncGUID?.some(node.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 240)

            TextField("Amount", text: $amountText)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 100 * appFontScale)
                .onSubmit(commit)

            Button("Enter", action: commit)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canCommit)
                .help("Add this transaction (⌘↩)")
        }
        .scaledFont(.body)
        .padding(8)
        .background(.bar)
    }

    private func applySuggestion(_ suggestion: String) {
        descriptionText = suggestion
        if let fill = model.quickFill(forDescription: suggestion, into: accountID) {
            transferID = fill.transferID
            amountText = NSDecimalNumber(decimal: fill.amount).stringValue
        }
    }

    private func commit() {
        guard canCommit, let transferID, let amount else { return }
        guard model.quickEnter(into: accountID, transferFrom: transferID,
                               amount: amount, date: date,
                               description: descriptionText) != nil else { return }
        // Keep the date and the transfer: runs of entries share both. Clear
        // what identifies the transaction, and put focus back where the next
        // one starts.
        descriptionText = ""
        amountText = ""
        descriptionFocused = true
    }
}

/// GnuCash's Find Account (⌘I): type a few letters, land on the account
/// (`FR-FIND-02`).
///
/// The sidebar filter covers browsing; this is for the keyboard. ⌘I, type,
/// Return — no mouse, no disclosure triangles, and it works however deep the
/// account is buried. The filter is the same `matching` Find's picker and the
/// sidebar use, so all three agree about what a search string means.
struct FindAccountSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var filter = ""
    @State private var selection: GncGUID?
    @FocusState private var filterFocused: Bool

    private var matches: [AccountNode] {
        AccountMatchPicker.matching(model.accountTree,
                                    filter: filter.trimmingCharacters(in: .whitespaces),
                                    includingPlaceholders: true)
    }

    /// Return acts on what you can see: the chosen row, or the only match —
    /// "cdia" narrowing to one account should not also demand an arrow key.
    private var target: GncGUID? { Self.target(selection: selection, matches: matches) }

    static func target(selection: GncGUID?, matches: [AccountNode]) -> GncGUID? {
        selection ?? (matches.count == 1 ? matches.first?.id : nil)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("Account name", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .focused($filterFocused)
                    .onSubmit(show)
                    .padding(8)
                Divider()
                List(selection: $selection) {
                    ForEach(matches) { node in
                        HStack {
                            Text(node.fullName)
                            Spacer()
                            Text(AmountFormat.string(node.balance, code: node.currencyCode))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .tag(node.id)
                    }
                }
                .contextMenu(forSelectionType: GncGUID.self) { _ in } primaryAction: { ids in
                    selection = ids.first
                    show()
                }
                if matches.isEmpty {
                    Text("No accounts match “\(filter)”.")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            }
            .navigationTitle("Find Account")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Show") { show() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(target == nil)
                }
            }
            .onAppear { focusSoon { filterFocused = true } }
            .onChange(of: filter) { selection = nil }
        }
        .frame(minWidth: 440, minHeight: 360)
    }

    private func show() {
        guard let target else { return }
        model.selectedAccountID = target
        dismiss()
    }
}

/// GnuCash's Transaction ▸ Schedule…: turn a transaction you have already
/// entered into a recurring one (`FR-SCH-01`).
struct ScheduleTransactionSheet: View {
    @Bindable var model: AppModel
    var transactionID: GncGUID
    @Environment(\.dismiss) private var dismiss

    @State private var loaded = false
    @State private var name = ""
    @State private var period: RecurrencePeriod = .monthly
    @State private var interval = 1
    @State private var advanceCreateDays = 0
    @State private var advanceRemindDays = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("Repeat") {
                    Picker("Every", selection: $period) {
                        ForEach(RecurrencePeriod.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    Stepper("Every \(interval) \(unitName)", value: $interval, in: 1...52)
                }
                Section("Name") {
                    TextField("Name", text: $name)
                }
                Section("Create ahead") {
                    Stepper("Create \(advanceCreateDays) days early",
                            value: $advanceCreateDays, in: 0...90)
                    Stepper("Remind \(advanceRemindDays) days early",
                            value: $advanceRemindDays, in: 0...90)
                }
                Section {
                    // The thing worth saying: this schedules the *next* one. The
                    // transaction in front of you already exists and is not
                    // about to be posted again.
                    Text("The first occurrence will be the next one after this "
                         + "transaction’s date. This transaction is left alone.")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Schedule Transaction")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Schedule") {
                        model.scheduleTransaction(transactionID, period: period,
                                                  interval: interval, name: name,
                                                  advanceCreateDays: advanceCreateDays,
                                                  advanceRemindDays: advanceRemindDays)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .onAppear(perform: loadIfNeeded)
        }
        .frame(minWidth: 420, minHeight: 300)
    }

    private var unitName: String {
        let singular = period.unitNoun
        return interval == 1 ? singular : singular + "s"
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let edit = model.editData(forTransaction: transactionID) {
            name = edit.description
        }
    }
}

/// GnuCash's Go to Date (⌘G): jump the register to where a day begins.
struct GoToDateSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var missed = false

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Date", selection: $date, displayedComponents: .date)
                if missed {
                    Text("No transaction on or after that date.")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Go to Date")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Go") {
                        // Say so rather than dismissing onto an unchanged
                        // register, which would read as the jump being ignored.
                        if model.goToDate(date) { dismiss() } else { missed = true }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .onChange(of: date) { missed = false }
        }
        .frame(minWidth: 340, minHeight: 180)
    }
}

/// GnuCash's View ▸ Filter By: which rows the register shows, by date and by
/// reconcile status. Edits a draft and applies on Done, so half-set criteria
/// don't churn the register underneath the user.
struct RegisterFilterSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var limitDates = false
    @State private var start = Date()
    @State private var end = Date()
    @State private var statuses: Set<ReconcileState> = Set(ReconcileState.allCases)
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Date") {
                    Toggle("Limit to a date range", isOn: $limitDates)
                    if limitDates {
                        DatePicker("From", selection: $start, displayedComponents: .date)
                        DatePicker("To", selection: $end, in: start..., displayedComponents: .date)
                    }
                }
                Section("Status") {
                    ForEach(ReconcileState.allCases, id: \.self) { state in
                        Toggle(Self.name(state), isOn: binding(for: state))
                    }
                    HStack {
                        Button("Select All") { statuses = Set(ReconcileState.allCases) }
                        Spacer()
                        Button("Clear All") { statuses = [] }
                    }
                }
                if statuses.isEmpty {
                    Text("No statuses selected — the register will be empty.")
                        .scaledFont(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Filter Transactions")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { apply() }
                }
                ToolbarItem(placement: .automatic) {
                    Button("Show All") {
                        model.registerFilter = .showAll
                        dismiss()
                    }
                    .disabled(model.registerFilter.isShowingEverything)
                }
            }
            .onAppear(perform: loadIfNeeded)
        }
    }

    private func binding(for state: ReconcileState) -> Binding<Bool> {
        Binding(
            get: { statuses.contains(state) },
            set: { isOn in
                if isOn { statuses.insert(state) } else { statuses.remove(state) }
            }
        )
    }

    private static func name(_ state: ReconcileState) -> String {
        switch state {
        case .notReconciled: "Unreconciled"
        case .cleared: "Cleared"
        case .reconciled: "Reconciled"
        case .frozen: "Frozen"
        case .voided: "Voided"
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let filter = model.registerFilter
        statuses = filter.statuses
        if let from = filter.startDate, let to = filter.endDate {
            limitDates = true
            start = from
            end = to
        } else {
            // Default the range to the span actually on screen, so turning the
            // toggle on doesn't blank the register.
            start = model.registerRows.first?.date ?? Date()
            end = model.registerRows.last?.date ?? Date()
        }
    }

    private func apply() {
        model.registerFilter = RegisterFilter(
            statuses: statuses,
            startDate: limitDates ? start : nil,
            endDate: limitDates ? end : nil)
        dismiss()
    }
}

// MARK: - Search results

struct SearchResultsView: View {
    @Bindable var model: AppModel
    @State private var selection: Set<GncGUID> = []
    @State private var editingTransactionID: GncGUID?

    var body: some View {
        Table(model.searchResults, selection: $selection) {
            TableColumn("Date") { row in
                Text(row.date, format: .dateTime.year().month().day())
                    .scaledFont(.body)
            }
            TableColumn("Description") { row in
                Text(row.description).scaledFont(.body)
            }
            TableColumn("Accounts") { row in
                Text(row.accounts).scaledFont(.body)
            }
            TableColumn("Amount") { row in
                Text(AmountFormat.string(row.amount, code: row.currencyCode))
                    .scaledFont(.body)
                    .monospacedDigit()
            }
        }
        // A result is a transaction, so it can be worked on like one. Editing
        // in place is what makes "find, then fix each one" possible without
        // leaving the results — the nearest thing we have to GnuCash, whose
        // Find opens its results as a register. With several rows selected the
        // menu acts on all of them, as one edit and one Undo: "find last
        // month's cheques, mark them cleared" is one act, not forty.
        .contextMenu(forSelectionType: GncGUID.self) { ids in
            let list = Array(ids)
            if let id = list.first, list.count == 1 {
                Button("Edit…") { editingTransactionID = id }
                Button("Show in Register") { model.showInRegister(id) }
                Divider()
            }
            // Reconcile state applies to the *matched* split of each result —
            // the leg the search was about — so it is only offered where a
            // structured find remembered one.
            if model.findQuery != nil, !list.isEmpty {
                Menu(list.count == 1 ? "Set Reconcile State"
                     : "Set Reconcile State (\(list.count))") {
                    ForEach(ReconcileState.settableInRegister, id: \.self) { state in
                        Button(state.label) {
                            model.setReconcileStateOfMatches(in: list, to: state)
                        }
                    }
                }
            }
            if !list.isEmpty {
                Button(list.count == 1 ? "Void Transaction"
                       : "Void \(list.count) Transactions") {
                    model.voidTransactions(list)
                }
                Divider()
                Button(list.count == 1 ? "Delete Transaction"
                       : "Delete \(list.count) Transactions", role: .destructive) {
                    model.deleteTransactions(list)
                }
            }
        } primaryAction: { ids in
            if let id = ids.first, ids.count == 1 { editingTransactionID = id }
        }
        .sheet(item: $editingTransactionID) { id in
            TransactionEditorSheet(model: model, editingID: id)
        }
        .overlay {
            if model.searchResults.isEmpty { noResults }
        }
        .safeAreaInset(edge: .top) {
            if !model.searchNotices.isEmpty { noticeBanner }
        }
        .toolbar {
            if model.findQuery != nil {
                ToolbarItemGroup {
                    Button("Edit Find…", systemImage: "slider.horizontal.3") {
                        model.presentedPanel = .find
                    }
                    .help("Change the search criteria (⌘F)")
                    Button("Clear", systemImage: "xmark.circle") { model.clearFind() }
                        .help("Stop showing find results")
                }
            }
        }
        .navigationTitle(title)
    }

    private var title: String {
        model.findQuery == nil
            ? "Results for “\(model.searchQuery)”"
            : "Find Results (\(model.searchResults.count))"
    }

    /// Finding nothing is a result. Saying nothing is not: without this the
    /// detail pane fell back to the dashboard and the search vanished.
    private var noResults: some View {
        ContentUnavailableView {
            Label("No Results", systemImage: "magnifyingglass")
        } description: {
            if model.findQuery == nil {
                Text("No transactions match “\(model.searchQuery)”.")
            } else {
                Text("No splits match these criteria.")
            }
        } actions: {
            if model.findQuery != nil {
                Button("Edit Criteria…") { model.presentedPanel = .find }
            }
        }
    }

    private var noticeBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.searchNotices) { notice in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(notice.message).scaledFont(.callout)
                        Text(notice.recovery)
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.bar)
    }
}

// MARK: - New account

/// A small catalog of common ISO currencies for the account editor.
enum CurrencyCatalog {
    static let common: [Commodity] = [
        .currency("AUD", name: "Australian Dollar"),
        .currency("USD", name: "US Dollar"),
        .currency("EUR", name: "Euro"),
        .currency("GBP", name: "Pound Sterling"),
        .currency("NZD", name: "New Zealand Dollar"),
        .currency("CAD", name: "Canadian Dollar"),
        .currency("JPY", fractionDigits: 0, name: "Japanese Yen"),
        .currency("CHF", name: "Swiss Franc"),
        .currency("CNY", name: "Chinese Yuan"),
        .currency("HKD", name: "Hong Kong Dollar"),
        .currency("SGD", name: "Singapore Dollar"),
        .currency("INR", name: "Indian Rupee"),
    ]
}

/// Names and saves the current search query.
struct SaveSearchSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("Query", value: model.searchQuery)
                TextField("Name", text: $name).focused($focused)
            }
            .navigationTitle("Save Search")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { model.saveCurrentSearch(name: name); dismiss() }
                }
            }
            .onAppear { focusSoon { focused = true } }
        }
        .frame(minWidth: 360, minHeight: 160)
    }
}

struct NewAccountSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var type: AccountType = .bank
    @State private var parentID: GncGUID?
    @State private var currencyCode = ""
    @State private var exchange = ""
    @State private var ticker = ""
    @State private var securityName = ""
    @FocusState private var nameFocused: Bool

    private let selectableTypes: [AccountType] = [
        .bank, .cash, .asset, .credit, .liability, .equity, .income, .expense, .stock, .mutualFund,
    ]

    private var isSecurity: Bool { type.isSecurityType }

    /// Book currencies plus the common catalog, de-duplicated by code.
    private var availableCurrencies: [Commodity] {
        var seen = Set<String>()
        var result: [Commodity] = []
        for commodity in model.currencyCommodities + CurrencyCatalog.common
        where seen.insert(commodity.mnemonic).inserted {
            result.append(commodity)
        }
        return result
    }

    private var canAdd: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return isSecurity ? !ticker.trimmingCharacters(in: .whitespaces).isEmpty : true
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                    .focused($nameFocused)
                Picker("Type", selection: $type) {
                    ForEach(selectableTypes, id: \.self) { t in
                        Text(t.rawValue.capitalized).tag(t)
                    }
                }
                Picker("Parent", selection: $parentID) {
                    Text("Top level").tag(GncGUID?.none)
                    ForEach(model.accountTree) { node in
                        Text(node.name).tag(GncGUID?.some(node.id))
                    }
                }

                if isSecurity {
                    Section("Security") {
                        TextField("Exchange (e.g. ASX)", text: $exchange)
                        TextField("Ticker (e.g. CBA)", text: $ticker)
                        TextField("Full name (optional)", text: $securityName)
                    }
                } else {
                    Picker("Currency", selection: $currencyCode) {
                        ForEach(availableCurrencies, id: \.mnemonic) { c in
                            Text("\(c.mnemonic) — \(c.fullName)").tag(c.mnemonic)
                        }
                    }
                }
            }
            .navigationTitle("New Account")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }.disabled(!canAdd)
                }
            }
            .onAppear {
                if currencyCode.isEmpty { currencyCode = model.reportCurrency.mnemonic }
                focusSoon { nameFocused = true }
            }
        }
    }

    private func makeCommodity() -> Commodity {
        if isSecurity {
            let code = ticker.trimmingCharacters(in: .whitespaces).uppercased()
            let ex = exchange.trimmingCharacters(in: .whitespaces).uppercased()
            let full = securityName.trimmingCharacters(in: .whitespaces)
            return Commodity(namespace: .security(ex.isEmpty ? "OTHER" : ex),
                             mnemonic: code,
                             fullName: full.isEmpty ? code : full,
                             smallestFraction: 10_000)
        }
        return availableCurrencies.first { $0.mnemonic == currencyCode } ?? .currency(currencyCode)
    }

    private func add() {
        model.addAccount(name: name, type: type, commodity: makeCommodity(), parentID: parentID)
        dismiss()
    }
}

// MARK: - Transaction editor (multi-split)

/// One editable row of the transaction editor.
///
/// Internal rather than private so the round-trip below can be tested: this
/// type is the only thing standing between a transaction and its rewrite on
/// save, and the fields it forgets are the fields the save destroys.
struct EditableSplit: Identifiable {
    let id = UUID()

    /// The split this row came from, or `nil` for a leg the user just added.
    /// Carried so the save can re-attach to that split instead of replacing it,
    /// which is what keeps its reconcile state, identity and slots alive.
    var splitID: GncGUID?
    var accountID: GncGUID?
    var amountText: String = ""

    /// The split's amount in its **own** commodity — a share count for a
    /// security, the foreign amount for an FX leg — when it differs from the
    /// value. Empty means "same as the value", which is right for a plain cash
    /// posting and lets editing the amount carry the quantity with it.
    ///
    /// Editable text now (GnuCash's Edit Exchange Rate); it was carried blind,
    /// so the one number you could not fix on an FX or security leg was the
    /// foreign amount. GnuCash's dialog edits the *rate*, but the book stores
    /// value and quantity — editing the quantity with the implied rate shown is
    /// the same act without a derived field that can drift from what is stored.
    var quantityText: String = ""

    var quantity: Decimal? {
        let trimmed = quantityText.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : Self.strictDecimal(trimmed)
    }

    /// Empty is fine (the quantity follows the value); text that does not parse
    /// is not. The test for this found the hazard was worse than assumed:
    /// `Decimal(string:)` parses a numeric *prefix*, so "1o" is not rejected —
    /// it is **1**, and a typo would have quietly set a share count to 1.
    var quantityIsValid: Bool {
        quantityText.trimmingCharacters(in: .whitespaces).isEmpty || quantity != nil
    }

    /// A decimal only if the *whole* string is one — or a whole arithmetic
    /// expression that evaluates to one (GnuCash lets you type `5*3` or
    /// `10.50+2` into an amount cell; ``AmountExpression`` validates the whole
    /// string and returns the number for a plain figure).
    static func strictDecimal(_ text: String) -> Decimal? {
        AmountExpression.evaluate(text)
    }

    /// Per-split memo and GnuCash's per-split Action. Both are editable below;
    /// both were previously carried blind, and `action` was not carried at all.
    var memo: String = ""
    var action: String = ""

    /// Strict for the same reason as the quantity: `Decimal(string:)` parses a
    /// prefix, so "4o0" would be 4 — here it is 0, and the imbalance readout
    /// says so instead of the sheet saving a number nobody typed.
    var amount: Decimal { Self.strictDecimal(amountText.trimmingCharacters(in: .whitespaces)) ?? 0 }

    init(accountID: GncGUID? = nil, amountText: String = "") {
        self.accountID = accountID
        self.amountText = amountText
    }

    init(_ input: SplitInput) {
        self.splitID = input.splitID
        self.accountID = input.accountID
        self.amountText = NSDecimalNumber(decimal: input.value).stringValue
        self.quantityText = input.quantity.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
        self.memo = input.memo
        self.action = input.action
    }

    /// The row as the engine takes it. Everything the editor knows about a
    /// split has to come back out here, including the parts it never showed.
    var asInput: SplitInput {
        SplitInput(splitID: splitID, accountID: accountID, value: amount,
                   quantity: quantity, memo: memo, action: action)
    }
}

/// Creates or edits a transaction with N balancing splits, with QuickFill.
struct TransactionEditorSheet: View {
    @Bindable var model: AppModel
    var editingID: GncGUID?
    @Environment(\.dismiss) private var dismiss

    @State private var loaded = false
    @State private var date = Date()
    @State private var description = ""
    @State private var notes = ""
    @State private var tagsText = ""
    @State private var lines: [EditableSplit] = [EditableSplit(), EditableSplit()]
    @FocusState private var descriptionFocused: Bool
    @State private var commitError: String?
    @State private var invoicePickerShown = false
    @State private var analyzingInvoice = false
    @Environment(\.appFontScale) private var appFontScale
    private var amountWidth: CGFloat { 100 * appFontScale }

    private var parsedTags: [String] {
        tagsText.split(whereSeparator: { $0 == "," || $0 == " " })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// What is being typed after the last comma — the tag in progress, which is
    /// what suggestions should narrow on.
    private var tagFragment: String {
        String(tagsText.split(separator: ",", omittingEmptySubsequences: false).last ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Completes the tag in progress rather than appending after it, so picking
    /// "groceries" while "groc" is typed does not leave "groc, groceries".
    private func appendTag(_ tag: String) {
        var parts = tagsText.split(separator: ",", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        if parts.isEmpty || !tagFragment.isEmpty { _ = parts.popLast() }
        parts.removeAll { $0.isEmpty }
        parts.append(tag)
        tagsText = parts.joined(separator: ", ")
    }

    private var imbalance: Decimal { lines.reduce(Decimal(0)) { $0 + $1.amount } }
    /// Currency of the transaction being built (first cash account's, else base).
    private var displayCurrency: Commodity {
        model.transactionCurrency(for: lines.compactMap(\.accountID))
    }
    private var validLineCount: Int { lines.filter { $0.accountID != nil }.count }
    private var isBalanced: Bool {
        imbalance == 0 && validLineCount >= 2 && lines.allSatisfy(\.quantityIsValid)
    }
    private var isEditing: Bool { editingID != nil }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Date", selection: $date, displayedComponents: .date)
                TextField("Description", text: $description)
                    .focused($descriptionFocused)
                if !isEditing {
                    let suggestions = model.descriptionSuggestions(prefix: description)
                    if !suggestions.isEmpty {
                        Menu("Fill from recent…") {
                            ForEach(suggestions, id: \.self) { suggestion in
                                Button(suggestion) { applyTemplate(suggestion) }
                            }
                        }
                    }
                }

                // GnuCash's Notes: the second line of a double-line register,
                // and the only home for the 18,641 notes this book already
                // carries — they round-tripped through import and export
                // faithfully while being impossible to read.
                TextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(1...4)

                Section("Splits") {
                    // Two rows per split, as GnuCash shows them: the posting,
                    // then its own memo and action. Two sibling rows rather
                    // than a VStack — nesting the posting row inside a stack
                    // takes it out of the Form's own row layout, and the
                    // account Picker's intrinsic width (the longest of 559 full
                    // account names) then overflows the sheet on both sides.
                    // Two lines per split, as GnuCash shows them: the posting,
                    // then that split's own memo and action. Labels are hidden
                    // and the prompts carry the naming — a Form row that keeps
                    // its labels is split into a label column and a content
                    // column sized across every row, and the account picker
                    // (as wide as the longest of 559 full account paths) then
                    // drags that column wider than the sheet.
                    ForEach($lines) { $line in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Picker("Account", selection: $line.accountID) {
                                    Text("—").tag(GncGUID?.none)
                                    ForEach(model.postableAccounts) { node in
                                        Text(node.fullName).tag(GncGUID?.some(node.id))
                                    }
                                }
                                .labelsHidden()
                                TextField("Amount", text: $line.amountText,
                                          prompt: Text("Amount"))
                                    .labelsHidden()
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: amountWidth)
                            }
                            HStack(spacing: 8) {
                                TextField("Memo", text: $line.memo, prompt: Text("Memo"))
                                    .labelsHidden()
                                TextField("Action", text: $line.action, prompt: Text("Action"))
                                    .labelsHidden()
                                    .frame(width: amountWidth)
                            }
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            // GnuCash's Edit Exchange Rate, only where there is
                            // one: a leg posting to another commodity has two
                            // amounts, and the second was carried blind.
                            if let unit = foreignUnit(of: line) {
                                HStack(spacing: 8) {
                                    Text(rateDescription(of: line, unit: unit))
                                        .foregroundStyle(.secondary)
                                    Spacer(minLength: 0)
                                    TextField("Quantity", text: $line.quantityText,
                                              prompt: Text(unit))
                                        .labelsHidden()
                                        .multilineTextAlignment(.trailing)
                                        .frame(width: amountWidth)
                                }
                                .scaledFont(.caption)
                            }
                        }
                    }
                    .onDelete { lines.remove(atOffsets: $0) }
                    Button("Add Split", systemImage: "plus") { lines.append(EditableSplit()) }
                    if model.isIntelligenceAvailable {
                        Button {
                            #if os(macOS)
                            if let url = MacFilePanel.open(types: [.pdf],
                                                           title: "Choose an invoice (PDF)") {
                                analyzeInvoice(url)
                            }
                            #else
                            invoicePickerShown = true
                            #endif
                        } label: {
                            Label(analyzingInvoice ? "Reading invoice…" : "Split from Invoice…",
                                  systemImage: "sparkles")
                        }
                        .disabled(analyzingInvoice)
                        .help("Read an invoice PDF and split this transaction across its line items")
                    }
                }

                Section("Tags") {
                    TextField("Comma-separated tags", text: $tagsText)
                    // Fed by `Book.allTags`, which existed and was tested with
                    // no caller: the field was free text, so reusing a tag
                    // meant remembering how you spelled it and a typo quietly
                    // made a second one.
                    let suggestions = model.tagSuggestions(prefix: tagFragment,
                                                           excluding: parsedTags)
                    if !suggestions.isEmpty {
                        Menu("Add existing tag…") {
                            ForEach(suggestions.prefix(20), id: \.self) { tag in
                                Button(tag) { appendTag(tag) }
                            }
                        }
                    }
                }

                Section {
                    HStack {
                        Text("Imbalance")
                        Spacer()
                        Text(AmountFormat.string(imbalance, code: displayCurrency.mnemonic))
                            .monospacedDigit()
                            .foregroundStyle(imbalance == 0 ? Color.secondary : Color.red)
                    }
                    if let commitError {
                        Text(commitError).scaledFont(.caption).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Transaction" : "New Transaction")
            // Esc cancels even while a text field has focus (cancelOperation
            // bubbles up the responder chain; .cancelAction alone doesn't).
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Add") { commit() }
                        .disabled(!isBalanced)
                }
            }
            .onAppear(perform: loadIfNeeded)
            .fileImporter(isPresented: $invoicePickerShown,
                          allowedContentTypes: [.pdf]) { result in
                if case .success(let url) = result { analyzeInvoice(url) }
            }
        }
    }

    /// Reads a linked invoice PDF and replaces the counter-splits with its
    /// categorised line items (`FR-AI-03`). The funding leg keeps its amount
    /// when one exists, so a mismatch with the invoice total shows up in the
    /// imbalance readout instead of being papered over.
    private func analyzeInvoice(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        let data = try? Data(contentsOf: url)
        if scoped { url.stopAccessingSecurityScopedResource() }
        guard let data else { return }
        analyzingInvoice = true
        commitError = nil
        Task {
            defer { analyzingInvoice = false }
            do {
                let analysis = try await model.analyzeInvoicePDF(data)
                applyInvoice(analysis)
            } catch {
                commitError = error.localizedDescription
            }
        }
    }

    private func applyInvoice(_ analysis: InvoiceAnalysis) {
        if description.isEmpty { description = analysis.vendor }
        if !isEditing, let invoiceDate = analysis.date { date = invoiceDate }
        let existing = lines.first
        let fundingAmount = (existing?.amount ?? 0) != 0
            ? existing!.amountText
            : NSDecimalNumber(decimal: -analysis.total).stringValue
        let funding = EditableSplit(accountID: existing?.accountID, amountText: fundingAmount)
        let items = analysis.lineItems.map {
            EditableSplit(accountID: $0.suggestedCategoryID,
                          amountText: NSDecimalNumber(decimal: $0.amount).stringValue)
        }
        guard !items.isEmpty else {
            commitError = "No line items were found in this invoice."
            return
        }
        lines = [funding] + items
    }

    /// The commodity a leg's own amount is denominated in, when it is not the
    /// transaction's currency — "USD" for a foreign account, "BHP" for shares.
    /// `nil` for an ordinary leg, which has one amount and needs one field.
    private func foreignUnit(of line: EditableSplit) -> String? {
        guard let id = line.accountID,
              let node = model.postableAccounts.first(where: { $0.id == id }),
              node.currencyCode != displayCurrency.mnemonic
        else { return nil }
        return node.currencyCode
    }

    /// The exchange rate the two amounts imply, stated so it can be checked
    /// against a statement: "10 BHP @ 40 AUD".
    private func rateDescription(of line: EditableSplit, unit: String) -> String {
        guard let quantity = line.quantity, quantity != 0, line.amount != 0 else {
            return "Amount in \(unit)"
        }
        let rate = line.amount / quantity
        let rounded = NSDecimalNumber(decimal: displayCurrency.round(rate)).stringValue
        return "\(NSDecimalNumber(decimal: quantity).stringValue) \(unit) @ \(rounded) \(displayCurrency.mnemonic)"
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let editingID, let edit = model.editData(forTransaction: editingID) {
            date = edit.date
            description = edit.description
            notes = edit.notes
            lines = edit.splits.map { EditableSplit($0) }
            tagsText = edit.tags.joined(separator: ", ")
        }
        focusSoon { descriptionFocused = true }
    }

    private func applyTemplate(_ suggestion: String) {
        description = suggestion
        if let template = model.template(forDescription: suggestion) {
            lines = template.map { EditableSplit($0) }
        }
    }

    private func commit() {
        let inputs = lines
            .filter { $0.accountID != nil }
            .map(\.asInput)
        let currency = model.transactionCurrency(for: inputs.compactMap(\.accountID))
        do {
            if let editingID {
                try model.updateTransaction(id: editingID, date: date, description: description,
                                            currency: currency, splits: inputs,
                                            tags: parsedTags, notes: notes)
            } else {
                try model.addTransaction(date: date, description: description,
                                         currency: currency, splits: inputs,
                                         tags: parsedTags, notes: notes)
            }
            dismiss()
        } catch {
            // Keep the sheet up — the user's entry must not silently vanish.
            commitError = error.localizedDescription
        }
    }
}

// MARK: - Edit account

struct EditAccountSheet: View {
    @Bindable var model: AppModel
    let accountID: GncGUID
    @Environment(\.dismiss) private var dismiss

    @State private var loaded = false
    @State private var name = ""
    @State private var code = ""
    @State private var description = ""
    @State private var notes = ""
    @State private var isPlaceholder = false
    @State private var isHidden = false
    @State private var hasColor = false
    @State private var color: Color = .accentColor
    @State private var parentID: GncGUID?
    @State private var originalParentID: GncGUID?
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                    .focused($nameFocused)
                TextField("Code", text: $code)
                TextField("Description", text: $description)
                TextField("Notes", text: $notes, axis: .vertical)
                Picker("Parent", selection: $parentID) {
                    Text("Top level").tag(GncGUID?.none)
                    ForEach(model.validParents(forAccount: accountID)) { node in
                        Text(node.fullName).tag(GncGUID?.some(node.id))
                    }
                }
                Toggle("Placeholder", isOn: $isPlaceholder)
                Toggle("Hidden", isOn: $isHidden)

                // GnuCash account colour — shown as a dot in the sidebar.
                Toggle("Colour", isOn: $hasColor.animation())
                if hasColor {
                    ColorPicker("Account colour", selection: $color, supportsOpacity: false)
                }

                Section {
                    Button("Renumber Sub-Accounts") {
                        model.renumberChildren(of: accountID)
                    }
                } footer: {
                    Text("Assigns sequential codes (010, 020, …) to this account's children.")
                }
            }
            .navigationTitle("Edit Account")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.updateAccount(id: accountID, name: name, code: code,
                                            description: description, notes: notes,
                                            isPlaceholder: isPlaceholder, isHidden: isHidden)
                        model.setAccountColor(accountID,
                                              colorString: hasColor ? GnuCashColor.gnuCashString(from: color) : nil)
                        if parentID != originalParentID {
                            model.moveAccount(accountID, under: parentID)
                        }
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if !loaded, let edit = model.editData(forAccount: accountID) {
                    loaded = true
                    name = edit.name; code = edit.code; description = edit.description
                    notes = edit.notes; isPlaceholder = edit.isPlaceholder; isHidden = edit.isHidden
                    if let existing = model.accountColor(accountID).flatMap(GnuCashColor.color(from:)) {
                        hasColor = true
                        color = existing
                    }
                    parentID = model.parentID(ofAccount: accountID)
                    originalParentID = parentID
                }
                focusSoon { nameFocused = true }
            }
        }
    }
}
