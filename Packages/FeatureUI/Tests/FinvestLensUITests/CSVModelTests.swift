//
//  CSVModelTests.swift
//  FinvestLens — FeatureUI
//
//  CSV export of the open book (FR-XIO-06) and saved import profiles
//  (FR-XIO-08) through the app model.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
}

@MainActor
@Suite("CSV export (FR-XIO-06)")
struct CSVExportModelTests {

    @Test("The accounts export carries the GnuCash tree columns, tax flag included")
    func accountsExport() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let deductions = try #require(model.addAccount(name: "Work Deductions", type: .expense))
        model.setAccountTax(id: deductions, related: true, code: "N123")
        _ = bank

        let csv = model.csvExport(.accounts)
        let lines = csv.split(separator: "\n").map(String.init)
        #expect(lines.first == "Type,Full Account Name,Account Name,Account Code,"
                + "Description,Account Color,Notes,Symbol,Namespace,Hidden,Tax Info,Placeholder")

        let bankRow = try #require(lines.first { $0.hasPrefix("BANK,Bank,") })
        #expect(bankRow == "BANK,Bank,Bank,,,,,AUD,CURRENCY,F,F,F")
        let taxRow = try #require(lines.first { $0.hasPrefix("EXPENSE,Work Deductions,") })
        #expect(taxRow == "EXPENSE,Work Deductions,Work Deductions,,,,,AUD,CURRENCY,F,T,F")
        // The root account is never exported.
        #expect(!csv.contains("ROOT"))
    }

    @Test("The transactions export writes one row per split with GnuCash's full layout")
    func transactionsExport() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let groceries = try #require(model.addAccount(name: "Groceries", type: .expense))
        // 2026-03-15T00:00:00Z; the description needs RFC-4180 quoting.
        let posted = Date(timeIntervalSince1970: 1_773_532_800)
        let txn = try model.addTransaction(date: posted, description: "Woolworths, Sydney",
                                           currency: .aud, splits: [
            SplitInput(accountID: bank, value: dec("-52.30"), memo: "card 1234"),
            SplitInput(accountID: groceries, value: dec("52.30"))])

        let csv = model.csvExport(.transactions)
        let lines = csv.split(separator: "\n").map(String.init)
        #expect(lines.first == "Date,Transaction ID,Number,Description,Notes,"
                + "Commodity/Currency,Action,Memo,Full Account Name,"
                + "Amount Num.,Value Num.,Reconcile,Reconcile Date,Rate/Price")
        #expect(lines.count == 3)                                  // header + two splits

        let guid = txn.hexString
        let bankRow = try #require(lines.first { $0.contains(",Bank,") })
        #expect(bankRow == "2026-03-15,\(guid),,\"Woolworths, Sydney\",,CURRENCY::AUD,"
                + ",card 1234,Bank,-52.30,-52.30,n,,")
        let groceriesRow = try #require(lines.first { $0.contains(",Groceries,") })
        #expect(groceriesRow == "2026-03-15,\(guid),,\"Woolworths, Sydney\",,CURRENCY::AUD,"
                + ",,Groceries,52.30,52.30,n,,")
    }

    @Test("A security split carries its share quantity and the Rate/Price column")
    func transactionsExportRate() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let bank = try #require(model.addAccount(name: "Bank", type: .bank))
        let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                            fullName: "Commonwealth Bank", smallestFraction: 10000)
        let shares = try #require(model.addAccount(name: "CBA", type: .stock, commodity: cba))
        try model.addTransaction(date: Date(timeIntervalSince1970: 1_773_532_800),
                                 description: "Buy CBA", currency: .aud, splits: [
            SplitInput(accountID: shares, value: dec("1000"), quantity: dec("8"), action: "Buy"),
            SplitInput(accountID: bank, value: dec("-1000"))])

        let csv = model.csvExport(.transactions)
        let sharesRow = try #require(csv.split(separator: "\n").map(String.init)
            .first { $0.contains(",CBA,") })
        // Amount = 8 shares, value = $1000, rate = 1000 / 8 = 125.
        #expect(sharesRow.contains(",Buy,,CBA,8.00,1000.00,n,,125.00"))
    }

    @Test("The prices export lists the price database, sorted by date")
    func pricesExport() throws {
        let url = tempURL()
        let model = AppModel()
        try model.newDocument(at: url)
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        let cba = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                            fullName: "Commonwealth Bank", smallestFraction: 10000)
        _ = try #require(model.addAccount(name: "CBA", type: .stock, commodity: cba))
        model.addPrice(commodity: cba, currency: .aud,
                       date: Date(timeIntervalSince1970: 1_773_532_800), value: dec("45.12"))
        model.addPrice(commodity: cba, currency: .aud,
                       date: Date(timeIntervalSince1970: 1_773_532_800 - 86_400), value: dec("44"))

        let lines = model.csvExport(.prices).split(separator: "\n").map(String.init)
        #expect(lines.first == "Date,Namespace,Commodity,Currency,Price,Source,Type")
        #expect(lines.count == 3)
        #expect(lines[1] == "2026-03-14,ASX,CBA,AUD,44.00,user:price,last")
        #expect(lines[2] == "2026-03-15,ASX,CBA,AUD,45.12,user:price,last")
    }

    @Test("With no open book every export is empty; kinds name their menus and files")
    func noBookAndMetadata() {
        let model = AppModel()
        for kind in CSVExportKind.allCases {
            #expect(model.csvExport(kind).isEmpty)
        }
        #expect(CSVExportKind.accounts.menuTitle == "Accounts…")
        #expect(CSVExportKind.transactions.menuTitle == "Transactions…")
        #expect(CSVExportKind.prices.menuTitle == "Prices…")
        #expect(CSVExportKind.transactions.filename(book: "Ashley") == "Ashley Transactions")
        #expect(CSVExportKind.prices.id == "prices")
    }
}

