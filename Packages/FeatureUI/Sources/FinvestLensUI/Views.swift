//
//  Views.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import UniformTypeIdentifiers
import FinvestLensEngine
import FinvestLensIntelligence
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

// MARK: - Formatting

enum AmountFormat {
    static func string(_ value: Decimal, code: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        return formatter.string(from: NSDecimalNumber(decimal: value))
            ?? "\(value) \(code)"
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
public struct OpeningBookView: View {
    let url: URL
    @Environment(\.appFontScale) private var appFontScale

    public init(url: URL) { self.url = url }

    public var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Opening \(url.deletingPathExtension().lastPathComponent)…")
                .scaledFont(.title3, weight: .semibold)
            Text("Reading accounts, transactions and prices.")
                .foregroundStyle(.secondary)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Opening \(url.deletingPathExtension().lastPathComponent)")
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
    @State private var importPayload: ImportPayload?
    @State private var offeredOnboarding = false
    @State private var smartPayload: SmartImportPayload?
    @State private var statementProgress: (done: Int, total: Int)?
    @State private var statementError: String?

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            AccountsSidebar(model: model)
                .navigationTitle("Accounts")
        } detail: {
            if model.isSearching {
                SearchResultsView(model: model)
            } else if model.selectedAccountID == nil {
                DashboardView(model: model)
            } else {
                RegisterView(model: model)
            }
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
                    model.presentedPanel = .reports
                    #endif
                }
                .help("Reports (⌘R)")
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
                        model.presentedPanel = .rules
                    }
                    Button("Scheduled…", systemImage: "calendar.badge.clock") {
                        model.presentedPanel = .scheduled
                    }
                    Button("Budget…", systemImage: "chart.bar.doc.horizontal") {
                        model.presentedPanel = .budget
                    }
                    Button("Prices & Quotes…", systemImage: "tag") {
                        model.presentedPanel = .prices
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
            case .reports: ReportsView(model: model)
            case .rules: RulesView(model: model)
            case .scheduled: ScheduledView(model: model)
            case .budget: BudgetView(model: model)
            case .prices: PricesView(model: model)
            case .saveSearch: SaveSearchSheet(model: model)
            case .onboarding: OnboardingSheet(model: model)
            case .reconcile:
                if let id = model.selectedAccountID {
                    ReconcileView(model: model, accountID: id)
                }
            case .autoCategorize: AutoCategorizeSheet(model: model)
            case .find: FindSheet(model: model)
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

    var id: String {
        switch self {
        case .edit(let guid): return "edit-\(guid.hexString)"
        case .reconcile(let guid): return "rec-\(guid.hexString)"
        }
    }
}

struct AccountsSidebar: View {
    @Bindable var model: AppModel
    @State private var sheet: AccountSheet?
    @Environment(\.appFontScale) private var appFontScale

    var body: some View {
        List(selection: $model.selectedAccountID) {
            OutlineGroup(model.accountTree, children: \.children) { node in
                HStack {
                    // GnuCash account colour, shown Finder-tag style.
                    if let dot = node.color.flatMap(GnuCashColor.color(from:)) {
                        Circle()
                            .fill(dot)
                            .frame(width: 9, height: 9)
                            .accessibilityHidden(true)
                    }
                    Text(node.name)
                        .scaledFont(.body)
                        .foregroundStyle(node.isHidden ? .secondary : .primary)
                    Spacer()
                    Text(AmountFormat.string(node.balance, code: node.currencyCode))
                        .scaledFont(.body)
                        .monospacedDigit()
                        .foregroundStyle(node.balance < 0 ? .red : .secondary)
                }
                .tag(node.id)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(node.name)
                .accessibilityValue(AmountFormat.string(node.balance, code: node.currencyCode))
                .contextMenu {
                    Button("Edit…") { sheet = .edit(node.id) }
                    Button("Reconcile…") { sheet = .reconcile(node.id) }
                    if model.canDeleteAccount(node.id) {
                        Button("Delete", role: .destructive) { model.deleteAccount(node.id) }
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 200 * appFontScale,
                                        ideal: 240 * appFontScale,
                                        max: 400 * appFontScale)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .edit(let id): EditAccountSheet(model: model, accountID: id)
            case .reconcile(let id): ReconcileView(model: model, accountID: id)
            }
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
                    sortMenu
                    filterButton
                }
            }
            .padding(6)
            Divider()
            content
        }
        .navigationTitle(style == .generalLedger ? "General Ledger" : selectedName)
        .background { jumpShortcuts }
        .sheet(isPresented: $filterShown) {
            RegisterFilterSheet(model: model)
        }
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

