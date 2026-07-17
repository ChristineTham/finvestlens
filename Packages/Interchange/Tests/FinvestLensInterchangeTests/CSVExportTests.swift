//
//  CSVExportTests.swift
//  FinvestLens — Interchange
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Testing
import Foundation
import FinvestLensEngine
@testable import FinvestLensInterchange

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

struct CSVExportTests {

    private func makeBook() -> Book {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let salary = book.addAccount(Account(name: "Salary", type: .income, commodity: .aud))
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let txn = Transaction(currency: .aud, datePosted: day, description: "Pay, incl. \"bonus\"")
        txn.addSplit(account: bank, value: dec("100.00"))
        txn.addSplit(account: salary, value: dec("-100.00"))
        book.addTransaction(txn)
        let stock = Commodity(namespace: .security("ASX"), mnemonic: "CBA",
                              fullName: "Commonwealth Bank", smallestFraction: 10000)
        book.addPrice(Price(commodity: stock, currency: .aud, date: day, value: dec("105.20")))
        return book
    }

    @Test("Account export lists non-root accounts with full names")
    func accountsExport() {
        let csv = CSVExporter.accounts(makeBook())
        let lines = csv.split(separator: "\n").map(String.init)
        #expect(lines.first?.hasPrefix("Type,Full Account Name,Account Name") == true)
        #expect(lines.contains { $0.contains("Bank") })
        #expect(lines.contains { $0.contains("Salary") })
        // Root account is excluded.
        #expect(!lines.dropFirst().contains { $0.hasPrefix("ROOT") || $0.hasPrefix("root") })
    }

    @Test("Transaction export writes one row per split and quotes special chars")
    func transactionsExport() {
        let csv = CSVExporter.transactions(makeBook())
        let lines = csv.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)   // header + 2 splits
        // The description has a comma and a quote → must be RFC-4180 quoted.
        #expect(csv.contains("\"Pay, incl. \"\"bonus\"\"\""))
        #expect(csv.contains("100.00"))
        #expect(csv.contains("-100.00"))
    }

    @Test("Price export lists the price DB")
    func pricesExport() {
        let csv = CSVExporter.prices(makeBook())
        #expect(csv.contains("Date,Namespace,Commodity,Currency,Price"))
        #expect(csv.contains("CBA"))
        #expect(csv.contains("105.20"))
    }

    @Test("CSV price import round-trips the price export")
    func priceImportRoundTrip() {
        let csv = CSVExporter.prices(makeBook())
        let staged = CSVPriceImporter.parse(csv, mapping:
            CSVPriceColumnMapping(date: 0, commodity: 2, price: 4, currency: 3))
        #expect(staged.count == 1)
        #expect(staged.first?.commoditySymbol == "CBA")
        #expect(staged.first?.currencyCode == "AUD")
        #expect(staged.first?.value == dec("105.20"))
    }

    @Test("CSV price import skips malformed / non-positive rows")
    func priceImportSkipsBadRows() {
        let csv = """
        Date,Symbol,Price
        2024-01-02,CBA,105.20
        not-a-date,CBA,1.00
        2024-01-03,,2.00
        2024-01-04,CBA,0
        """
        let staged = CSVPriceImporter.parse(csv, mapping:
            CSVPriceColumnMapping(date: 0, commodity: 1, price: 2))
        #expect(staged.count == 1)
        #expect(staged.first?.value == dec("105.20"))
    }
}
