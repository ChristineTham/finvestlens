//
//  MT940CAMTTests.swift
//  FinvestLens — Interchange
//
//  P8 statement importers (`FR-XIO-04`): SWIFT MT940/MT942 and ISO 20022
//  CAMT.053. Fixtures follow the SWIFT field spec and published bank samples
//  (ABN AMRO / ING / Danske style for MT940; the ISO message samples for
//  CAMT), the way the QIF/OFX fixtures were built.
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

@Suite("MT940 import")
struct MT940ImportTests {

    @Test("Parses a full MT940 message with block headers and multi-line narratives")
    func fullStatement() {
        let mt940 = """
        {1:F01AAAABB99BSMK3513951576}{2:O9400400260701BBBBAA33XXXX0359233277}{4:
        :20:0574908765432101
        :25:AU012345/678901234
        :28C:00035/001
        :60F:C260501AUD1723,56
        :61:2605020502D200,00NCHKNONREF//B4E07XM00J000023
        :86:CHEQUE 123 CHATSWOOD BRANCH
        :61:2605040504D20000,00NTRF16778249//B4E07XM00J000024
        :86:TRANSFER TO CWK THAM LH CHEAH SMSF PTY L
        NETBANK LCHEAH NON CONCESSIONAL
        :61:2605110511C18512,99NTRFNONREF//B4E07XM00J000025
        :86:PAYMENT RECEIVED - THANK YOU
        :62F:C260630AUD26,55
        -}
        """
        let rows = MT940Importer.parse(mt940)
        #expect(rows.count == 3)

        #expect(rows[0].date == day(2026, 5, 2))
        #expect(rows[0].amount == Decimal(-200))
        #expect(rows[0].reference == "B4E07XM00J000023")
        #expect(rows[0].memo == "CHEQUE 123 CHATSWOOD BRANCH")

        // Multi-line :86: joins; the bank reference (after //) wins.
        #expect(rows[1].amount == Decimal(-20000))
        #expect(rows[1].memo == "TRANSFER TO CWK THAM LH CHEAH SMSF PTY L NETBANK LCHEAH NON CONCESSIONAL")
        #expect(rows[1].reference == "B4E07XM00J000024")

        #expect(rows[2].amount == Decimal(string: "18512.99"))
        #expect(rows[2].date == day(2026, 5, 11))
    }

    @Test("Statement-line variants: no entry date, funds code, reversals, customer ref")
    func statementLineVariants() {
        // No entry date, funds code R before the amount, no decimals.
        let plain = MT940Importer.statementLine("260502DR450,NMSC1234567890123")
        #expect(plain?.date == day(2026, 5, 2))
        #expect(plain?.amount == Decimal(-450))
        #expect(plain?.reference == "1234567890123")   // customer ref, no // part

        // RC = reversal of credit → money back out (negative); RD → positive.
        let reversedCredit = MT940Importer.statementLine("2605020502RC100,00NTRFNONREF")
        #expect(reversedCredit?.amount == Decimal(-100))
        let reversedDebit = MT940Importer.statementLine("2605020502RD75,50NRTINONREF")
        #expect(reversedDebit?.amount == Decimal(string: "75.50"))

        // NONREF with no bank reference → empty reference.
        #expect(MT940Importer.statementLine("2605020502C10,00NTRFNONREF")?.reference == "")
    }

    @Test("German ?-subfield narratives extract payee and remittance text")
    func subfieldNarrative() {
        let (payee, memo) = MT940Importer.narrative(
            "005?00SEPA-LASTSCHRIFT?20EREF+123456789?21MREF+ABC-XYZ?32WOOLWORTHS METRO?33SYDNEY NSW")
        #expect(payee == "WOOLWORTHS METRO SYDNEY NSW")
        #expect(memo == "EREF+123456789 MREF+ABC-XYZ")

        // Free-form narratives stay whole, as the memo.
        let (freePayee, freeMemo) = MT940Importer.narrative("Direct Debit ANZ CREDIT CARD")
        #expect(freePayee.isEmpty)
        #expect(freeMemo == "Direct Debit ANZ CREDIT CARD")
    }

