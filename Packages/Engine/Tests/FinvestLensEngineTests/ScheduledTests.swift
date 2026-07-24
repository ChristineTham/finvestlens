//
//  ScheduledTests.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensEngine

private var utc: Calendar {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
}
private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
    utc.date(from: DateComponents(year: y, month: m, day: d))!
}

@Suite("Recurrence")
struct RecurrenceTests {

    @Test("Monthly occurrences step by month")
    func monthly() {
        let r = Recurrence(period: .monthly, interval: 1, startDate: date(2026, 1, 15))
        let dates = r.occurrences(since: nil, through: date(2026, 4, 15))
        #expect(dates == [date(2026, 1, 15), date(2026, 2, 15), date(2026, 3, 15), date(2026, 4, 15)])
    }

    @Test("Weekly with interval")
    func fortnightly() {
        let r = Recurrence(period: .weekly, interval: 2, startDate: date(2026, 1, 1))
        let dates = r.occurrences(since: nil, through: date(2026, 1, 31))
        #expect(dates == [date(2026, 1, 1), date(2026, 1, 15), date(2026, 1, 29)])
    }

    @Test("since excludes already-generated occurrences")
    func sinceExcludes() {
        let r = Recurrence(period: .monthly, startDate: date(2026, 1, 15))
        let dates = r.occurrences(since: date(2026, 2, 15), through: date(2026, 4, 15))
        #expect(dates == [date(2026, 3, 15), date(2026, 4, 15)])
    }

    @Test("next occurrence strictly after a date")
    func next() {
        let r = Recurrence(period: .monthly, startDate: date(2026, 1, 15))
        #expect(r.next(after: date(2026, 1, 15)) == date(2026, 2, 15))
        #expect(r.next(after: date(2026, 1, 10)) == date(2026, 1, 15))
    }

    @Test("Monthly on the 31st re-anchors instead of drifting (GnuCash parity)")
    func monthEndNoDrift() {
        let r = Recurrence(period: .monthly, startDate: date(2025, 1, 31))
        let dates = r.occurrences(since: nil, through: date(2025, 6, 30))
        #expect(dates == [date(2025, 1, 31), date(2025, 2, 28), date(2025, 3, 31),
                          date(2025, 4, 30), date(2025, 5, 31), date(2025, 6, 30)])
    }

    @Test("Yearly from Feb 29 restores the leap day (GnuCash parity)")
    func leapYearAnchor() {
        let r = Recurrence(period: .yearly, startDate: date(2020, 2, 29))
        let dates = r.occurrences(since: nil, through: date(2024, 3, 1))
        #expect(dates == [date(2020, 2, 29), date(2021, 2, 28), date(2022, 2, 28),
                          date(2023, 2, 28), date(2024, 2, 29)])
    }

    @Test("End-of-month snaps the start and tracks each month's last day")
    func endOfMonth() {
        let r = Recurrence(period: .endOfMonth, startDate: date(2025, 1, 30))
        #expect(r.startDate == date(2025, 1, 31))     // aligned to last day
        let dates = r.occurrences(since: nil, through: date(2025, 4, 30))
        #expect(dates == [date(2025, 1, 31), date(2025, 2, 28),
                          date(2025, 3, 31), date(2025, 4, 30)])
    }

    @Test("Nth-weekday keeps the 3rd Tuesday each month")
    func nthWeekday() {
        // 2025-01-21 is the 3rd Tuesday of January.
        let r = Recurrence(period: .nthWeekday, startDate: date(2025, 1, 21))
        let dates = r.occurrences(since: nil, through: date(2025, 4, 30))
        #expect(dates == [date(2025, 1, 21), date(2025, 2, 18),
                          date(2025, 3, 18), date(2025, 4, 15)])
    }

    @Test("Last-weekday keeps the last Friday each month")
    func lastWeekday() {
        // 2025-01-31 is the last Friday of January.
        let r = Recurrence(period: .lastWeekday, startDate: date(2025, 1, 31))
        let dates = r.occurrences(since: nil, through: date(2025, 4, 30))
        #expect(dates == [date(2025, 1, 31), date(2025, 2, 28),
                          date(2025, 3, 28), date(2025, 4, 25)])
    }

    @Test("Once fires exactly once")
    func once() {
        let r = Recurrence(period: .once, startDate: date(2026, 1, 15))
        #expect(r.occurrences(since: nil, through: date(2027, 1, 1)) == [date(2026, 1, 15)])
        #expect(r.next(after: date(2026, 1, 15)) == nil)
        #expect(r.next(after: date(2026, 1, 10)) == date(2026, 1, 15))
    }

    @Test("Weekend-adjust moves a weekend occurrence off the weekend")
    func weekendAdjust() {
        // The 15th of March 2025 is a Saturday.
        let back = Recurrence(period: .monthly, startDate: date(2025, 3, 15), weekendAdjust: .back)
        #expect(back.next(after: date(2025, 2, 20)) == date(2025, 3, 14))   // → Friday
        let fwd = Recurrence(period: .monthly, startDate: date(2025, 3, 15), weekendAdjust: .forward)
        #expect(fwd.next(after: date(2025, 2, 20)) == date(2025, 3, 17))    // → Monday
    }
}