    private var registerTableBody: some View {
        Table(model.registerRows, selection: $selection) {
            TableColumn("Date") { row in
                Text(row.date, format: .dateTime.year().month().day())
                    .scaledFont(.body)
            }
            TableColumn("Description") { row in
                Text(row.description).scaledFont(.body)
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
            TableColumn("Amount") { row in
                Text(AmountFormat.string(row.amount, code: currencyCode))
                    .scaledFont(.body)
                    .monospacedDigit()
                    .foregroundStyle(row.amount < 0 ? .red : .primary)
            }
            TableColumn("Balance") { row in
                Text(AmountFormat.string(row.runningBalance, code: currencyCode))
                    .scaledFont(.body)
                    .monospacedDigit()
            }
        }
        .contextMenu(forSelectionType: GncGUID.self) { ids in
            if let splitID = ids.first, let txnID = model.transactionID(ofSplit: splitID) {
                Button("Edit…") { editingTransactionID = txnID }
                Button("Go to Other Account") { model.jumpToOtherAccount(ofSplit: splitID) }
                if model.hasLinkedDocument(txnID) {
                    Button("Open Linked Document", systemImage: "paperclip") {
                        model.openLinkedDocument(for: txnID)
                    }
                }
                Divider()
                Button("Duplicate") { model.duplicateTransaction(txnID) }
                Button("Add Reversing Transaction") { _ = model.addReversingTransaction(txnID) }
                if model.isVoided(txnID) {
                    Button("Unvoid") { model.unvoidTransaction(txnID) }
                } else {
                    Button("Void") { model.voidTransaction(txnID) }
                }
                Divider()
                Button("Delete", role: .destructive) { model.deleteTransaction(txnID) }
            }
        }
        .sheet(item: $editingTransactionID) { id in
            TransactionEditorSheet(model: model, editingID: id)
        }
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
    @State private var selection: Set<GncGUID> = []
    @Environment(\.appFontScale) private var appFontScale

    var body: some View {
        let rows = model.journalRows(forAccountID: accountID)
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
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                Button("Edit…") { editingTransactionID = row.transactionID }
            }
        }
        .sheet(item: $editingTransactionID) { id in
            TransactionEditorSheet(model: model, editingID: id)
        }
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
        // Find opens its results as a register.
        .contextMenu(forSelectionType: GncGUID.self) { ids in
            if let id = ids.first {
                Button("Edit…") { editingTransactionID = id }
                Button("Show in Register") { model.showInRegister(id) }
            }
        } primaryAction: { ids in
            if let id = ids.first { editingTransactionID = id }
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
    var accountID: GncGUID?
    var amountText: String = ""

    /// The split's amount in its **own** commodity — a share count for a
    /// security, the foreign amount for an FX leg — when it differs from the
    /// value. `nil` means "same as the value", which is right for a plain
    /// cash posting and lets editing the amount carry the quantity with it.
    ///
    /// The sheet has no field for this; it is carried through untouched. It
    /// must be: the editor rebuilds every split on save, so dropping it reset
    /// share counts to the dollar value and silently destroyed a holding.
    var quantity: Decimal?

    /// Per-split memo, likewise carried through so an edit cannot erase it.
    var memo: String = ""

    var amount: Decimal { Decimal(string: amountText) ?? 0 }

    init(accountID: GncGUID? = nil, amountText: String = "") {
        self.accountID = accountID
        self.amountText = amountText
    }

    init(_ input: SplitInput) {
        self.accountID = input.accountID
        self.amountText = NSDecimalNumber(decimal: input.value).stringValue
        self.quantity = input.quantity
        self.memo = input.memo
    }

    /// The row as the engine takes it. Everything the editor knows about a
    /// split has to come back out here, including the parts it never showed.
    var asInput: SplitInput {
        SplitInput(accountID: accountID, value: amount, quantity: quantity, memo: memo)
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

    private var imbalance: Decimal { lines.reduce(Decimal(0)) { $0 + $1.amount } }
    /// Currency of the transaction being built (first cash account's, else base).
    private var displayCurrency: Commodity {
        model.transactionCurrency(for: lines.compactMap(\.accountID))
    }
    private var validLineCount: Int { lines.filter { $0.accountID != nil }.count }
    private var isBalanced: Bool { imbalance == 0 && validLineCount >= 2 }
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

                Section("Splits") {
                    ForEach($lines) { $line in
                        HStack {
                            Picker("Account", selection: $line.accountID) {
                                Text("—").tag(GncGUID?.none)
                                ForEach(model.postableAccounts) { node in
                                    Text(node.fullName).tag(GncGUID?.some(node.id))
                                }
                            }
                            .labelsHidden()
                            TextField("Amount", text: $line.amountText)
                                .multilineTextAlignment(.trailing)
                                .frame(width: amountWidth)
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

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let editingID, let edit = model.editData(forTransaction: editingID) {
            date = edit.date
            description = edit.description
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
                                            currency: currency, splits: inputs, tags: parsedTags)
            } else {
                try model.addTransaction(date: date, description: description,
                                         currency: currency, splits: inputs, tags: parsedTags)
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
