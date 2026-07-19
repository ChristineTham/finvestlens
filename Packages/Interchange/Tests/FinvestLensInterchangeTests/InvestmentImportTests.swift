//
//  InvestmentImportTests.swift
//  FinvestLens — Interchange
//
//  Parsing QIF `!Type:Invst` and OFX investment transactions (FR-XIO-01/02).
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensInterchange

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

@Suite("Investment import")
struct InvestmentImportTests {

    @Test("QIF !Type:Invst parses buy/sell/dividend with security, qty and price")
    func qifInvestment() {
        let qif = """
        !Type:Invst
        D01/02'24
        NBuy
        YAcme Corp
        I25.50
        Q100
        O9.95
        U-2559.95
        ^
        D02/03'24
        NSell
        YAcme Corp
        I30.00
        Q40
        T1200.00
        ^
        D03/04'24
        NDiv
        YAcme Corp
        T45.00
        ^
        """
        let rows = QIFImporter.parse(qif)
        #expect(rows.count == 3)
        let allInvestment = rows.allSatisfy { $0.isInvestment }
        #expect(allInvestment)

        let buy = rows[0].investment!
        #expect(buy.action == .buy)
        #expect(buy.security == "Acme Corp")
        #expect(buy.quantity == 100)
        #expect(buy.pricePerShare == dec("25.50"))
        #expect(buy.commission == dec("9.95"))
        #expect(rows[0].amount == dec("-2559.95"))

        #expect(rows[1].investment?.action == .sell)
        #expect(rows[1].investment?.quantity == 40)
        #expect(rows[2].investment?.action == .dividend)
        #expect(rows[2].amount == dec("45.00"))
    }

    @Test("A cash section after an investment section still parses as cash")
    func qifMixedSections() {
        let qif = """
        !Type:Invst
        D01/02'24
        NBuy
        YAcme Corp
        I10.00
        Q5
        ^
        !Type:Bank
        D01/03'24
        T-42.00
        PGrocer
        ^
        """
        let rows = QIFImporter.parse(qif)
        #expect(rows.count == 2)
        #expect(rows[0].isInvestment)
        #expect(!rows[1].isInvestment)
        #expect(rows[1].payee == "Grocer")
        #expect(rows[1].amount == dec("-42.00"))
        // The buy's cash amount is derived from qty × price when T/U is absent.
        #expect(rows[0].amount == dec("50.00"))
    }

    @Test("QIF S/E/$ split lines produce a multi-category cash row")
    func qifSplits() {
        let qif = """
        !Type:Bank
        D01/15'24
        T-120.00
        PSupermarket
        SGroceries
        EFood
        $-90.00
        SHousehold
        $-30.00
        ^
        """
        let rows = QIFImporter.parse(qif)
        #expect(rows.count == 1)
        let row = rows[0]
        #expect(row.isSplit)
        #expect(row.amount == dec("-120.00"))
        #expect(row.splits.count == 2)
        #expect(row.splits[0].category == "Groceries")
        #expect(row.splits[0].amount == dec("-90.00"))
        #expect(row.splits[0].memo == "Food")
        #expect(row.splits[1].category == "Household")
        #expect(row.splits[1].amount == dec("-30.00"))
    }

    @Test("OFX BUYSTOCK / SELLSTOCK / INCOME parse into investment rows")
    func ofxInvestment() {
        let ofx = """
        <INVTRANLIST>
        <BUYSTOCK>
        <INVBUY>
        <INVTRAN><FITID>1<DTTRADE>20240102<MEMO>Buy Acme</INVTRAN>
        <SECID><UNIQUEID>ACME<UNIQUEIDTYPE>TICKER</SECID>
        <UNITS>100
        <UNITPRICE>25.50
        <COMMISSION>9.95
        <TOTAL>-2559.95
        </INVBUY>
        <BUYTYPE>BUY
        </BUYSTOCK>
        <SELLSTOCK>
        <INVSELL>
        <INVTRAN><FITID>2<DTTRADE>20240203</INVTRAN>
        <SECID><UNIQUEID>ACME</SECID>
        <UNITS>-40
        <UNITPRICE>30.00
        <TOTAL>1200.00
        </INVSELL>
        </SELLSTOCK>
        <INCOME>
        <INVTRAN><FITID>3<DTTRADE>20240304</INVTRAN>
        <SECID><UNIQUEID>ACME</SECID>
        <INCOMETYPE>DIV
        <TOTAL>45.00
        </INCOME>
        </INVTRANLIST>
        """
        let rows = OFXImporter.parse(ofx)
        let investments = rows.filter(\.isInvestment)
        #expect(investments.count == 3)

        let buy = investments.first { $0.investment?.action == .buy }?.investment
        #expect(buy?.security == "ACME")
        #expect(buy?.quantity == 100)
        #expect(buy?.pricePerShare == dec("25.50"))
        #expect(buy?.commission == dec("9.95"))

        // Units come through as a positive magnitude regardless of sign.
        let sell = investments.first { $0.investment?.action == .sell }?.investment
        #expect(sell?.quantity == 40)

        #expect(investments.contains { $0.investment?.action == .dividend && $0.amount == dec("45.00") })
    }

    @Test("A plain cash OFX statement carries no investment rows")
    func ofxCashOnly() {
        let ofx = """
        <STMTTRN>
        <TRNTYPE>DEBIT<DTPOSTED>20240110<TRNAMT>-19.99<NAME>Netflix<FITID>x
        </STMTTRN>
        """
        let rows = OFXImporter.parse(ofx)
        #expect(rows.count == 1)
        #expect(!rows[0].isInvestment)
        #expect(rows[0].amount == dec("-19.99"))
    }
}
