//
//  FindTests.swift
//  FinvestLens — Engine
//
//  The load-bearing rule, taken from GnuCash's own dialog (which is headed
//  "Split Search"): criteria are tested against one split, not against a
//  transaction. `sameSplitMustSatisfyEveryCriterion` is the test that pins it.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensEngine

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

private func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 0) -> Date {
    var c = DateComponents()
    c.year = y; c.month = m; c.day = d; c.hour = hour
    return Calendar(identifier: .gregorian).date(from: c)!
}

@Suite("Find")
struct FindTests {

    /// A share buy: cash out of CDIA, shares into AGL, both in one transaction.
    private func book() -> (Book, Account, Account, Account) {
        let book = Book()
        let cdia = Account(name: "CDIA", type: .bank, commodity: .aud)
        let agl = Account(name: "AGL", type: .stock,
                          commodity: Commodity(namespace: .security("ASX"), mnemonic: "AGL",
                                               fullName: "AGL Energy", smallestFraction: 10000))
        let fees = Account(name: "Brokerage", type: .expense, commodity: .aud)
        book.rootAccount.addChild(cdia)
        book.rootAccount.addChild(agl)
        book.rootAccount.addChild(fees)
        return (book, cdia, agl, fees)
    }

    private func shareBuy(_ book: Book, _ cdia: Account, _ agl: Account) -> Transaction {
        let txn = Transaction(currency: .aud, datePosted: day(2026, 4, 28), description: "AGL buy")
        txn.notes = "CommSec confirmation 12345"
        txn.number = "T-900"
        // Cash leg: reconciled, memo "settlement".
        txn.addSplit(account: cdia, value: dec("-11600"), quantity: dec("-11600"), memo: "settlement")
        txn.splits[0].reconcileState = .reconciled
        // Share leg: 11,600 shares at $1.00, not reconciled, memo "parcel".
        txn.addSplit(account: agl, value: dec("11600"), quantity: dec("11600"), memo: "parcel")
        txn.splits[1].action = "Buy"
        book.addTransaction(txn)
        return txn
    }

    // MARK: The rule

