//
//  BillableEntryTests.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensEngine

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

@Suite("Billable entry")
struct BillableEntryTests {

    @Test("Amount is quantity times rate")
    func amount() {
        let time = BillableEntry(kind: .time, quantity: dec("2.5"), rate: dec("120"))
        #expect(time.amount == dec("300"))
        let mileage = BillableEntry(kind: .mileage, quantity: dec("40"), rate: dec("0.85"))
        #expect(mileage.amount == dec("34"))
    }

    @Test("Older slots without job/income/billed decode cleanly")
    func backwardCompatibleDecode() throws {
        let json = #"{"id":"\#(GncGUID.random().hexString)","kind":"time","date":0,"quantity":3,"rate":100,"detail":"Consulting"}"#
        let entry = try JSONDecoder().decode(BillableEntry.self, from: Data(json.utf8))
        #expect(entry.detail == "Consulting")
        #expect(entry.jobID == nil)
        #expect(entry.incomeAccountID == nil)
        #expect(!entry.billed)
        #expect(entry.amount == dec("300"))
    }
}
