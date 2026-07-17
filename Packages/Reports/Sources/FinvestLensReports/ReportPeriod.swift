//
//  ReportPeriod.swift
//  FinvestLens — Reports
//
//  The timescale vocabulary for reports (`FR-RPT-04`).
//
//  Reports are read by financial year, and a financial year is a convention
//  the book carries — Australia's runs July to June. So a period is a *name*
//  ("previous financial year"), resolved against a start month and today,
//  rather than a pair of dates: a favourite saved as "current FY" should mean
//  the current FY forever, not the one it happened to be when saved.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// A named reporting period, resolvable to concrete dates.
public enum ReportPeriod: Codable, Hashable, Sendable {
    case currentFinancialYear
    case previousFinancialYear
    case calendarYearToDate
    case previousCalendarYear
    case currentQuarter
    case currentMonth
    case previousMonth
    case last12Months
    case allTime
    case custom(from: Date, to: Date)

    /// Everything the selector offers, in menu order. `custom` is absent — it
    /// is entered, not picked.
    public static let named: [ReportPeriod] = [
        .currentFinancialYear, .previousFinancialYear,
        .calendarYearToDate, .previousCalendarYear,
        .currentQuarter, .currentMonth, .previousMonth,
        .last12Months, .allTime,
    ]

    /// The period as concrete, inclusive bounds.
    ///
    /// `from` is the first instant of the first day, `to` the last instant of
    /// the last day — matching every report's inclusive `datePosted <= to`.
    public func resolve(financialYearStartMonth: Int, today: Date,
                        calendar: Calendar = .current) -> (from: Date, to: Date) {
        let startMonth = min(max(financialYearStartMonth, 1), 12)
        let todayStart = calendar.startOfDay(for: today)

        func endOfDay(_ day: Date) -> Date {
            let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))!
            return next.addingTimeInterval(-1)
        }
        func monthStart(year: Int, month: Int) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: 1))!
        }

        let components = calendar.dateComponents([.year, .month], from: todayStart)
        let year = components.year!
        let month = components.month!

        switch self {
        case .currentFinancialYear, .previousFinancialYear:
            // The FY containing today starts at the most recent `startMonth`
            // 1st: this year's if we have reached it, last year's otherwise.
            var fyStart = monthStart(year: month >= startMonth ? year : year - 1,
                                     month: startMonth)
            if self == .previousFinancialYear {
                fyStart = calendar.date(byAdding: .year, value: -1, to: fyStart)!
            }
            let fyEnd = calendar.date(byAdding: DateComponents(year: 1, day: -1), to: fyStart)!
            return (fyStart, endOfDay(fyEnd))

        case .calendarYearToDate:
            return (monthStart(year: year, month: 1), endOfDay(todayStart))

        case .previousCalendarYear:
            let start = monthStart(year: year - 1, month: 1)
            let end = calendar.date(byAdding: DateComponents(year: 1, day: -1), to: start)!
            return (start, endOfDay(end))

        case .currentQuarter:
            let quarterMonth = ((month - 1) / 3) * 3 + 1
            let start = monthStart(year: year, month: quarterMonth)
            let end = calendar.date(byAdding: DateComponents(month: 3, day: -1), to: start)!
            return (start, endOfDay(end))

        case .currentMonth:
            let start = monthStart(year: year, month: month)
            let end = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: start)!
            return (start, endOfDay(end))

        case .previousMonth:
            let thisMonth = monthStart(year: year, month: month)
            let start = calendar.date(byAdding: .month, value: -1, to: thisMonth)!
            let end = calendar.date(byAdding: .day, value: -1, to: thisMonth)!
            return (start, endOfDay(end))

        case .last12Months:
            let start = calendar.date(byAdding: DateComponents(year: -1, day: 1), to: todayStart)!
            return (start, endOfDay(todayStart))

        case .allTime:
            return (.distantPast, endOfDay(todayStart))

        case .custom(let from, let to):
            return (calendar.startOfDay(for: from), endOfDay(to))
        }
    }

    /// What the selector shows — specific enough to check ("FY 2026–27"), not
    /// just the name of the rule.
    public func label(financialYearStartMonth: Int, today: Date,
                      calendar: Calendar = .current) -> String {
        let (from, to) = resolve(financialYearStartMonth: financialYearStartMonth,
                                 today: today, calendar: calendar)
        let fromYear = calendar.component(.year, from: from)
        let toYear = calendar.component(.year, from: to)

        switch self {
        case .currentFinancialYear, .previousFinancialYear:
            // A July–June year is written FY 2026–27; a January year is just
            // the year, because "FY 2026–26" would read as a typo.
            return fromYear == toYear
                ? "FY \(fromYear)"
                : "FY \(fromYear)–\(String(format: "%02d", toYear % 100))"
        case .calendarYearToDate:
            return "\(fromYear) to date"
        case .previousCalendarYear:
            return "\(fromYear)"
        case .currentQuarter:
            let quarter = (calendar.component(.month, from: from) - 1) / 3 + 1
            return "Q\(quarter) \(fromYear)"
        case .currentMonth, .previousMonth:
            return from.formatted(.dateTime.month(.wide).year())
        case .last12Months:
            return "Last 12 months"
        case .allTime:
            return "All time"
        case .custom:
            return "\(from.formatted(date: .abbreviated, time: .omitted)) – "
                + "\(to.formatted(date: .abbreviated, time: .omitted))"
        }
    }

    /// The rule's own name, for the menu ("Current financial year" beside its
    /// resolved label).
    public var name: String {
        switch self {
        case .currentFinancialYear: "This financial year"
        case .previousFinancialYear: "Last financial year"
        case .calendarYearToDate: "This year to date"
        case .previousCalendarYear: "Last calendar year"
        case .currentQuarter: "This quarter"
        case .currentMonth: "This month"
        case .previousMonth: "Last month"
        case .last12Months: "Last 12 months"
        case .allTime: "All time"
        case .custom: "Custom range"
        }
    }
}
