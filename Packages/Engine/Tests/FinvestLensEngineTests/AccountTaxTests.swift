//
//  AccountTaxTests.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensEngine

@Suite("Account tax slots")
struct AccountTaxTests {

    @Test("Tax-related and code read and write through GnuCash's slots")
    func slots() {
        let a = Account(name: "Salary", type: .income, commodity: .aud)
        #expect(!a.taxRelated)
        #expect(a.taxCode == nil)

        a.taxRelated = true
        a.taxCode = "N286"
        #expect(a.taxRelated)
        #expect(a.taxCode == "N286")

        // Stored under the exact GnuCash keys, as an integer flag and a nested
        // tax-US frame, so a round-trip preserves them.
        #expect(a.kvp["tax-related"] == .int64(1))
        if case let .frame(frame)? = a.kvp["tax-US"] {
            #expect(frame["code"] == .string("N286"))
        } else {
            Issue.record("expected a tax-US frame")
        }
    }

    @Test("Clearing tax-related removes the slot rather than writing zero")
    func clearing() {
        let a = Account(name: "Salary", type: .income, commodity: .aud)
        a.taxRelated = true
        a.taxCode = "X1"
        a.taxRelated = false
        #expect(a.kvp["tax-related"] == nil)          // absent, not int64(0)
        a.taxCode = nil
        #expect(a.kvp["tax-US"] == nil)               // empty frame is dropped
    }

    @Test("An unrelated slot on the account is left untouched")
    func preservesOtherSlots() {
        let a = Account(name: "Salary", type: .income, commodity: .aud)
        a.kvp["notes"] = .string("keep me")
        a.taxRelated = true
        a.taxCode = "N1"
        a.taxRelated = false
        a.taxCode = nil
        #expect(a.kvp["notes"] == .string("keep me"))
    }
}
