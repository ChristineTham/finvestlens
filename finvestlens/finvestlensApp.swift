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

@main
struct finvestlensApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootHost(model: model)
                .onOpenURL { url in
                    // Opened from Finder / another app via the .finvestlens type.
                    guard url.pathExtension == "finvestlens" else { return }
                    model.openBook(at: url)
                }
                .finvestLensAppearance()
        }
        .commands {
            #if os(macOS)
            // File ▸ New/Open/Open Recent (replaces the stock New Window item).
            CommandGroup(replacing: .newItem) {
                Button("New Book…") { DocumentDialogs.newBook(model) }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Open…") { DocumentDialogs.openBook(model) }
                    .keyboardShortcut("o", modifiers: .command)
                Menu("Open Recent") {
                    ForEach(model.recentBooks, id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent) {
                            model.openBook(at: url)
                        }
                    }
                    if model.recentBooks.isEmpty {
                        Text("No recent books")
                    }
                }
            }
            #endif
            CommandGroup(after: .saveItem) {
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
                Button("Import Bank File…") { model.bankImportRequested = true }
                    .keyboardShortcut("i", modifiers: .command)
                    .disabled(!model.isOpen)
                Button("Reconcile Account…") { model.presentedPanel = .reconcile }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!model.isOpen || model.selectedAccountID == nil)
                Divider()
                Button("Reports…") { model.presentedPanel = .reports }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!model.isOpen)
                Button("Budget…") { model.presentedPanel = .budget }
                    .keyboardShortcut("b", modifiers: .command)
                    .disabled(!model.isOpen)
                Button("Rules…") { model.presentedPanel = .rules }
                    .disabled(!model.isOpen)
                Button("Scheduled Transactions…") { model.presentedPanel = .scheduled }
                    .disabled(!model.isOpen)
                Button("Prices & Quotes…") { model.presentedPanel = .prices }
                    .disabled(!model.isOpen)
                Divider()
                Button("Dashboard") { model.selectedAccountID = nil }
                    .keyboardShortcut("d", modifiers: .command)
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
        Settings {
            AppearanceSettingsView()
                .finvestLensAppearance()
        }
        #endif
    }
}
