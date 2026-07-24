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

    @Test("Two-digit day-first years land in this century, not year 26 AD")
    func twoDigitDayFirstYears() {
        // AU-bank style: `30/06/26` proves day-first; `08/06/26` alone would be
        // ambiguous but must follow the file's orientation (8 June, not 6 Aug) —
        // and both must parse as 2026, not literal year 26.
        let qif = """
        !Type:Bank
        D30/06/26
        PInterest Paid
        T126.20
        ^
        D08/06/26
        PDirect Debit
        T-4439.95
        ^
        """
        let rows = QIFImporter.parse(qif)
        #expect(rows.count == 2)
        #expect(rows[0].date == day(2026, 6, 30))
        #expect(rows[1].date == day(2026, 6, 8))
    }

    @Test("Two-digit years without day-first evidence stay month-first")
    func twoDigitMonthFirstYears() {
        let rows = QIFImporter.parse("D06/08/26\nT-10.00\nPShop\n^")
        #expect(rows.count == 1)
        #expect(rows[0].date == day(2026, 6, 8))
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

    @Test("Different bank references veto an amount+date match")
    func referenceMismatchVeto() {
        let (book, bank, _) = makeBook()
        // Last statement's entry, stamped with its FITID.
        book.splits(for: bank).first!.kvp["online_id"] = .string("FIT-OLD")

        // This statement's row: same amount, next day — but its own FITID.
        // A bank never re-issues an event under a new id: not a duplicate.
        let staged = [StagedTransaction(date: day(2026, 1, 16), amount: Decimal(string: "-52.30")!,
                                        payee: "Woolworths", reference: "FIT-NEW")]
        let results = ImportMatcher.match(staged, into: bank, book: book)
        #expect(!results[0].isDuplicate)
    }

    @Test("Each book entry absorbs at most one statement row")
    func oneToOneClaiming() {
        let (book, bank, _) = makeBook()
        // Two identical rows against ONE book entry: the second must import.
        let rows = [
            StagedTransaction(date: day(2026, 1, 15), amount: Decimal(string: "-52.30")!, payee: "Woolworths"),
            StagedTransaction(date: day(2026, 1, 16), amount: Decimal(string: "-52.30")!, payee: "Woolworths"),
        ]
        let results = ImportMatcher.match(rows, into: bank, book: book)
        #expect(results.filter(\.isDuplicate).count == 1)
    }

    @Test("History learned from money-leg memos, not just descriptions")
    func memoHistory() {
        let (book, bank, groceries) = makeBook()
        // A renamed transaction: friendly description, raw narrative in the
        // bank leg's memo (how the smart categoriser leaves them).
        let txn = Transaction(currency: .aud, datePosted: day(2026, 2, 1), description: "Digidirect")
        txn.addSplit(account: groceries, value: Decimal(string: "150")!)
        txn.addSplit(account: bank, value: Decimal(string: "-150")!,
                     memo: "PAYPAL AUSTRALIA 1051339327183")
        book.addTransaction(txn)

        let staged = [StagedTransaction(date: day(2026, 6, 1), amount: Decimal(string: "-88")!,
                                        payee: "PAYPAL AUSTRALIA 1051339327183")]
        let results = ImportMatcher.match(staged, into: bank, book: book)
        #expect(results[0].suggestedAccountID == groceries.guid)
    }
}

@Suite("Import matcher — transfers")
struct ImportTransferMatchTests {

    /// Two banks and a wash account, with one transfer already imported from
    /// the CMAA side: CMAA −5000, the other leg parked in "Unspecified".
    private func makeBook() -> (Book, cma: Account, cmaa: Account, wash: Account, washSplit: Split) {
        let book = Book(baseCurrency: .aud)
        let cma = book.addAccount(Account(name: "CMA", type: .bank, commodity: .aud))
        let cmaa = book.addAccount(Account(name: "CMAA", type: .bank, commodity: .aud))
        let wash = book.addAccount(Account(name: "Unspecified", type: .income, commodity: .aud))
        let txn = Transaction(currency: .aud, datePosted: day(2026, 5, 20),
                              description: "To Smsf Pty Ltd Internal transfer")
        txn.addSplit(account: cmaa, value: Decimal(-5000))
        let washSplit = txn.addSplit(account: wash, value: Decimal(5000))
        book.addTransaction(txn)
        return (book, cma, cmaa, wash, washSplit)
    }

    @Test("The other side of a transfer heals the wash leg instead of duplicating")
    func transferCounterpartDetected() {
        let (book, cma, cmaa, _, washSplit) = makeBook()
        let staged = [StagedTransaction(date: day(2026, 5, 20), amount: Decimal(5000),
                                        payee: "From Smsf Pty Ltd Atf")]
        let results = ImportMatcher.match(staged, into: cma, book: book)
        #expect(!results[0].isDuplicate)
        #expect(results[0].transferSplitID == washSplit.guid)
        #expect(results[0].suggestedAccountID == cmaa.guid)
    }

