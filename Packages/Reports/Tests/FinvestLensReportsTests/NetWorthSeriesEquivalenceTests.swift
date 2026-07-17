//
//  NetWorthSeriesEquivalenceTests.swift
//  FinvestLens — Reports
//
//  ``FinancialReports/netWorthSeries(_:dates:currency:)`` walks the book once
//  instead of once per account per date. That is a change of algorithm, not of
//  meaning, so what has to be pinned is that the meaning did not move: the
//  reference implementation below is the old shape — ask each account for its
//  balance at each date — and the two must agree exactly, on a book carrying
//  every case that makes the fast path harder than a running total.
//
//  Decimal is exact, so "agree" means equal, not close.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensReports

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }
private func day(_ days: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(days) * 86_400) }

@Suite("Net worth series equivalence")
struct NetWorthSeriesEquivalenceTests {

    /// The old algorithm, kept only here: for each date, for each account, walk
    /// the whole book. Correct and unusably slow — the thing the fast path has
    /// to match.
    private func reference(_ book: Book, dates: [Date], currency: Commodity) -> [NetWorthPoint] {
        let assetTypes: Set<AccountType> = [.asset, .bank, .cash, .stock, .mutualFund, .receivable]
        let liabilityTypes: Set<AccountType> = [.liability, .credit, .payable]
        func total(_ types: Set<AccountType>, _ date: Date) -> Decimal {
            var sum = Decimal(0)
            for account in book.accounts
            where types.contains(account.type) && !account.isPlaceholder {
                if let amount = FinancialReports.convertedDisplayBalance(
                    of: account, in: book, from: nil, to: date,
                    currency: currency, rateDate: date) {
                    sum += amount
                }
            }
            return sum
        }
        return dates.sorted().map { date in
            let assets = total(assetTypes, date)
            let liabilities = total(liabilityTypes, date)
            return NetWorthPoint(date: date,
                                 assets: currency.round(assets),
                                 liabilities: currency.round(liabilities),
                                 netWorth: currency.round(assets - liabilities))
        }
    }

    /// A book with the awkward cases: a foreign-currency account, a security
    /// valued at market, a security with **no** price (must be omitted, not
    /// counted as zero), a voided split (must not count), a placeholder (must
    /// not count), a liability, an account whose balance goes negative, and a
    /// transaction dated after every requested date.
    private func awkwardBook() -> Book {
        let book = Book(baseCurrency: .aud)
        let audBank = Account(name: "AUD Bank", type: .bank, commodity: .aud)
        let usdBank = Account(name: "USD Bank", type: .bank, commodity: .usd)
        let card = Account(name: "Card", type: .credit, commodity: .aud)
        let opening = Account(name: "Opening", type: .equity, commodity: .aud)
        let holder = Account(name: "Investments", type: .asset, commodity: .aud)
        holder.isPlaceholder = true

        let bhpCommodity = Commodity(namespace: .security("ASX"), mnemonic: "BHP",
                                     fullName: "BHP", smallestFraction: 10000)
        let ghostCommodity = Commodity(namespace: .security("ASX"), mnemonic: "GHOST",
                                       fullName: "No price here", smallestFraction: 10000)
        let bhp = Account(name: "BHP", type: .stock, commodity: bhpCommodity)
        let ghost = Account(name: "GHOST", type: .stock, commodity: ghostCommodity)

        book.addAccount(audBank); book.addAccount(usdBank); book.addAccount(card)
        book.addAccount(opening); book.addAccount(holder)
        book.addAccount(bhp, under: holder); book.addAccount(ghost, under: holder)

        book.setExchangeRate(from: .usd, to: .aud, rate: dec("1.50"), date: day(0))
        // A rate that moves: the same holding is worth different amounts at
        // different dates even though its balance never changes.
        book.setExchangeRate(from: .usd, to: .aud, rate: dec("1.60"), date: day(20))
        book.addPrice(Price(commodity: bhpCommodity, currency: .aud, date: day(0), value: dec("40.00")))
        book.addPrice(Price(commodity: bhpCommodity, currency: .aud, date: day(20), value: dec("45.50")))

        let t1 = Transaction(currency: .aud, datePosted: day(1), description: "Open")
        t1.addSplit(account: audBank, value: dec("1000"))
        t1.addSplit(account: opening, value: dec("-1000"))
        book.addTransaction(t1)

        let t2 = Transaction(currency: .usd, datePosted: day(5), description: "USD in")
        t2.addSplit(account: usdBank, value: dec("200"))
        t2.addSplit(account: opening, value: dec("-200"))
        book.addTransaction(t2)

        let t3 = Transaction(currency: .aud, datePosted: day(10), description: "Buy BHP")
        let bhpSplit = Split(account: bhp, value: dec("400"), quantity: dec("10"))
        t3.addSplit(bhpSplit)
        t3.addSplit(account: audBank, value: dec("-400"))
        book.addTransaction(t3)

        let t4 = Transaction(currency: .aud, datePosted: day(11), description: "Buy GHOST")
        t4.addSplit(Split(account: ghost, value: dec("100"), quantity: dec("5")))
        t4.addSplit(account: audBank, value: dec("-100"))
        book.addTransaction(t4)

        // Voided: must not count on either side of the change.
        let t5 = Transaction(currency: .aud, datePosted: day(12), description: "Voided")
        let voided = Split(account: audBank, value: dec("999"), quantity: dec("999"))
        voided.reconcileState = .voided
        t5.addSplit(voided)
        t5.addSplit(account: opening, value: dec("-999"))
        book.addTransaction(t5)

        let t6 = Transaction(currency: .aud, datePosted: day(15), description: "Card spend")
        t6.addSplit(account: card, value: dec("-250"))
        t6.addSplit(account: audBank, value: dec("250"))
        book.addTransaction(t6)

        // After every date asked about: must not leak backwards.
        let t7 = Transaction(currency: .aud, datePosted: day(500), description: "Far future")
        t7.addSplit(account: audBank, value: dec("77777"))
        t7.addSplit(account: opening, value: dec("-77777"))
        book.addTransaction(t7)

        return book
    }