@Suite("Scheduled transaction")
struct ScheduledTransactionTests {

    private func makeBook() -> (Book, expense: GncGUID, bank: GncGUID) {
        let book = Book(baseCurrency: .aud)
        let bank = book.addAccount(Account(name: "Bank", type: .bank, commodity: .aud))
        let rent = book.addAccount(Account(name: "Rent", type: .expense, commodity: .aud))
        return (book, rent.guid, bank.guid)
    }

    private func rentSX(_ expense: GncGUID, _ bank: GncGUID) -> ScheduledTransaction {
        ScheduledTransaction(
            name: "Rent", currency: .aud, description: "Monthly rent",
            recurrence: Recurrence(period: .monthly, startDate: date(2026, 1, 1)),
            splits: [
                ScheduledSplit(accountGUID: expense, value: Decimal(500)),
                ScheduledSplit(accountGUID: bank, value: Decimal(-500)),
            ]
        )
    }

    @Test("Template balances and lists due dates")
    func dueDates() {
        let (_, expense, bank) = makeBook()
        let sx = rentSX(expense, bank)
        #expect(sx.isBalanced)
        #expect(sx.dueDates(through: date(2026, 3, 1)).count == 3)   // Jan, Feb, Mar
    }

    @Test("Scheduled-split formulas resolve variables at instantiation (FR-SCH-02)")
    func splitFormulas() {
        let (book, expense, bank) = makeBook()
        // A loan payment split by formula: principal + interest to the bank,
        // matched by the expense legs — variables supplied at post time.
        let sx = ScheduledTransaction(
            name: "Loan payment", currency: .aud,
            recurrence: Recurrence(period: .monthly, startDate: date(2026, 1, 1)),
            splits: [
                ScheduledSplit(accountGUID: expense, value: 0, formula: "principal + interest"),
                ScheduledSplit(accountGUID: bank, value: 0, formula: "-(principal + interest)"),
            ])

        #expect(sx.variableNames == ["interest", "principal"])

        let vars = ["principal": Decimal(800), "interest": Decimal(200)]
        let txn = try! #require(ScheduledTransactionService.post(
            sx, date: date(2026, 1, 1), into: book, variables: vars))
        let toExpense = txn.splits.first { $0.account?.guid == expense }
        #expect(toExpense?.value == Decimal(1000))
        #expect(txn.isBalanced)
    }

    @Test("Advance-create days create instances ahead of their due date")
    func advanceCreate() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let sx = ScheduledTransaction(
            name: "Rent", currency: .aud,
            recurrence: Recurrence(period: .monthly, startDate: date(2026, 1, 15)),
            splits: [ScheduledSplit(accountGUID: .random(), value: 0)],
            advanceCreateDays: 5)
        // Asking through Feb 12 — three days before the Feb 15 occurrence. The
        // 5-day advance window pulls Feb 15 in; without it only Jan 15 shows.
        let due = sx.dueDates(through: date(2026, 2, 12), calendar: cal)
        #expect(due == [date(2026, 1, 15), date(2026, 2, 15)])

        var noAdvance = sx; noAdvance.advanceCreateDays = 0
        #expect(noAdvance.dueDates(through: date(2026, 2, 12), calendar: cal) == [date(2026, 1, 15)])
    }

    @Test("Advance-remind lists upcoming instances without creating them")
    func advanceRemind() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let sx = ScheduledTransaction(
            name: "Rent", currency: .aud,
            recurrence: Recurrence(period: .monthly, startDate: date(2026, 1, 15)),
            splits: [ScheduledSplit(accountGUID: .random(), value: 0)],
            advanceRemindDays: 10)
        // Through Feb 10, remind window reaches Feb 20 → the Feb 15 occurrence.
        #expect(sx.remindDates(through: date(2026, 2, 10), calendar: cal) == [date(2026, 2, 15)])
    }

    @Test("Posting creates a balanced transaction in the book")
    func post() throws {
        let (book, expense, bank) = makeBook()
        let sx = rentSX(expense, bank)
        let txn = try #require(ScheduledTransactionService.post(sx, date: date(2026, 1, 1), into: book))
        #expect(txn.isBalanced)
        #expect(book.transactions.count == 1)
        let rentAccount = try #require(book.account(with: expense))
        #expect(book.balance(of: rentAccount).amount == Decimal(500))
    }

    @Test("Pending aggregates and sorts across schedules")
    func pending() {
        let (_, expense, bank) = makeBook()
        let sx = rentSX(expense, bank)
        let pending = ScheduledTransactionService.pending([sx], through: date(2026, 2, 15))
        #expect(pending.count == 2)
        #expect(pending.first?.date == date(2026, 1, 1))
    }
}

