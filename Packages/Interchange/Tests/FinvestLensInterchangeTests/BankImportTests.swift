//
//  BankImportTests.swift
//  FinvestLens — Interchange
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensInterchange

private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
    var c = DateComponents(); c.year = y; c.month = m; c.day = d
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    return cal.date(from: c)!
}

@Suite("CSV import")
struct CSVImportTests {

    @Test("Parses a signed-amount CSV with a header")
    func signedAmount() {
        let csv = """
        Date,Description,Amount
        2026-01-15,Woolworths,-52.30
        2026-01-16,"Salary, Employer Pty",1000.00
        """
        let mapping = CSVColumnMapping(date: 0, amount: 2, payee: 1, dateFormat: "yyyy-MM-dd")
        let rows = CSVTransactionImporter.parse(csv, mapping: mapping)
        #expect(rows.count == 2)
        #expect(rows[0].amount == Decimal(string: "-52.30"))
        #expect(rows[0].payee == "Woolworths")
        #expect(rows[1].payee == "Salary, Employer Pty")   // quoted comma preserved
        #expect(rows[1].amount == Decimal(1000))
    }

    @Test("Parses separate debit/credit columns")
    func debitCredit() {
        let csv = """
        15/01/2026,Rent,800.00,
        16/01/2026,Refund,,25.00
        """
        let mapping = CSVColumnMapping(date: 0, debit: 2, credit: 3, payee: 1,
                                       dateFormat: "dd/MM/yyyy", hasHeader: false)
        let rows = CSVTransactionImporter.parse(csv, mapping: mapping)
        #expect(rows[0].amount == Decimal(-800))           // debit → money out
        #expect(rows[1].amount == Decimal(25))             // credit → money in
    }
}

@Suite("QIF import")
struct QIFImportTests {

    @Test("Parses a bank QIF")
    func bankQIF() {
        let qif = """
        !Type:Bank
        D01/15/2026
        T-52.30
        PWoolworths
        MGroceries
        NCARD
        LExpenses:Groceries
        ^
        D01/16/2026
        T1,000.00
        PEmployer
        ^
        """
        let rows = QIFImporter.parse(qif)
        #expect(rows.count == 2)
        #expect(rows[0].payee == "Woolworths")
        #expect(rows[0].amount == Decimal(string: "-52.30"))
        #expect(rows[0].category == "Expenses:Groceries")
        #expect(rows[1].amount == Decimal(1000))
    }

    @Test("Handles apostrophe-year dates")
    func apostropheYear() {
        let rows = QIFImporter.parse("D01/15'26\nT-10.00\nPShop\n^")
        #expect(rows.count == 1)
    }
}

@Suite("OFX import")
struct OFXImportTests {

    @Test("Parses OFX v1 (SGML, unclosed tags)")
    func ofxV1() {
        let ofx = """
        OFXHEADER:100
        DATA:OFXSGML

        <OFX><BANKMSGSRSV1><STMTTRNRS><STMTRS><BANKTRANLIST>
        <STMTTRN>
        <TRNTYPE>DEBIT
        <DTPOSTED>20260115120000
        <TRNAMT>-52.30
        <FITID>ABC123
        <NAME>Woolworths
        </STMTTRN>
        <STMTTRN>
        <TRNTYPE>CREDIT
        <DTPOSTED>20260116
        <TRNAMT>1000.00
        <FITID>ABC124
        <NAME>Employer
        </STMTTRN>
        </BANKTRANLIST></STMTRS></STMTTRNRS></BANKMSGSRSV1></OFX>
        """
        let rows = OFXImporter.parse(ofx)
        #expect(rows.count == 2)
        #expect(rows[0].payee == "Woolworths")
        #expect(rows[0].amount == Decimal(string: "-52.30"))
        #expect(rows[0].reference == "ABC123")
        #expect(rows[1].amount == Decimal(1000))
    }

    @Test("Parses OFX v2 (XML, closed tags)")
    func ofxV2() {
        let ofx = """
        <?xml version="1.0"?>
        <OFX><BANKMSGSRSV1><STMTTRNRS><STMTRS><BANKTRANLIST>
          <STMTTRN>
            <TRNTYPE>DEBIT</TRNTYPE>
            <DTPOSTED>20260115</DTPOSTED>
            <TRNAMT>-52.30</TRNAMT>
            <FITID>X1</FITID>
            <NAME>Cafe</NAME>
          </STMTTRN>
        </BANKTRANLIST></STMTRS></STMTTRNRS></BANKMSGSRSV1></OFX>
        """
        let rows = OFXImporter.parse(ofx)
        #expect(rows.count == 1)
        #expect(rows[0].payee == "Cafe")
        #expect(rows[0].amount == Decimal(string: "-52.30"))
    }
}

@Suite("Import matcher")
struct ImportMatcherTests {

    /// Bank with an existing "Woolworths" expense so history can suggest.
    private func makeBook() -> (Book, bank: Account, groceries: Account) {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let groceries = book.addAccount(Account(name: "Groceries", type: .expense, commodity: .aud))
        let txn = Transaction(currency: .aud, datePosted: day(2026, 1, 15), description: "Woolworths")
        txn.addSplit(account: groceries, value: Decimal(string: "52.30")!)
        txn.addSplit(account: bank, value: Decimal(string: "-52.30")!)
        book.addTransaction(txn)
        return (book, bank, groceries)
    }

    @Test("Flags duplicates and suggests from history")
    func matching() {
        let (book, bank, groceries) = makeBook()
        let staged = [
            // Same amount/payee, same day → duplicate; suggests Groceries.
            StagedTransaction(date: day(2026, 1, 15), amount: Decimal(string: "-52.30")!, payee: "Woolworths"),
            // New transaction → not a duplicate; no history for this payee.
            StagedTransaction(date: day(2026, 2, 1), amount: Decimal(string: "-19.99")!, payee: "Netflix"),
        ]
        let results = ImportMatcher.match(staged, into: bank, book: book)

        #expect(results[0].isDuplicate)
        #expect(results[0].suggestedAccountID == groceries.guid)
        #expect(!results[1].isDuplicate)
        #expect(results[1].suggestedAccountID == nil)
    }

    @Test("A matching FITID in a split's online_id is a definitive duplicate")
    func onlineIDDedup() {
        let (book, bank, _) = makeBook()
        // Tag the existing bank split with an OFX FITID (GnuCash's online_id).
        let bankSplit = book.splits(for: bank).first!
        bankSplit.kvp["online_id"] = .string("FIT-12345")

        // A re-imported row with the same FITID but a wildly different amount
        // and a date months away — GnuCash still dedupes it on online_id.
        let offAmount = StagedTransaction(date: day(2026, 6, 30),
            amount: Decimal(string: "-999")!, payee: "SomethingElse", reference: "FIT-12345")
        let fresh = StagedTransaction(date: day(2026, 6, 30),
            amount: Decimal(string: "-77")!, payee: "New", reference: "FIT-99999")
        let results = ImportMatcher.match([offAmount, fresh], into: bank, book: book)
        #expect(results[0].isDuplicate)          // online_id definitive
        #expect(!results[1].isDuplicate)         // different id + amount
    }
}