    private let dates = [day(0), day(6), day(11), day(13), day(16), day(25), day(60)]

    @Test("One pass agrees with per-account-per-date, exactly")
    func matchesReference() {
        let book = awkwardBook()
        let fast = FinancialReports.netWorthSeries(book, dates: dates, currency: .aud)
        let slow = reference(book, dates: dates, currency: .aud)
        #expect(fast.count == slow.count)
        for (f, s) in zip(fast, slow) {
            #expect(f.date == s.date)
            #expect(f.assets == s.assets, "assets differ at \(f.date)")
            #expect(f.liabilities == s.liabilities, "liabilities differ at \(f.date)")
            #expect(f.netWorth == s.netWorth, "net worth differs at \(f.date)")
        }
    }

    /// Dates are answered in date order regardless of the order asked, and the
    /// running total must not carry the answer for a later date into an earlier
    /// one. Shuffling the input is what would catch a cursor that never rewinds.
    @Test("Unsorted dates give the same answers as sorted ones")
    func unsortedDates() {
        let book = awkwardBook()
        let sorted = FinancialReports.netWorthSeries(book, dates: dates, currency: .aud)
        let shuffled = FinancialReports.netWorthSeries(book, dates: dates.reversed(), currency: .aud)
        #expect(sorted == shuffled)
    }

    /// A rate moving with no balance moving still moves net worth — the reason
    /// conversion stays per date instead of being hoisted out of the loop. The
    /// two query dates each sit nearer a different price so, under GnuCash's
    /// nearest-in-time source, they resolve to different rates.
    @Test("A moving rate moves net worth even when balances do not")
    func movingRateMovesNetWorth() {
        let book = Book(baseCurrency: .aud)
        let usd = book.addAccount(Account(name: "USD", type: .bank, commodity: .usd))
        let equity = book.addAccount(Account(name: "Equity", type: .equity, commodity: .aud))
        book.setExchangeRate(from: .usd, to: .aud, rate: dec("1.50"), date: day(10))
        book.setExchangeRate(from: .usd, to: .aud, rate: dec("1.60"), date: day(30))
        // The only posting is on day 1 — balances are constant thereafter.
        let t = Transaction(currency: .usd, datePosted: day(1), description: "Open")
        t.addSplit(account: usd, value: dec("100"))
        t.addSplit(account: equity, value: dec("-100"))
        book.addTransaction(t)

        // day 15 is nearer the day-10 rate (1.50); day 35 is nearer day-30 (1.60).
        let series = FinancialReports.netWorthSeries(book, dates: [day(15), day(35)], currency: .aud)
        #expect(series[0].netWorth == dec("150"))
        #expect(series[1].netWorth == dec("160"))
        #expect(series[0].netWorth != series[1].netWorth)
    }

    @Test("An empty date list gives an empty series")
    func noDates() {
        #expect(FinancialReports.netWorthSeries(awkwardBook(), dates: [], currency: .aud).isEmpty)
    }

    @Test("A book with no transactions gives zeroes, not an empty series")
    func emptyBook() {
        let series = FinancialReports.netWorthSeries(Book(baseCurrency: .aud),
                                                     dates: [day(1)], currency: .aud)
        #expect(series.count == 1)
        #expect(series[0].netWorth == 0)
    }
}
