//
//  TagsTests.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensEngine

@Suite("Transaction tags")
struct TagsTests {

    @Test("Tags round-trip through the KVP slot")
    func roundTrip() {
        let txn = Transaction(currency: .aud, datePosted: Date(timeIntervalSince1970: 0))
        #expect(txn.tags.isEmpty)
        txn.tags = ["holiday", "  reimbursable  ", ""]
        // Trimmed and blanks dropped.
        #expect(txn.tags == ["holiday", "reimbursable"])
        // Stored in kvp (so it persists / round-trips).
        #expect(txn.kvp["finvestlens/tags"] != nil)
        txn.tags = []
        #expect(txn.kvp["finvestlens/tags"] == nil)
    }

    @Test("Book collects distinct sorted tags")
    func bookTags() {
        let book = Book(baseCurrency: .aud)
        let t1 = Transaction(currency: .aud, datePosted: Date(timeIntervalSince1970: 0))
        t1.tags = ["b", "a"]
        let t2 = Transaction(currency: .aud, datePosted: Date(timeIntervalSince1970: 1))
        t2.tags = ["a", "c"]
        book.addTransaction(t1); book.addTransaction(t2)
        #expect(book.allTags == ["a", "b", "c"])
    }
}