    /// The whole reason this evaluates per split. "In CDIA" and "is not
    /// reconciled" are both true of this transaction — but of *different*
    /// splits. GnuCash finds nothing here, and so must we. Rolling the test up
    /// to the transaction would wrongly match.
    @Test("Every criterion must hold for the same split")
    func sameSplitMustSatisfyEveryCriterion() throws {
        let (book, cdia, agl, _) = book()
        _ = shareBuy(book, cdia, agl)

        let query = FindQuery(criteria: [
            FindCriterion(test: .account(.isOneOf, [cdia.guid])),
            FindCriterion(test: .reconcile(.isOneOf, [.notReconciled])),
        ])

        #expect(book.splitsMatching(query).isEmpty,
                "the CDIA split is reconciled; the unreconciled split is AGL's")
    }

    @Test("The same criteria match when one split satisfies both")
    func oneSplitSatisfyingBothMatches() throws {
        let (book, cdia, agl, _) = book()
        _ = shareBuy(book, cdia, agl)

        let query = FindQuery(criteria: [
            FindCriterion(test: .account(.isOneOf, [cdia.guid])),
            FindCriterion(test: .reconcile(.isOneOf, [.reconciled])),
        ])

        let hits = book.splitsMatching(query)
        #expect(hits.count == 1)
        #expect(hits.first?.account?.name == "CDIA")
    }

    /// "any" is also per split — it must not become "any criterion, any split".
    @Test("Matching any criterion still tests one split at a time")
    func anyIsStillPerSplit() throws {
        let (book, cdia, agl, _) = book()
        _ = shareBuy(book, cdia, agl)

        let query = FindQuery(criteria: [
            FindCriterion(test: .account(.isOneOf, [cdia.guid])),
            FindCriterion(test: .text(.memo, .contains, "parcel", matchCase: false)),
        ], matchAll: false)

        let hits = book.splitsMatching(query)
        #expect(hits.count == 2, "the CDIA split by account, the AGL split by memo")
    }

    // MARK: Transaction-level fields through a split

    @Test("Description, notes and number read through the parent transaction")
    func transactionFieldsAreVisibleFromSplits() throws {
        let (book, cdia, agl, _) = book()
        _ = shareBuy(book, cdia, agl)

        for test in [FindTest.text(.description, .contains, "AGL buy", matchCase: false),
                     .text(.notes, .contains, "CommSec", matchCase: false),
                     .text(.number, .matchesExactly, "T-900", matchCase: false)] {
            let hits = book.splitsMatching(FindQuery(criteria: [FindCriterion(test: test)]))
            #expect(hits.count == 2, "both splits share the transaction: \(test)")
        }
    }

    @Test("Description, Notes, or Memo searches all three")
    func combinedTextField() throws {
        let (book, cdia, agl, _) = book()
        _ = shareBuy(book, cdia, agl)

        // "parcel" is only a memo, and only on one split.
        let memoHit = book.splitsMatching(FindQuery(criteria: [
            FindCriterion(test: .text(.descriptionNotesOrMemo, .contains, "parcel", matchCase: false))]))
        #expect(memoHit.count == 1)

        // "CommSec" is only in the notes, which both splits share.
        let notesHit = book.splitsMatching(FindQuery(criteria: [
            FindCriterion(test: .text(.descriptionNotesOrMemo, .contains, "CommSec", matchCase: false))]))
        #expect(notesHit.count == 2)
    }

    /// "does not contain" on the combined field must mean *none of* the three,
    /// not "some field lacks it" — every split has fields that lack any needle.
    @Test("Does not contain means none of the fields contain it")
    func doesNotContainIsNoneOf() throws {
        let (book, cdia, agl, _) = book()
        _ = shareBuy(book, cdia, agl)

        let hits = book.splitsMatching(FindQuery(criteria: [
            FindCriterion(test: .text(.descriptionNotesOrMemo, .doesNotContain, "parcel", matchCase: false))]))
        #expect(hits.count == 1, "only the split whose every field lacks 'parcel'")
        #expect(hits.first?.memo == "settlement")
    }

    // MARK: Case

    @Test("Match case is honoured both ways")
    func matchCase() throws {
        let (book, cdia, agl, _) = book()
        _ = shareBuy(book, cdia, agl)

        let insensitive = book.splitsMatching(FindQuery(criteria: [
            FindCriterion(test: .text(.description, .contains, "agl BUY", matchCase: false))]))
        #expect(insensitive.count == 2)

        let sensitive = book.splitsMatching(FindQuery(criteria: [
            FindCriterion(test: .text(.description, .contains, "agl BUY", matchCase: true))]))
        #expect(sensitive.isEmpty)
    }

    // MARK: Dates

    /// A posting stamped mid-afternoon is still "on" that day. Comparing
    /// instants instead of days would drop it.
    @Test("Dates compare by day, not by instant")
    func datesCompareByDay() throws {
        let book = Book()
        let cdia = Account(name: "CDIA", type: .bank, commodity: .aud)
        let fees = Account(name: "Fees", type: .expense, commodity: .aud)
        book.rootAccount.addChild(cdia)
        book.rootAccount.addChild(fees)
        let txn = Transaction(currency: .aud, datePosted: day(2026, 4, 28, hour: 15), description: "Fee")
        txn.addSplit(account: cdia, value: dec("-10"))
        txn.addSplit(account: fees, value: dec("10"))
        book.addTransaction(txn)

        func hits(_ c: DateComparator) -> Int {
            book.splitsMatching(FindQuery(criteria: [
                FindCriterion(test: .date(.posted, c, day(2026, 4, 28)))])).count
        }
        #expect(hits(.isOn) == 2, "15:00 on the 28th is on the 28th")
        #expect(hits(.isNotOn) == 0)
        #expect(hits(.isBeforeOrOn) == 2)
        #expect(hits(.isOnOrAfter) == 2)
        #expect(hits(.isBefore) == 0, "not before its own day")
        #expect(hits(.isAfter) == 0)
    }

    @Test("Reconciled Date only matches splits that have one")
    func reconciledDateSkipsUnreconciled() throws {
        let (book, cdia, agl, _) = book()
        let txn = shareBuy(book, cdia, agl)
        txn.splits[0].reconcileDate = day(2026, 5, 1)

        let hits = book.splitsMatching(FindQuery(criteria: [
            FindCriterion(test: .date(.reconciled, .isOn, day(2026, 5, 1)))]))
        #expect(hits.count == 1)
        #expect(hits.first?.account?.name == "CDIA")
    }

    // MARK: Numbers

    @Test("Shares and value are different questions")
    func sharesAndValue() throws {
        let (book, cdia, agl, _) = book()
        _ = shareBuy(book, cdia, agl)

        let byShares = book.splitsMatching(FindQuery(criteria: [
            FindCriterion(test: .number(.shares, .equalTo, dec("11600")))]))
        #expect(byShares.count == 1, "only the AGL leg holds 11,600 shares")
        #expect(byShares.first?.account?.name == "AGL")

        let byValue = book.splitsMatching(FindQuery(criteria: [
            FindCriterion(test: .number(.value, .lessThan, dec("0")))]))
        #expect(byValue.count == 1, "only the cash leg is negative")
        #expect(byValue.first?.account?.name == "CDIA")
    }

    /// A cash split has no share price. Treating it as zero would sweep every
    /// cash posting in the book into "price is less than $1".
    @Test("A zero-quantity split has no share price, not a price of zero")
    func sharePriceUndefinedForZeroQuantity() throws {
        let book = Book()
        let cdia = Account(name: "CDIA", type: .bank, commodity: .aud)
        let equity = Account(name: "Opening", type: .equity, commodity: .aud)
        book.rootAccount.addChild(cdia)
        book.rootAccount.addChild(equity)
        let txn = Transaction(currency: .aud, datePosted: day(2026, 1, 1), description: "Zero")
        txn.addSplit(account: cdia, value: dec("0"), quantity: dec("0"))
        txn.addSplit(account: equity, value: dec("0"), quantity: dec("0"))
        book.addTransaction(txn)

        let hits = book.splitsMatching(FindQuery(criteria: [
            FindCriterion(test: .number(.sharePrice, .lessThan, dec("1")))]))
        #expect(hits.isEmpty)
    }

    @Test("Share price is value over quantity")
    func sharePrice() throws {
        let (book, cdia, agl, _) = book()
        _ = shareBuy(book, cdia, agl)

        let atOne = book.splitsMatching(FindQuery(criteria: [
            FindCriterion(test: .number(.sharePrice, .equalTo, dec("1")))]))
        #expect(atOne.count == 2, "both legs are 1:1 here")
    }

    // MARK: Sets

    @Test("Reconcile is-not excludes the listed states")
    func reconcileIsNot() throws {
        let (book, cdia, agl, _) = book()
        _ = shareBuy(book, cdia, agl)

        let hits = book.splitsMatching(FindQuery(criteria: [
            FindCriterion(test: .reconcile(.isNotOneOf, [.reconciled]))]))
        #expect(hits.count == 1)
        #expect(hits.first?.account?.name == "AGL")
    }

    @Test("Account is-not excludes the listed accounts")
    func accountIsNot() throws {
        let (book, cdia, agl, _) = book()
        _ = shareBuy(book, cdia, agl)

        let hits = book.splitsMatching(FindQuery(criteria: [
            FindCriterion(test: .account(.isNotOneOf, [cdia.guid]))]))
        #expect(hits.count == 1)
        #expect(hits.first?.account?.name == "AGL")
    }

    // MARK: Degenerate queries

    /// An empty Find dialog must not answer "everything". Returning all 46,553
    /// transactions because the user opened a dialog and pressed Find is not a
    /// search result, it is an accident.
    @Test("A query with no criteria matches nothing")
    func emptyQueryMatchesNothing() throws {
        let (book, cdia, agl, _) = book()
        _ = shareBuy(book, cdia, agl)

        #expect(FindQuery().isEmpty)
        #expect(book.splitsMatching(FindQuery()).isEmpty)
        #expect(book.splitsMatching(FindQuery(criteria: [], matchAll: false)).isEmpty)
    }

    @Test("An empty needle contains everything, as substring search does")
    func emptyNeedle() throws {
        let (book, cdia, agl, _) = book()
        _ = shareBuy(book, cdia, agl)

        let hits = book.splitsMatching(FindQuery(criteria: [
            FindCriterion(test: .text(.description, .contains, "", matchCase: false))]))
        #expect(hits.count == 2)
    }

    @Test("Balanced finds unbalanced transactions")
    func balanced() throws {
        let (book, cdia, agl, _) = book()
        _ = shareBuy(book, cdia, agl)

        #expect(book.splitsMatching(FindQuery(criteria: [
            FindCriterion(test: .balanced(true))])).count == 2)
        #expect(book.splitsMatching(FindQuery(criteria: [
            FindCriterion(test: .balanced(false))])).isEmpty)
    }
}