    @Test("MT942 interim reports parse through the same scanner")
    func mt942() {
        let mt942 = """
        :20:INTERIM240630
        :25:AU012345/678901234
        :28C:00212
        :13D:2606301200+1000
        :90D:1AUD49,10
        :90C:0AUD0,00
        :61:2606300630D49,10NCMZNONREF//T123
        :86:WW METRO 436 VICTORIA AVE CHATSWOOD
        """
        let rows = MT940Importer.parse(mt942)
        #expect(rows.count == 1)
        #expect(rows[0].amount == Decimal(string: "-49.10"))
        #expect(rows[0].date == day(2026, 6, 30))
        #expect(rows[0].memo == "WW METRO 436 VICTORIA AVE CHATSWOOD")
    }
}

@Suite("CAMT.053 import")
struct CAMTImportTests {

    private let sample = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Document xmlns="urn:iso:std:iso:20022:tech:xsd:camt.053.001.02">
     <BkToCstmrStmt>
      <GrpHdr><MsgId>053MSG-1</MsgId><CreDtTm>2026-07-01T00:00:00</CreDtTm></GrpHdr>
      <Stmt>
       <Id>STMT-2026-06</Id>
       <Acct><Id><Othr><Id>678901234</Id></Othr></Id></Acct>
       <Bal><Amt Ccy="AUD">1723.56</Amt></Bal>
       <Ntry>
        <Amt Ccy="AUD">4439.95</Amt>
        <CdtDbtInd>DBIT</CdtDbtInd>
        <Sts>BOOK</Sts>
        <BookgDt><Dt>2026-06-08</Dt></BookgDt>
        <ValDt><Dt>2026-06-09</Dt></ValDt>
        <AcctSvcrRef>D615900989507</AcctSvcrRef>
        <NtryDtls><TxDtls>
          <Refs><EndToEndId>NOTPROVIDED</EndToEndId></Refs>
          <RltdPties><Cdtr><Nm>ANZ CREDIT CARD</Nm></Cdtr></RltdPties>
          <RmtInf><Ustrd>Direct Debit 024332</Ustrd><Ustrd>ANZ CREDIT CARD</Ustrd></RmtInf>
        </TxDtls></NtryDtls>
       </Ntry>
       <Ntry>
        <Amt Ccy="AUD">10000.00</Amt>
        <CdtDbtInd>CRDT</CdtDbtInd>
        <Sts><Cd>BOOK</Cd></Sts>
        <BookgDt><DtTm>2026-06-17T09:30:00+10:00</DtTm></BookgDt>
        <NtryDtls><TxDtls>
          <Refs><TxId>TX-778899</TxId></Refs>
          <RltdPties><Dbtr><Pty><Nm>HELLO THAM CHRIS THAM</Nm></Pty></Dbtr></RltdPties>
          <RmtInf><Ustrd>Non Concessional</Ustrd></RmtInf>
        </TxDtls></NtryDtls>
       </Ntry>
       <Ntry>
        <Amt Ccy="AUD">1.00</Amt>
        <CdtDbtInd>DBIT</CdtDbtInd>
        <Sts>PDNG</Sts>
        <BookgDt><Dt>2026-06-30</Dt></BookgDt>
       </Ntry>
       <Ntry>
        <Amt Ccy="AUD">50.00</Amt>
        <CdtDbtInd>DBIT</CdtDbtInd>
        <RvslInd>true</RvslInd>
        <Sts>BOOK</Sts>
        <BookgDt><Dt>2026-06-20</Dt></BookgDt>
        <AddtlNtryInf>REVERSAL OF FEE</AddtlNtryInf>
       </Ntry>
      </Stmt>
     </BkToCstmrStmt>
    </Document>
    """

    @Test("Parses entries with signs, refs, counterparties, and status filtering")
    func parseStatement() {
        let rows = CAMTImporter.parse(sample)
        #expect(rows.count == 3)                       // PDNG entry skipped

        // Debit → negative; booking date preferred; entry AcctSvcrRef wins;
        // creditor names the payee on a debit; Ustrd lines join.
        #expect(rows[0].amount == Decimal(string: "-4439.95"))
        #expect(rows[0].date == day(2026, 6, 8))
        #expect(rows[0].reference == "D615900989507")
        #expect(rows[0].payee == "ANZ CREDIT CARD")
        #expect(rows[0].memo == "Direct Debit 024332 ANZ CREDIT CARD")

        // Credit → positive; nested Sts/Cd read; DtTm accepted; TxId as the
        // reference (EndToEndId NOTPROVIDED is meaningless); debtor payee via
        // the newer Pty nesting.
        #expect(rows[1].amount == Decimal(10000))
        #expect(rows[1].date == day(2026, 6, 17))
        #expect(rows[1].reference == "TX-778899")
        #expect(rows[1].payee == "HELLO THAM CHRIS THAM")

        // A booked reversal of a debit flips back to a credit.
        #expect(rows[2].amount == Decimal(50))
        #expect(rows[2].memo == "REVERSAL OF FEE")
    }

    @Test("Prefixed namespaces parse the same")
    func prefixedNamespace() {
        let prefixed = sample
            .replacingOccurrences(of: "<", with: "<c:")
            .replacingOccurrences(of: "<c:/", with: "</c:")
            .replacingOccurrences(of: "<c:?xml", with: "<?xml")
            .replacingOccurrences(of: "xmlns=", with: "xmlns:c=")
        let rows = CAMTImporter.parse(prefixed)
        #expect(rows.count == 3)
        #expect(rows[0].amount == Decimal(string: "-4439.95"))
    }
}

@Suite("P8 exit criteria — new formats through the matcher")
struct ExtendedImportMatcherTests {

    /// Import an MT940 and a CAMT.053 through the Import Matcher against a
    /// book with history: dedupe (by online_id and by amount+window) and
    /// account assignment (by payee history) must behave exactly as they do
    /// for QIF/OFX (`FR-XIO-04` exit criterion).
    @Test("MT940 and CAMT rows dedupe and get destinations from history")
    func throughTheMatcher() {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let groceries = book.addAccount(Account(name: "Groceries", type: .expense, commodity: .aud))

        // History: a categorised Woolworths purchase whose split carries the
        // FITID of a previous statement.
        let txn = Transaction(currency: .aud, datePosted: day(2026, 6, 1), description: "WOOLWORTHS METRO")
        txn.addSplit(account: groceries, value: Decimal(string: "52.30")!)
        let bankLeg = txn.addSplit(account: bank, value: Decimal(string: "-52.30")!)
        bankLeg.kvp["online_id"] = .string("B4E07XM00J000001")
        book.addTransaction(txn)

        let mt940 = """
        :20:REF1
        :25:AU/1
        :61:2606010601D52,30NMSCNONREF//B4E07XM00J000001
        :86:WOOLWORTHS METRO
        :61:2606150615D64,10NMSCNONREF//B4E07XM00J000002
        :86:WOOLWORTHS METRO
        """
        let mtRows = MT940Importer.parse(mt940)
        #expect(mtRows.count == 2)
        let mtResults = ImportMatcher.match(mtRows, into: bank, book: book)
        #expect(mtResults[0].isDuplicate)                                // same FITID
        #expect(!mtResults[1].isDuplicate)                               // new FITID (veto + new)
        #expect(mtResults[1].suggestedAccountID == groceries.guid)       // payee history

        let camt = """
        <Document xmlns="urn:iso:std:iso:20022:tech:xsd:camt.053.001.02"><BkToCstmrStmt><Stmt>
        <Ntry><Amt Ccy="AUD">52.30</Amt><CdtDbtInd>DBIT</CdtDbtInd><Sts>BOOK</Sts>
        <BookgDt><Dt>2026-06-01</Dt></BookgDt><AcctSvcrRef>B4E07XM00J000001</AcctSvcrRef>
        <NtryDtls><TxDtls><RmtInf><Ustrd>WOOLWORTHS METRO</Ustrd></RmtInf></TxDtls></NtryDtls></Ntry>
        <Ntry><Amt Ccy="AUD">89.00</Amt><CdtDbtInd>DBIT</CdtDbtInd><Sts>BOOK</Sts>
        <BookgDt><Dt>2026-06-20</Dt></BookgDt><AcctSvcrRef>B4E07XM00J000003</AcctSvcrRef>
        <NtryDtls><TxDtls><RmtInf><Ustrd>WOOLWORTHS METRO</Ustrd></RmtInf></TxDtls></NtryDtls></Ntry>
        </Stmt></BkToCstmrStmt></Document>
        """
        let camtRows = CAMTImporter.parse(camt)
        #expect(camtRows.count == 2)
        let camtResults = ImportMatcher.match(camtRows, into: bank, book: book)
        #expect(camtResults[0].isDuplicate)                              // same reference
        #expect(!camtResults[1].isDuplicate)
        #expect(camtResults[1].suggestedAccountID == groceries.guid)
    }
}
