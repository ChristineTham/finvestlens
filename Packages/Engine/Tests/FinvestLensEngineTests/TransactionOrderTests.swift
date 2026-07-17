//
//  TransactionOrderTests.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensEngine

@Suite("Transaction canonical order")
struct TransactionOrderTests {

    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(n) * 86_400) }

    private func txn(date: Int, num: String = "", entered: Int = 0,
                     desc: String = "") -> Transaction {
        Transaction(currency: .aud, datePosted: day(date),
                    dateEntered: day(entered), number: num, description: desc)
    }

    @Test("Date posted is the primary key")
    func byDate() {
        let a = txn(date: 1, num: "99"), b = txn(date: 2, num: "1")
        #expect(Transaction.canonicalOrder(a, action: "", b, action: "") < 0)
    }

    @Test("Same date orders by the num string, numerically not lexically")
    func numericNum() {
        // Loaded 2 then 1, and 10 vs 9 — GnuCash sorts 1 < 2 and 9 < 10.
        let one = txn(date: 5, num: "1"), two = txn(date: 5, num: "2")
        #expect(Transaction.canonicalOrder(two, action: "", one, action: "") > 0)
        let nine = txn(date: 5, num: "9"), ten = txn(date: 5, num: "10")
        #expect(Transaction.canonicalOrder(ten, action: "", nine, action: "") > 0)   // 10 after 9
    }

    @Test("Split action overrides the transaction num when both are set")
    func actionOverride() {
        let a = txn(date: 5, num: "50"), b = txn(date: 5, num: "1")
        // Actions 1 vs 2 decide it even though the nums would say otherwise.
        #expect(Transaction.canonicalOrder(a, action: "1", b, action: "2") < 0)
    }

    @Test("Equal nums fall through to description")
    func descriptionTiebreak() {
        let a = txn(date: 5, num: "7", desc: "Aardvark")
        let b = txn(date: 5, num: "7", desc: "Zebra")
        #expect(Transaction.canonicalOrder(a, action: "", b, action: "") < 0)
    }

    @Test("A transaction never sorts before itself")
    func reflexive() {
        let a = txn(date: 5, num: "7")
        #expect(Transaction.canonicalOrder(a, action: "", a, action: "") == 0)
    }
}