    @Test("No transfer match outside the date window or at the wrong amount")
    func transferBounds() {
        let (book, cma, _, _, _) = makeBook()
        let farAway = StagedTransaction(date: day(2026, 6, 20), amount: Decimal(5000),
                                        payee: "From Smsf")
        let wrongAmount = StagedTransaction(date: day(2026, 5, 20), amount: Decimal(4999),
                                            payee: "From Smsf")
        let results = ImportMatcher.match([farAway, wrongAmount], into: cma, book: book)
        #expect(results[0].transferSplitID == nil)
        #expect(results[1].transferSplitID == nil)
    }

    @Test("Equal amount and date alone don't make a transfer — narratives must agree")
    func transferNarrativeGate() {
        let (book, cma, _, _, _) = makeBook()
        // Same $5,000, same day — but a completely unrelated story (a term
        // deposit maturing, say). Must NOT be healed into the pending transfer.
        let coincidence = StagedTransaction(date: day(2026, 5, 20), amount: Decimal(5000),
                                            payee: "Myer Sydney City Refund")
        let results = ImportMatcher.match([coincidence], into: cma, book: book)
        #expect(results[0].transferSplitID == nil)
    }

    @Test("A transaction already posted to the target is a duplicate, not a transfer")
    func completeTransferIsDuplicate() {
        let (book, cma, cmaa, _, _) = makeBook()
        // The completed transfer: both real legs present.
        let txn = Transaction(currency: .aud, datePosted: day(2026, 6, 8), description: "Card payment")
        txn.addSplit(account: cma, value: Decimal(string: "-4439.95")!)
        txn.addSplit(account: cmaa, value: Decimal(string: "4439.95")!)
        book.addTransaction(txn)

        let staged = [StagedTransaction(date: day(2026, 6, 8),
                                        amount: Decimal(string: "-4439.95")!, payee: "Direct Debit")]
        let results = ImportMatcher.match(staged, into: cma, book: book)
        #expect(results[0].isDuplicate)
        #expect(results[0].transferSplitID == nil)
    }

    @Test("Completing a transfer beats matching a wash-parked half of the same amount")
    func healBeatsWashHalfDuplicate() {
        let (book, cma, cmaa, wash, washSplit) = makeBook()
        // The book also holds an OLDER wash-parked deposit of the same amount in
        // the target account itself — last statement's still-uncategorised entry.
        let older = Transaction(currency: .aud, datePosted: day(2026, 5, 18),
                                description: "From Smsf Pty Ltd Atf")
        older.addSplit(account: cma, value: Decimal(5000))
        older.addSplit(account: wash, value: Decimal(-5000))
        book.addTransaction(older)

        // The row is within the window of both the older half (a would-be
        // duplicate) and the pending CMAA transfer. Completing the transfer is
        // the stronger read: a wash-parked half proves the amount recurs, not
        // that this row is already recorded.
        let staged = [StagedTransaction(date: day(2026, 5, 20), amount: Decimal(5000),
                                        payee: "From Smsf Pty Ltd Atf")]
        let results = ImportMatcher.match(staged, into: cma, book: book)
        #expect(!results[0].isDuplicate)
        #expect(results[0].transferSplitID == washSplit.guid)
    }

    @Test("Credit-card payment rows fall back to the historical funding account")
    func fundingFallback() {
        let book = Book(baseCurrency: .aud)
        let card = book.addAccount(Account(name: "Visa", type: .credit, commodity: .aud))
        let cdia = book.addAccount(Account(name: "CDIA", type: .bank, commodity: .aud))
        for month in 1...3 {
            let txn = Transaction(currency: .aud, datePosted: day(2026, month, 9),
                                  description: "Direct Debit ANZ CREDIT CARD")
            txn.addSplit(account: card, value: Decimal(2000 + month))
            txn.addSplit(account: cdia, value: Decimal(-2000 - month))
            book.addTransaction(txn)
        }

        let payment = StagedTransaction(date: day(2026, 6, 8), amount: Decimal(string: "4439.95")!,
                                        memo: "PAYMENT - THANK YOU")
        let charge = StagedTransaction(date: day(2026, 6, 9), amount: Decimal(string: "-49.10")!,
                                       memo: "WW METRO CHATSWOOD")
        let results = ImportMatcher.match([payment, charge], into: card, book: book)
        #expect(results[0].suggestedAccountID == cdia.guid)   // funded from CDIA
        #expect(results[1].suggestedAccountID == nil)         // charges don't infer funding
    }
}