@Suite("Recurrence gaps")
struct RecurrenceGapTests {

    @Test("Daily recurrence with a multiplier")
    func daily() {
        let r = Recurrence(period: .daily, interval: 3, startDate: date(2026, 1, 1))
        #expect(r.occurrences(since: nil, through: date(2026, 1, 10)) ==
                [date(2026, 1, 1), date(2026, 1, 4), date(2026, 1, 7), date(2026, 1, 10)])
        #expect(r.next(after: date(2026, 1, 2)) == date(2026, 1, 4))
    }

    @Test("Quarterly (monthly interval 3) re-anchors to month end")
    func quarterly() {
        let r = Recurrence(period: .monthly, interval: 3, startDate: date(2026, 1, 31))
        #expect(r.occurrences(since: nil, through: date(2026, 8, 1)) ==
                [date(2026, 1, 31), date(2026, 4, 30), date(2026, 7, 31)])
    }

    @Test("Every second year from a leap day")
    func biennial() {
        let r = Recurrence(period: .yearly, interval: 2, startDate: date(2024, 2, 29))
        #expect(r.next(after: date(2024, 3, 1)) == date(2026, 2, 28))
    }

    @Test("The general monthly step covers a mid-month reference")
    func midMonthReference() {
        let r = Recurrence(period: .monthly, startDate: date(2026, 1, 15))
        #expect(r.next(after: date(2026, 3, 1)) == date(2026, 3, 15))
    }

    @Test("Interval clamps: zero-interval repeats every period; once has none")
    func intervalClamp() {
        #expect(Recurrence(period: .monthly, interval: 0, startDate: date(2026, 1, 1)).interval == 1)
        #expect(Recurrence(period: .once, interval: 5, startDate: date(2026, 1, 1)).interval == 0)
    }

    @Test("Weekend adjustment is meaningless for weekly and is dropped")
    func weekendAdjustDropped() {
        let weekly = Recurrence(period: .weekly, startDate: date(2026, 1, 1), weekendAdjust: .back)
        #expect(weekly.weekendAdjust == .none)
        let monthly = Recurrence(period: .monthly, startDate: date(2026, 1, 1), weekendAdjust: .back)
        #expect(monthly.weekendAdjust == .back)
    }

    @Test("A 5th-weekday start becomes a last-weekday rule")
    func fifthWeekBecomesLast() {
        // 2025-05-30 is the fifth Friday of May.
        let r = Recurrence(period: .nthWeekday, startDate: date(2025, 5, 30))
        #expect(r.period == .lastWeekday)
        #expect(r.next(after: date(2025, 5, 30)) == date(2025, 6, 27))   // last Friday of June
    }

    @Test("A last-weekday start is normalised into the final week")
    func lastWeekdayNormalised() {
        // 2025-01-03 is a Friday; the rule means "last Friday", so the anchor
        // snaps forward to 2025-01-31.
        let r = Recurrence(period: .lastWeekday, startDate: date(2025, 1, 3))
        #expect(r.startDate == date(2025, 1, 31))
    }

    @Test("Weekend-back monthly: Friday look-ahead around a Saturday anchor")
    func weekendBackMonthly() {
        // Anchor the 15th; March 15 2025 is a Saturday, adjusted back to the 14th.
        let r = Recurrence(period: .monthly, startDate: date(2025, 3, 15), weekendAdjust: .back)
        // From the adjusted Friday occurrence, the next is April's (weekday) 15th.
        #expect(r.next(after: date(2025, 3, 14)) == date(2025, 4, 15))
        // A weekend reference is pulled back to Friday first — same answer.
        #expect(r.next(after: date(2025, 3, 16)) == date(2025, 4, 15))
        // A Friday early in the month: this month's occurrence is still to come.
        #expect(r.next(after: date(2025, 8, 1)) == date(2025, 8, 15))
        // A Friday after the anchor day steps a full month.
        #expect(r.next(after: date(2025, 3, 21)) == date(2025, 4, 15))
    }

    @Test("Weekend-back monthly: Sunday anchor reached through the Friday look-ahead")
    func weekendBackSundayAnchor() {
        // June 15 2025 is a Sunday → occurrences fall on Friday the 13th.
        let r = Recurrence(period: .monthly, startDate: date(2025, 6, 15), weekendAdjust: .back)
        #expect(r.next(after: date(2025, 6, 13)) == date(2025, 7, 15))
        #expect(r.next(after: date(2025, 6, 20)) == date(2025, 7, 15))
    }

    @Test("Weekend-back monthly from the 31st hops the short months")
    func weekendBack31st() {
        let r = Recurrence(period: .monthly, startDate: date(2025, 1, 31), weekendAdjust: .back)
        // From Friday Feb 28 (last of month) the next is Monday March 31.
        #expect(r.next(after: date(2025, 2, 28)) == date(2025, 3, 31))
    }

    @Test("Weekend-back yearly looks past a Friday month-end")
    func weekendBackYearly() {
        let r = Recurrence(period: .yearly, startDate: date(2025, 6, 30), weekendAdjust: .back)
        // 2026-02-27 is a Friday whose Saturday closes February.
        #expect(r.next(after: date(2026, 2, 27)) == date(2026, 6, 30))
        // 2027-02-26 is a Friday whose Sunday closes February.
        #expect(r.next(after: date(2027, 2, 26)) == date(2027, 6, 30))
    }

    @Test("Weekend-back end-of-month walks Fridays and month ends")
    func weekendBackEndOfMonth() {
        let r = Recurrence(period: .endOfMonth, startDate: date(2025, 5, 15), weekendAdjust: .back)
        #expect(r.startDate == date(2025, 5, 31))          // snapped to month end
        // May 31 2025 is a Saturday → the occurrence is Friday May 30.
        #expect(r.next(after: date(2025, 5, 1)) == date(2025, 5, 30))
        // From that Friday, June's occurrence is Monday June 30.
        #expect(r.next(after: date(2025, 5, 30)) == date(2025, 6, 30))
        // A mid-month Friday still finds this month's end.
        #expect(r.next(after: date(2025, 6, 6)) == date(2025, 6, 30))
        // Friday Oct 31 is itself an occurrence; November's lands on Friday the
        // 28th because the 30th is a Sunday.
        #expect(r.next(after: date(2025, 10, 31)) == date(2025, 11, 28))
        // A weekend reference: Sunday Nov 30 pulls back to Friday, then steps on.
        #expect(r.next(after: date(2025, 11, 30)) == date(2025, 12, 31))
    }

    @Test("Occurrences: a start after the horizon yields nothing; limit caps the walk")
    func occurrenceBounds() {
        let r = Recurrence(period: .daily, startDate: date(2026, 6, 1))
        #expect(r.occurrences(since: nil, through: date(2026, 5, 1)).isEmpty)
        #expect(r.occurrences(since: nil, through: date(2027, 1, 1), limit: 3).count == 3)
    }

    @Test("Period nouns and display names")
    func periodNames() {
        #expect(RecurrencePeriod.allCases.map(\.unitNoun) ==
                ["day", "week", "month", "year", "occurrence", "month", "month", "month"])
        #expect(RecurrencePeriod.allCases.map(\.displayName) ==
                ["Daily", "Weekly", "Monthly", "Yearly", "Once",
                 "Monthly (last day)", "Monthly (same weekday)", "Monthly (last weekday)"])
    }

    @Test("Decoding tolerates books saved before interval and weekend-adjust")
    func legacyDecode() throws {
        let json = #"{"period":"monthly","startDate":0}"#
        let r = try JSONDecoder().decode(Recurrence.self, from: Data(json.utf8))
        #expect(r.period == .monthly)
        #expect(r.interval == 1)
        #expect(r.weekendAdjust == .none)
        #expect(r.startDate == Date(timeIntervalSinceReferenceDate: 0))
    }

    @Test("A decoded end-of-month start re-aligns to the month's last day")
    func decodeRealigns() throws {
        let mid = date(2025, 1, 15).timeIntervalSinceReferenceDate
        let json = #"{"period":"end-of-month","interval":2,"startDate":\#(mid)}"#
        let r = try JSONDecoder().decode(Recurrence.self, from: Data(json.utf8))
        #expect(r.startDate == date(2025, 1, 31))
        #expect(r.interval == 2)
    }

    @Test("Codable round-trip preserves the rule")
    func roundTrip() throws {
        let r = Recurrence(period: .monthly, interval: 3,
                           startDate: date(2026, 1, 31), weekendAdjust: .forward)
        let back = try JSONDecoder().decode(Recurrence.self, from: JSONEncoder().encode(r))
        #expect(back == r)
    }
}

