//
//  ReportPeriodTests.swift
//  FinvestLens — Reports
//
//  The FY arithmetic is the part with wrong answers: a July financial year
//  containing 30 June belongs to the *previous* year's start, and one
//  containing 1 July to that same day. Off-by-one here misfiles a whole year
//  of postings, so every boundary gets a test with a fixed "today".
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import FinvestLensReports

@Suite("Report periods")
struct ReportPeriodTests {

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        utc.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    private func days(of period: ReportPeriod, fy: Int, today: Date) -> (String, String) {
        let (from, to) = period.resolve(financialYearStartMonth: fy, today: today, calendar: utc)
        let formatter = DateFormatter()
        formatter.calendar = utc
        formatter.timeZone = utc.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return (formatter.string(from: from), formatter.string(from: to))
    }

    // MARK: Financial years (the Australian July–June convention)

    @Test("Mid-July sits in the FY that just began")
    func julyFY() {
        let (from, to) = days(of: .currentFinancialYear, fy: 7, today: date(2026, 7, 17))
        #expect(from == "2026-07-01")
        #expect(to == "2027-06-30")
    }

    /// The boundary that misfiles a year when wrong.
    @Test("30 June belongs to the FY that started last July")
    func juneThirtieth() {
        let (from, to) = days(of: .currentFinancialYear, fy: 7, today: date(2026, 6, 30))
        #expect(from == "2025-07-01")
        #expect(to == "2026-06-30")
    }

    @Test("1 July belongs to the FY starting that day")
    func julyFirst() {
        let (from, to) = days(of: .currentFinancialYear, fy: 7, today: date(2026, 7, 1))
        #expect(from == "2026-07-01")
        #expect(to == "2027-06-30")
    }

    @Test("The previous FY is exactly one year earlier")
    func previousFY() {
        let (from, to) = days(of: .previousFinancialYear, fy: 7, today: date(2026, 7, 17))
        #expect(from == "2025-07-01")
        #expect(to == "2026-06-30")
    }

    @Test("A January FY start is the calendar year")
    func januaryFY() {
        let (from, to) = days(of: .currentFinancialYear, fy: 1, today: date(2026, 7, 17))
        #expect(from == "2026-01-01")
        #expect(to == "2026-12-31")
    }

    // MARK: Calendar periods

    @Test("Year to date runs from 1 January to today")
    func yearToDate() {
        let (from, to) = days(of: .calendarYearToDate, fy: 7, today: date(2026, 7, 17))
        #expect(from == "2026-01-01")
        #expect(to == "2026-07-17")
    }

    @Test("Previous month crosses the year boundary")
    func previousMonthAcrossYear() {
        let (from, to) = days(of: .previousMonth, fy: 7, today: date(2026, 1, 15))
        #expect(from == "2025-12-01")
        #expect(to == "2025-12-31")
    }

    @Test("The quarter is the calendar quarter containing today")
    func quarter() {
        let (from, to) = days(of: .currentQuarter, fy: 7, today: date(2026, 8, 2))
        #expect(from == "2026-07-01")
        #expect(to == "2026-09-30")
    }

    @Test("February's month end is February's, leap or not")
    func februaryEnd() {
        let (_, to) = days(of: .currentMonth, fy: 7, today: date(2024, 2, 10))
        #expect(to == "2024-02-29")
        let (_, to25) = days(of: .currentMonth, fy: 7, today: date(2025, 2, 10))
        #expect(to25 == "2025-02-28")
    }

    // MARK: Bounds and labels

    /// `to` is the last instant of its day, so a posting stamped that evening
    /// is inside the period — the same inclusive rule every report applies.
    @Test("The end bound covers the whole final day")
    func endOfDayInclusive() {
        let (_, to) = ReportPeriod.currentMonth.resolve(financialYearStartMonth: 7,
                                                        today: date(2026, 7, 17), calendar: utc)
        let eveningPosting = utc.date(from: DateComponents(
            year: 2026, month: 7, day: 31, hour: 23, minute: 30))!
        #expect(eveningPosting <= to)
    }

    @Test("A July FY labels as a split year, a January FY as one")
    func labels() {
        #expect(ReportPeriod.currentFinancialYear
            .label(financialYearStartMonth: 7, today: date(2026, 7, 17), calendar: utc)
            == "FY 2026–27")
        #expect(ReportPeriod.currentFinancialYear
            .label(financialYearStartMonth: 1, today: date(2026, 7, 17), calendar: utc)
            == "FY 2026")
        #expect(ReportPeriod.currentQuarter
            .label(financialYearStartMonth: 7, today: date(2026, 8, 2), calendar: utc)
            == "Q3 2026")
    }

    @Test("A period name survives a Codable round-trip")
    func codable() throws {
        for period in ReportPeriod.named + [.custom(from: date(2025, 1, 1), to: date(2025, 6, 30))] {
            let data = try JSONEncoder().encode(period)
            let back = try JSONDecoder().decode(ReportPeriod.self, from: data)
            #expect(back == period)
        }
    }
}