@MainActor
@Suite("CSV import profiles (FR-XIO-08)", .serialized)
struct CSVImportProfileTests {

    private static let defaultsKey = "finvestlens.csvImportProfiles"

    @Test("Profiles save, replace by name, sort, and delete")
    func profileCRUD() {
        let model = AppModel()
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: Self.defaultsKey) }
        #expect(model.csvImportProfiles.isEmpty)

        let anz = CSVImportProfile(name: "ANZ", dateColumn: 0, amountColumn: 1,
                                   payeeColumn: 2, dateFormat: "dd/MM/yyyy", hasHeader: true)
        let west = CSVImportProfile(name: "Westpac", dateColumn: 1, amountColumn: 3,
                                    payeeColumn: 2, dateFormat: "yyyy-MM-dd", hasHeader: false)
        model.saveCSVImportProfile(west)
        model.saveCSVImportProfile(anz)
        #expect(model.csvImportProfiles.map(\.name) == ["ANZ", "Westpac"])   // sorted

        // Saving under the same name (case-insensitively) replaces, not duplicates.
        let anz2 = CSVImportProfile(name: "anz", dateColumn: 4, amountColumn: 5,
                                    payeeColumn: 6, dateFormat: "MM/dd/yyyy", hasHeader: false)
        model.saveCSVImportProfile(anz2)
        #expect(model.csvImportProfiles.count == 2)
        let reloaded = model.csvImportProfiles.first { $0.name == "anz" }
        #expect(reloaded?.dateColumn == 4)
        #expect(reloaded?.dateFormat == "MM/dd/yyyy")

        // Profiles are app-wide desk state: a second model sees them too.
        let other = AppModel()
        #expect(other.csvImportProfiles.count == 2)

        model.deleteCSVImportProfile(anz2.id)
        #expect(model.csvImportProfiles.map(\.name) == ["Westpac"])
        model.deleteCSVImportProfile(west.id)
        #expect(model.csvImportProfiles.isEmpty)
    }
}