@Suite("Scheduled transaction gaps")
struct ScheduledTransactionGapTests {

    private var utcCal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    @Test("Formula resolution falls back to the fixed value")
    func resolvedValue() {
        let split = ScheduledSplit(accountGUID: .random(), value: Decimal(42))
        #expect(split.resolvedValue() == 42)
        var formulaic = split
        formulaic.formula = "2 * 3"
        #expect(formulaic.resolvedValue() == 6)
        formulaic.formula = "x + 1"
        #expect(formulaic.resolvedValue() == 42)                      // unbound → fixed value
        #expect(formulaic.resolvedValue(variables: ["x": 9]) == 10)
        formulaic.formula = ""
        #expect(formulaic.resolvedValue() == 42)
    }

    @Test("Template balance tolerates sub-minor residue (ADR-1)")
    func templateBalance() {
        var sx = ScheduledTransaction(
            name: "T", currency: .aud,
            recurrence: Recurrence(period: .monthly, startDate: date(2026, 1, 1)),
            splits: [ScheduledSplit(accountGUID: .random(), value: Decimal(string: "100")!),
                     ScheduledSplit(accountGUID: .random(), value: Decimal(string: "-99.996")!)])
        #expect(sx.isBalanced)
        sx.splits[1].value = Decimal(string: "-99.99")!
        #expect(!sx.isBalanced)
    }

