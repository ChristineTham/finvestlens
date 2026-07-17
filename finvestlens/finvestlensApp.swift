//
//  finvestlensApp.swift
//  finvestlens
//
//  Created by Chris Tham on 12/7/2026.
//
//  This file is part of FinvestLens.
//
//  Copyright (C) 2026 Christine Tham
//
//  FinvestLens is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  FinvestLens is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with FinvestLens.  If not, see <https://www.gnu.org/licenses/>.
//

import SwiftUI
import FinvestLensUI

#if os(macOS)
import AppKit

/// Saves the open book (and releases its lock) on quit, so ⌘Q never loses
/// data and never leaves a stale lock behind. If the save fails, quitting is
/// cancelled so the error alert is seen instead of the data being lost.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var terminationHandler: (() -> Bool)?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        (terminationHandler?() ?? true) ? .terminateNow : .terminateCancel
    }
}
#endif

@main
struct finvestlensApp: App {
    @State private var model = AppModel()
    @Environment(\.openWindow) private var openWindow
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            RootHost(model: model)
                .onOpenURL { url in
                    // Opened from Finder / another app via the .finvestlens type.
                    guard url.pathExtension == "finvestlens" else { return }
                    Task { await model.openBook(at: url) }
                }
                .finvestLensAppearance()
                // Ask once for permission to deliver bill/alert notifications
                // (FR-PLAN-05). The system prompts only on first launch; later
                // syncs are no-ops until granted.
                .task { await AlertNotificationScheduler.requestAuthorization() }
            #if os(macOS)
                // Save the open book (and release its lock) on ⌘Q, so quitting
                // never loses data. Wired here because the adaptor instance —
                // not NSApp.delegate, which is SwiftUI's proxy — is the real
                // delegate object.
                .onAppear {
                    appDelegate.terminationHandler = { [weak model] in
                        model?.saveAndCloseIfOpen() ?? true
                    }
                }
            #endif
        }
        .commands {
            #if os(macOS)
            // File ▸ New/Open/Open Recent (replaces the stock New Window item).
            CommandGroup(replacing: .newItem) {
                Button("New Book…") { DocumentDialogs.newBook(model) }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Open…") { Task { await DocumentDialogs.openBook(model) } }
                    .keyboardShortcut("o", modifiers: .command)
                Menu("Open Recent") {
                    ForEach(model.recentBooks, id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent) {
                            Task { await model.openBook(at: url) }
                        }
                    }
                    if model.recentBooks.isEmpty {
                        Text("No recent books")
                    }
                }
            }
            #endif
            // Anchored after .newItem, NOT .saveItem: a plain WindowGroup scene
            // has no standard Save item, and a CommandGroup anchored to a
            // missing item is silently dropped from the menu bar.
            CommandGroup(after: .newItem) {
                Button("Save") { try? model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.hasUnsavedChanges)
                Button("Revert to Saved") { try? model.revert() }
                    .disabled(!model.isOpen || !model.hasUnsavedChanges)
                Divider()
                #if os(macOS)
                Button("Import GnuCash…") { DocumentDialogs.importGnuCash(model) }
                #endif
                Button("Export GnuCash…") { model.exportRequested = true }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(!model.isOpen)
                Divider()
                Button("Close Book") { model.saveAndCloseIfOpen() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(!model.isOpen)
            }
            // Find sits in Edit, under Cut/Copy/Paste, where GnuCash puts it
            // (Edit ▸ Find…, ⌘F) and where macOS users look for it.
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Find…") { model.presentedPanel = .find }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(!model.isOpen)
                Button("Find Account…") { model.presentedPanel = .findAccount }
                    .keyboardShortcut("i", modifiers: .command)
                    .disabled(!model.isOpen)
                Button("Clear Find") { model.clearFind() }
                    .disabled(model.findQuery == nil)
                Divider()
                Button("Tax Report Options…") { model.presentedPanel = .taxOptions }
                    .disabled(!model.isOpen)
            }
            // Transaction: what you can do to the selected register row.
            //
            // These were context-menu-only — no menu items, no shortcuts, and
            // in the Journal and General Ledger styles no way to reach them at
            // all. `TransactionActions` is the same view the context menus use,
            // so the menu bar cannot drift out of step with them.
            CommandMenu("Transaction") {
                TransactionActions(model: model, splitID: model.selectedSplitID)
                    .disabled(!model.isOpen)
            }
            // Book: every tool panel, so all functionality is reachable (and
            // discoverable, with shortcuts) from the menu bar.
            CommandMenu("Book") {
                Button("New Transaction…") { model.presentedPanel = .newTransaction }
                    .keyboardShortcut("t", modifiers: .command)
                    .disabled(!model.isOpen || model.postableAccounts.count < 2)
                Button("New Account…") { model.presentedPanel = .newAccount }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(!model.isOpen)
                Button("Stock Transaction…") { model.presentedPanel = .stockTransaction }
                    .disabled(!model.isOpen || model.securityAccountNodes.isEmpty)
                Button("Currency Transfer…") { model.presentedPanel = .currencyTransfer }
                    .disabled(!model.isOpen || model.currencyCommodities.count < 2)
                Divider()
                // ⌥⌘I: plain ⌘I is Find Account, which is what GnuCash puts
                // there — a lookup you do many times a session outranks an
                // import you do once a statement.
                Button("Import Bank File…") { model.bankImportRequested = true }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                    .disabled(!model.isOpen)
                Button("Reconcile Account…") { model.presentedPanel = .reconcile }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!model.isOpen || model.selectedAccountID == nil)
                Divider()
                // Inline, in the detail pane, like the dashboard — a detached
                // window only when asked for (docs/reports.md).
                Button("Reports…") {
                    #if os(macOS)
                    model.isShowingReports = true
                    #else
                    model.presentedPanel = .reports
                    #endif
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!model.isOpen)
                #if os(macOS)
                // No shortcut: ⇧⌘R is Reconcile's. A window you open once per
                // arrangement of monitors does not need a chord.
                Button("Reports in New Window") { openWindow(id: "reports") }
                    .disabled(!model.isOpen)
                #endif
                Button("Budget…") { model.presentedPanel = .budget }
                    .keyboardShortcut("b", modifiers: .command)
                    .disabled(!model.isOpen)
                Button("Rules…") { model.presentedPanel = .rules }
                    .disabled(!model.isOpen)
                Button("Scheduled Transactions…") { model.presentedPanel = .scheduled }
                    .disabled(!model.isOpen)
                Button("Prices & Quotes…") { model.presentedPanel = .prices }
                    .disabled(!model.isOpen)
                Button("Linked Documents…") { model.presentedPanel = .linkedDocuments }
                    .disabled(!model.isOpen)
                Button("Loan Calculator…") { model.presentedPanel = .loanCalculator }
                    .disabled(!model.isOpen)
                Button("Check & Repair…") { model.checkAndRepair() }
                    .disabled(!model.isOpen)
                Button("Period-End Close…") { model.presentedPanel = .closeBook }
                    .disabled(!model.isOpen)
                Divider()
                // Apple Intelligence features — disabled (with the reason as
                // a tooltip) when the on-device model isn't available.
                Button("Smart Import PDFs…") { model.smartImportRequested = true }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(!model.isOpen || !model.isIntelligenceAvailable)
                    .help(model.intelligenceUnavailableReason
                          ?? "Import bank statements, dividend statements, and invoices — each PDF is identified and handled automatically")
                Button("Auto-Categorise Transactions…") { model.presentedPanel = .autoCategorize }
                    .disabled(!model.isOpen)
                Divider()
                Button("Dashboard") { model.selectedAccountID = nil }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(!model.isOpen)
            }
            CommandMenu("Business") {
                Button("Customers, Vendors & Invoices…") { model.presentedPanel = .business }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                    .disabled(!model.isOpen)
                Divider()
                Button("Receivable Aging Report…") { model.openReceivableAging() }
                    .disabled(!model.isOpen)
                Button("Payable Aging Report…") { model.openPayableAging() }
                    .disabled(!model.isOpen)
            }
            CommandMenu("Security") {
                Button(model.requireAuthentication
                       ? "Don’t Require Authentication"
                       : "Require Authentication to Open") {
                    model.requireAuthentication.toggle()
                }
                .disabled(!model.isOpen)
                Button("Lock Now") { model.lockNow() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(!model.isOpen || model.isLocked)
            }
        }

        #if os(macOS)
        // Reports get their own window (HIG: workspaces aren't sheets).
        WindowGroup("Reports", id: "reports") {
            ReportsWindow(model: model)
                .finvestLensAppearance()
        }
        .defaultSize(width: 760, height: 560)

        Settings {
            FinvestLensSettingsView()
                .finvestLensAppearance()
        }
        #endif
    }
}
