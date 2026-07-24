//
//  SplitTransactionGapTests.swift
//  FinvestLens — Engine
//
//  Coverage for the Split/Transaction members the model tests skirt around:
//  Money views, detached copies, KVP-backed statement dates and document
//  links, split removal, voiding semantics, and the deep order tiebreaks.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensEngine

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private func day(_ days: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(days) * 86_400) }

@Suite("Split members")
struct SplitMemberTests {

    private func attachedSplit() -> (Transaction, Split, Account) {
        let account = Account(name: "US Cash", type: .bank, commodity: .usd)
        let txn = Transaction(currency: .aud, datePosted: day(0), description: "FX")
        let split = txn.addSplit(account: account, value: dec("150"), quantity: dec("100"))
        return (txn, split, account)
    }

    @Test("valueMoney and quantityMoney carry the right commodities")
    func moneyViews() {
        let (txn, split, _) = attachedSplit()
        #expect(split.valueMoney == Money(dec("150"), .aud))       // transaction currency
        #expect(split.quantityMoney == Money(dec("100"), .usd))    // account commodity
        withExtendedLifetime(txn) {}

        let orphan = Split(value: dec("5"))
        #expect(orphan.valueMoney == nil)      // no transaction
        #expect(orphan.quantityMoney == nil)   // no account
    }

    @Test("Quantity defaults to value for same-currency postings")
    func quantityDefault() {
        let split = Split(value: dec("25.50"))
        #expect(split.quantity == dec("25.50"))
        #expect(split.id == split.guid)
    }

    @Test("detachedCopy snapshots every field under the same identity")
    func detachedCopy() {
        let (txn, split, account) = attachedSplit()
        split.reconcileState = .reconciled
        split.reconcileDate = day(3)
        split.memo = "settled"
        split.action = "Buy"
        split.kvp["note"] = .string("kept")

        let copy = split.detachedCopy()
        #expect(copy.guid == split.guid)          // same identity…
        #expect(copy !== split)
        #expect(copy != split)                    // …but a distinct object (identity equality)
        #expect(copy.transaction == nil)          // belongs to no transaction
        #expect(copy.account === account)
        #expect(copy.value == split.value)
        #expect(copy.quantity == split.quantity)
        #expect(copy.reconcileState == .reconciled)
        #expect(copy.reconcileDate == day(3))
        #expect(copy.memo == "settled")
        #expect(copy.action == "Buy")
        #expect(copy.kvp["note"] == .string("kept"))

        // The snapshot stays untouched by later edits.
        split.value = dec("999")
        #expect(copy.value == dec("150"))
        withExtendedLifetime(txn) {}
    }

    @Test("Equality and hashing are by object identity")
    func identitySemantics() {
        let a = Split(value: dec("1"))
        let b = Split(value: dec("1"))
        #expect(a == a)
        #expect(a != b)
        #expect(Set([a, b, a]).count == 2)
    }
}

@Suite("Transaction members")
struct TransactionMemberTests {

    @Test("Statement date lives in a preserved KVP slot")
    func statementDate() {
        let txn = Transaction(currency: .aud, datePosted: day(10))
        #expect(txn.statementDate == nil)
        txn.statementDate = day(12)
        #expect(txn.statementDate == day(12))
        #expect(txn.kvp["finvestlens/statement-date"] == .date(day(12)))
        txn.statementDate = nil
        #expect(txn.statementDate == nil)
        #expect(txn.kvp["finvestlens/statement-date"] == nil)
    }

    @Test("Document links trim and clear like GnuCash associations")
    func documentLink() {
        let txn = Transaction(currency: .aud, datePosted: day(0))
        #expect(txn.documentLink == nil)
        txn.documentLink = "  file:///docs/invoice.pdf  "
        #expect(txn.documentLink == "file:///docs/invoice.pdf")   // trimmed
        #expect(txn.kvp["assoc_uri"] == .string("file:///docs/invoice.pdf"))
        txn.documentLink = "   "
        #expect(txn.documentLink == nil)                          // blank clears
        txn.documentLink = "relative/path.pdf"
        txn.documentLink = nil
        #expect(txn.kvp["assoc_uri"] == nil)
        // An empty preserved slot reads as no link.
        txn.kvp["assoc_uri"] = .string("")
        #expect(txn.documentLink == nil)
    }

    @Test("removeSplit detaches only its own splits")
    func removeSplit() {
        let account = Account(name: "A", type: .bank, commodity: .aud)
        let txn = Transaction(currency: .aud, datePosted: day(0))
        let split = txn.addSplit(account: account, value: dec("10"))
        let other = Transaction(currency: .aud, datePosted: day(0))
        let foreign = other.addSplit(account: account, value: dec("5"))

        txn.removeSplit(foreign)                  // not ours: no-op
        #expect(other.splits.count == 1)
        #expect(foreign.transaction === other)

        txn.removeSplit(split)
        #expect(txn.splits.isEmpty)
        #expect(split.transaction == nil)
    }