    @Test("A disabled schedule is due nothing and reminds of nothing")
    func disabled() {
        var sx = ScheduledTransaction(
            name: "T", currency: .aud,
            recurrence: Recurrence(period: .monthly, startDate: date(2026, 1, 1)),
            splits: [], isEnabled: false, advanceRemindDays: 10)
        #expect(sx.dueDates(through: date(2026, 3, 1), calendar: utcCal).isEmpty)
        #expect(sx.remindDates(through: date(2026, 3, 1), calendar: utcCal).isEmpty)
        sx.isEnabled = true
        #expect(!sx.dueDates(through: date(2026, 3, 1), calendar: utcCal).isEmpty)
    }

    @Test("Reminding inside the create horizon reminds of nothing")
    func remindWithinCreateHorizon() {
        // Creation looks 15 days out; reminding only 10 → nothing extra to say.
        let sx = ScheduledTransaction(
            name: "T", currency: .aud,
            recurrence: Recurrence(period: .monthly, startDate: date(2026, 1, 15)),
            splits: [ScheduledSplit(accountGUID: .random(), value: 0)],
            advanceCreateDays: 15, advanceRemindDays: 10)
        #expect(sx.remindDates(through: date(2026, 2, 10), calendar: utcCal).isEmpty)
        // And zero remind days means no reminders at all.
        var noRemind = sx
        noRemind.advanceRemindDays = 0
        #expect(noRemind.remindDates(through: date(2026, 2, 10), calendar: utcCal).isEmpty)
    }

    @Test("Posting fails cleanly when a split's account is missing")
    func postMissingAccount() {
        let book = Book(baseCurrency: .aud)
        let sx = ScheduledTransaction(
            name: "T", currency: .aud,
            recurrence: Recurrence(period: .monthly, startDate: date(2026, 1, 1)),
            splits: [ScheduledSplit(accountGUID: .random(), value: Decimal(10))])
        #expect(ScheduledTransactionService.post(sx, date: date(2026, 1, 1), into: book) == nil)
        #expect(book.transactions.isEmpty)
    }

    @Test("Pending instances carry distinct identities")
    func pendingIdentity() {
        let a = ScheduledTransactionService.PendingInstance(
            scheduledID: .random(), name: "A", date: date(2026, 1, 1))
        let b = ScheduledTransactionService.PendingInstance(
            scheduledID: a.scheduledID, name: "A", date: date(2026, 1, 1))
        #expect(a.id != b.id)
    }

    @Test("Templates saved before formulas and horizons still decode")
    func legacyDecode() throws {
        let acct = GncGUID.random()
        let splitJSON = #"{"accountGUID":"\#(acct.hexString)","value":-500}"#
        let split = try JSONDecoder().decode(ScheduledSplit.self, from: Data(splitJSON.utf8))
        #expect(split.accountGUID == acct)
        #expect(split.value == Decimal(-500))
        #expect(split.memo.isEmpty)
        #expect(split.formula == nil)

        let currency = String(data: try JSONEncoder().encode(Commodity.aud), encoding: .utf8)!
        let recurrence = String(data: try JSONEncoder().encode(
            Recurrence(period: .monthly, startDate: date(2026, 1, 1))), encoding: .utf8)!
        let id = GncGUID.random()
        let sxJSON = """
        {"id":"\(id.hexString)","name":"Rent","currency":\(currency),"recurrence":\(recurrence)}
        """
        let sx = try JSONDecoder().decode(ScheduledTransaction.self, from: Data(sxJSON.utf8))
        #expect(sx.id == id)
        #expect(sx.name == "Rent")
        #expect(sx.transactionDescription.isEmpty)
        #expect(sx.splits.isEmpty)
        #expect(sx.lastPosted == nil)
        #expect(sx.isEnabled)
        #expect(sx.advanceCreateDays == 0)
        #expect(sx.advanceRemindDays == 0)
    }

    @Test("A full template round-trips through Codable")
    func roundTrip() throws {
        let sx = ScheduledTransaction(
            name: "Rent", currency: .aud, description: "Monthly rent",
            recurrence: Recurrence(period: .monthly, startDate: date(2026, 1, 1)),
            splits: [ScheduledSplit(accountGUID: .random(), value: Decimal(500),
                                    memo: "rent", formula: "base * 1.05")],
            lastPosted: date(2026, 2, 1), isEnabled: false,
            advanceCreateDays: 3, advanceRemindDays: 7)
        let back = try JSONDecoder().decode(ScheduledTransaction.self,
                                            from: JSONEncoder().encode(sx))
        #expect(back == sx)
    }
}