    @Test("detachedCopy duplicates the splits under the same identities")
    func detachedCopy() {
        let account = Account(name: "A", type: .bank, commodity: .aud)
        let txn = Transaction(currency: .aud, datePosted: day(1), dateEntered: day(2),
                              number: "77", description: "Original", notes: "note")
        txn.kvp["book_closing"] = .int64(1)
        let split = txn.addSplit(account: account, value: dec("10"))

        let copy = txn.detachedCopy()
        #expect(copy.guid == txn.guid)
        #expect(copy !== txn)
        #expect(copy.currency == .aud)
        #expect(copy.datePosted == day(1))
        #expect(copy.dateEntered == day(2))
        #expect(copy.number == "77")
        #expect(copy.transactionDescription == "Original")
        #expect(copy.notes == "note")
        #expect(copy.kvp["book_closing"] == .int64(1))
        #expect(copy.splits.count == 1)
        #expect(copy.splits[0].guid == split.guid)
        #expect(copy.splits[0] !== split)
        #expect(copy.splits[0].transaction === copy)

        // The copy is a snapshot: edits to the original do not leak in.
        split.value = dec("99")
        #expect(copy.splits[0].value == dec("10"))
    }

    @Test("Balance tolerates only sub-minor-unit residue (ADR-1)")
    func balanceResidual() {
        let account = Account(name: "A", type: .bank, commodity: .aud)
        let txn = Transaction(currency: .aud, datePosted: day(0))
        txn.addSplit(account: account, value: dec("10.004"))
        txn.addSplit(account: account, value: dec("-10.00"))
        #expect(txn.imbalance.amount == dec("0.004"))
        #expect(txn.imbalance.commodity == .aud)
        #expect(txn.isBalanced)
        txn.addSplit(account: account, value: dec("0.01"))
        #expect(!txn.isBalanced)
        #expect(txn.id == txn.guid)
    }

    @Test("Identity semantics for equality and hashing")
    func identitySemantics() {
        let a = Transaction(currency: .aud, datePosted: day(0))
        let b = Transaction(currency: .aud, datePosted: day(0))
        #expect(a == a)
        #expect(a != b)
        #expect(Set([a, b, a]).count == 2)
    }

    @Test("Voided splits never count toward any balance")
    func voidedBalances() {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let costs = book.addAccount(Account(name: "Costs", type: .expense, commodity: .aud))
        let txn = Transaction(currency: .aud, datePosted: day(0), description: "Fee")
        txn.addSplit(account: bank, value: dec("-50"))
        txn.addSplit(account: costs, value: dec("50"))
        book.addTransaction(txn)

        // Frozen counts as cleared and as reconciled (GnuCash semantics).
        txn.splits[0].reconcileState = .frozen
        #expect(book.balance(of: bank, filter: .all).amount == dec("-50"))
        #expect(book.balance(of: bank, filter: .cleared).amount == dec("-50"))
        #expect(book.balance(of: bank, filter: .reconciled).amount == dec("-50"))

        // Cleared counts toward cleared but not reconciled.
        txn.splits[0].reconcileState = .cleared
        #expect(book.balance(of: bank, filter: .cleared).amount == dec("-50"))
        #expect(book.balance(of: bank, filter: .reconciled).amount == 0)

        // Voided vanishes from every filter.
        txn.splits[0].reconcileState = .voided
        #expect(book.balance(of: bank, filter: .all).amount == 0)
        #expect(book.balance(of: bank, filter: .cleared).amount == 0)
        #expect(book.balance(of: bank, filter: .reconciled).amount == 0)
    }
}

@Suite("Canonical order deep tiebreaks")
struct CanonicalOrderGapTests {

    private func txn(number: String = "", entered: Date? = nil,
                     description: String = "") -> Transaction {
        Transaction(currency: .aud, datePosted: day(0), dateEntered: entered,
                    number: number, description: description)
    }

    @Test("numOrString: numeric leads, collation fallbacks")
    func numOrString() {
        #expect(Transaction.numOrString("10", "9") > 0)      // numeric, not lexical
        #expect(Transaction.numOrString("12a", "12b") < 0)   // tie broken by the tail
        #expect(Transaction.numOrString("7", "007") == 0)    // same integer, empty tails
        #expect(Transaction.numOrString("abc", "abd") < 0)   // plain collation
        #expect(Transaction.numOrString("abc", "abc") == 0)
        #expect(Transaction.numOrString("0x", "1") < 0)      // a zero lead falls back to collation
    }

    @Test("Entered date breaks a full num tie")
    func enteredDateTiebreak() {
        let a = txn(number: "7", entered: day(5))
        let b = txn(number: "7", entered: day(6))
        #expect(Transaction.canonicalOrder(a, action: "", b, action: "") < 0)
        #expect(Transaction.canonicalOrder(b, action: "", a, action: "") > 0)
    }

    @Test("The guid keeps the order total when all else ties")
    func guidTiebreak() {
        let a = txn(entered: day(5), description: "Same")
        let b = txn(entered: day(5), description: "Same")
        let expected = a.guid.hexString < b.guid.hexString ? -1 : 1
        #expect(Transaction.canonicalOrder(a, action: "", b, action: "") == expected)
        #expect(Transaction.canonicalOrder(b, action: "", a, action: "") == -expected)
    }

    @Test("One empty action falls back to the transaction numbers")
    func mixedActions() {
        let a = txn(number: "2")
        let b = txn(number: "1")
        #expect(Transaction.canonicalOrder(a, action: "1", b, action: "") > 0)   // by number: 2 > 1
    }
}
