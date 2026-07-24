//
//  Recurrence.swift
//  FinvestLens — Engine
//
//  A repetition rule, ported from GnuCash's `Recurrence` (`libgnucash/engine/
//  Recurrence.cpp`). The core is `nextInstance(after:)`, a faithful port of
//  `recurrenceNextInstance`: from a reference date, step forward one period then
//  back up to the phase of the start date. Re-deriving each occurrence from the
//  start's phase (rather than from the previous occurrence) is what keeps
//  month-end and leap-day schedules from drifting — e.g. monthly from the 31st
//  stays 31/28/31/30, not 31/28/28/28.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The repetition unit of a ``Recurrence`` (GnuCash's `PeriodType`).
public enum RecurrencePeriod: String, Codable, Sendable, CaseIterable {
    case daily
    case weekly
    case monthly
    case yearly
    /// Fires exactly once, on the start date.
    case once
    /// The last day of the month, every N months.
    case endOfMonth = "end-of-month"
    /// The same weekday-in-month as the start (e.g. "3rd Tuesday").
    case nthWeekday = "nth-weekday"
    /// The last given weekday of the month (e.g. "last Friday").
    case lastWeekday = "last-weekday"
}

public extension RecurrencePeriod {
    /// The singular noun for an "every N ___" summary.
    var unitNoun: String {
        switch self {
        case .daily: "day"
        case .weekly: "week"
        case .yearly: "year"
        case .monthly, .endOfMonth, .nthWeekday, .lastWeekday: "month"
        case .once: "occurrence"
        }
    }

    /// A human-facing name for a picker.
    var displayName: String {
        switch self {
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .yearly: "Yearly"
        case .once: "Once"
        case .endOfMonth: "Monthly (last day)"
        case .nthWeekday: "Monthly (same weekday)"
        case .lastWeekday: "Monthly (last weekday)"
        }
    }
}

/// How an occurrence that lands on a weekend is moved (GnuCash's
/// `WeekendAdjust`). Only applies to monthly/end-of-month/yearly recurrences.
public enum WeekendAdjust: String, Codable, Sendable, CaseIterable {
    case none
    /// Move back to the preceding Friday.
    case back
    /// Move forward to the following Monday.
    case forward
}

/// A repetition rule: every `interval` `period`s, phased on `startDate`
/// (GnuCash's `Recurrence`).
public struct Recurrence: Codable, Hashable, Sendable {
    public private(set) var period: RecurrencePeriod
    /// Every N periods (1 = every period; 0 for ``RecurrencePeriod/once``).
    public private(set) var interval: Int
    /// The phase anchor. For the unusual period types this is normalised in
    /// `init` to agree with the type (last-of-month, last week, etc.).
    public private(set) var startDate: Date
    public private(set) var weekendAdjust: WeekendAdjust

    public init(period: RecurrencePeriod, interval: Int = 1, startDate: Date,
                weekendAdjust: WeekendAdjust = .none) {
        self.period = period
        self.interval = period == .once ? 0 : max(1, interval)

        // Phase-align the start to the period type (GnuCash `recurrenceSet`).
        let cal = Self.utcCalendar
        var ymd = YMD(startDate, calendar: cal)
        switch period {
        case .endOfMonth:
            ymd.day = ymd.daysInMonth
        case .lastWeekday:
            while ymd.daysInMonth - ymd.day >= 7 { ymd.addDays(7) }
        case .nthWeekday:
            if (ymd.day - 1) / 7 == 4 { self.period = .lastWeekday }  // 5th week → last
        default:
            break
        }
        self.startDate = ymd.date(timeFrom: startDate, calendar: cal)

        // Weekend adjustment only means something for these types.
        switch self.period {
        case .monthly, .endOfMonth, .yearly: self.weekendAdjust = weekendAdjust
        default: self.weekendAdjust = .none
        }
    }

    // Backward-compatible decoding: books saved before weekend-adjust existed
    // carry no such key, and the persisted start may predate phase-alignment.
    private enum CodingKeys: String, CodingKey {
        case period, interval, startDate, weekendAdjust
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(period: try c.decode(RecurrencePeriod.self, forKey: .period),
                  interval: try c.decodeIfPresent(Int.self, forKey: .interval) ?? 1,
                  startDate: try c.decode(Date.self, forKey: .startDate),
                  weekendAdjust: try c.decodeIfPresent(WeekendAdjust.self, forKey: .weekendAdjust) ?? .none)
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    /// The next occurrence strictly after `ref` (GnuCash `recurrenceNext
    /// Instance`), or `nil` for a spent ``RecurrencePeriod/once``.
    public func nextInstance(after ref: Date, calendar: Calendar? = nil) -> Date? {
        let cal = calendar ?? Self.utcCalendar
        let start = YMD(startDate, calendar: cal)
        let mult = max(1, interval)

        // Before the (weekend-adjusted) start, the next occurrence is the start.
        var adjustedStart = start
        adjustedStart.adjustForWeekend(period: period, wadj: weekendAdjust)
        let refYMD = YMD(ref, calendar: cal)
        if refYMD < adjustedStart {
            return adjustedStart.date(timeFrom: startDate, calendar: cal)
        }

        var next = refYMD

        // Step 1: move forward one period, passing exactly one occurrence.
        switch period {
        case .yearly, .monthly, .nthWeekday, .lastWeekday, .endOfMonth:
            let monthMult = period == .yearly ? mult * 12 : mult
            stepForwardMonthFamily(&next, start: start, monthMult: monthMult)
        case .weekly:
            next.addDays(7 * mult)
        case .daily:
            next.addDays(mult)
        case .once:
            return nil   // ref ≥ start was handled above; nothing further.
        }

        // Step 2: back up to align to the start phase (never as far as we added).
        switch period {
        case .yearly, .monthly, .nthWeekday, .lastWeekday, .endOfMonth:
            let monthMult = period == .yearly ? mult * 12 : mult
            let nMonths = 12 * (next.year - start.year) + (next.month - start.month)
            next.addMonths(-(nMonths % monthMult))
            let dim = next.daysInMonth
            if period == .lastWeekday || period == .nthWeekday {
                let wd = nthWeekdayCompare(start: start, next: next, period: period)
                next.addDays(wd)
            } else if period == .endOfMonth || start.day >= dim {
                next.day = dim
            } else {
                next.day = start.day
            }
            next.adjustForWeekend(period: period, wadj: weekendAdjust)
        case .weekly, .daily:
            let unit = period == .weekly ? 7 * mult : mult
            next.addDays(-(YMD.daysBetween(start, next) % unit))
        case .once:
            break
        }

        return next.date(timeFrom: startDate, calendar: cal)
    }

    /// Occurrence dates strictly after `since` (exclusive) and on/before
    /// `through` (inclusive), anchored at ``startDate``.
    public func occurrences(since: Date?, through: Date,
                            limit: Int = 5000, calendar: Calendar? = nil) -> [Date] {
        let cal = calendar ?? Self.utcCalendar
        guard startDate <= through else { return [] }
        var result: [Date] = []
        // Occurrence 0 is the start — weekend-adjusted like every other
        // occurrence, so this list agrees with `next(after:)`, which answers
        // the adjusted start for any reference before it.
        var seed = YMD(startDate, calendar: cal)
        seed.adjustForWeekend(period: period, wadj: weekendAdjust)
        var date = seed.date(timeFrom: startDate, calendar: cal)
        var iterations = 0
        while date <= through, iterations < limit {
            if since == nil || date > since! { result.append(date) }
            if period == .once { break }
            guard let nxt = nextInstance(after: date, calendar: cal), nxt > date else { break }
            date = nxt
            iterations += 1
        }
        return result
    }

    /// The next occurrence strictly after `date`.
    public func next(after date: Date, calendar: Calendar? = nil) -> Date? {
        nextInstance(after: date, calendar: calendar)
    }

    // MARK: Step 1 helper (month family)

    /// Moves `next` forward, passing exactly one occurrence, for the
    /// month/year/weekday-in-month family. Handles GnuCash's weekend-back
    /// look-ahead so an occurrence pulled back onto Friday still advances once.
    private func stepForwardMonthFamily(_ next: inout YMD, start: YMD, monthMult: Int) {
        let monthlyish = period == .yearly || period == .monthly || period == .endOfMonth

        if weekendAdjust == .back && monthlyish && next.isWeekend {
            // Pull a weekend `next` back to Friday so the checks below line up.
            next.subtractDays(next.gncWeekday == 6 ? 1 : 2)
        }
        if weekendAdjust == .back && monthlyish && next.gncWeekday == 5 {
            var sat = next; sat.addDays(1)
            var sun = next; sun.addDays(2)
            if period == .endOfMonth {
                if next.isLastOfMonth || sat.isLastOfMonth || sun.isLastOfMonth {
                    next.addMonths(monthMult)
                } else {
                    next.addMonths(monthMult - 1)
                }
            } else {
                if sat.day == start.day { next.addDays(1); next.addMonths(monthMult) }
                else if sun.day == start.day { next.addDays(2); next.addMonths(monthMult) }
                else if next.day >= start.day { next.addMonths(monthMult) }
                else if next.isLastOfMonth { next.addMonths(monthMult) }
                else if sat.isLastOfMonth { next.addDays(1); next.addMonths(monthMult) }
                else if sun.isLastOfMonth { next.addDays(2); next.addMonths(monthMult) }
                else { next.addMonths(monthMult - 1) }
            }
            return
        }

        if next.isLastOfMonth
            || ((period == .monthly || period == .yearly) && next.day >= start.day)
            || ((period == .nthWeekday || period == .lastWeekday)
                && nthWeekdayCompare(start: start, next: next, period: period) <= 0) {
            next.addMonths(monthMult)
        } else {
            next.addMonths(monthMult - 1)   // one fewer: an occurrence remains this month
        }
    }

    /// Offset in days from `next` to the nth/last weekday named by `start`, in
    /// `next`'s month (GnuCash `nth_weekday_compare`). Negative = earlier.
    private func nthWeekdayCompare(start: YMD, next: YMD, period: RecurrencePeriod) -> Int {
        let sd = start.day, nd = next.day
        var week = sd / 7 > 3 ? 3 : sd / 7
        if week > 0 && sd % 7 == 0 && sd != 28 { week -= 1 }
        var matchday = 7 * week + (nd - next.gncWeekday + start.gncWeekday + 7) % 7
        let dim = next.daysInMonth
        if (dim - matchday) >= 7 && period == .lastWeekday { matchday += 7 }
        if period == .nthWeekday && matchday % 7 == 0 { matchday += 7 }
        return matchday - nd
    }
}

// MARK: - GDate-equivalent integer date math

/// A date as (year, month, day), mirroring GLib's `GDate` operations GnuCash's
/// recurrence relies on — so month arithmetic clamps and re-sets the day the
/// same way, independent of `Calendar`'s own rules.
private struct YMD: Comparable {
    var year: Int
    var month: Int
    var day: Int

    init(year: Int, month: Int, day: Int) { self.year = year; self.month = month; self.day = day }

    init(_ date: Date, calendar: Calendar) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        year = c.year!; month = c.month!; day = c.day!
    }

    /// Reconstructs a `Date`, carrying the time-of-day from `timeFrom`.
    func date(timeFrom: Date, calendar: Calendar) -> Date {
        let t = calendar.dateComponents([.hour, .minute, .second], from: timeFrom)
        return calendar.date(from: DateComponents(
            year: year, month: month, day: day,
            hour: t.hour, minute: t.minute, second: t.second))!
    }

    static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        default:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        }
    }
    var daysInMonth: Int { Self.daysInMonth(year: year, month: month) }
    var isLastOfMonth: Bool { day == daysInMonth }

    /// GnuCash weekday numbering: Monday = 1 … Sunday = 7.
    var gncWeekday: Int {
        // 1970-01-01 (serial 0) was a Thursday → gnc 4; each +1 day advances one.
        (Self.serial(self) + 3).mod(7) + 1
    }

    /// Days since 1970-01-01 (proleptic Gregorian), for day arithmetic.
    static func serial(_ d: YMD) -> Int {
        // Days from civil date (Howard Hinnant's algorithm).
        let y = d.month <= 2 ? d.year - 1 : d.year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (d.month + (d.month > 2 ? -3 : 9)) + 2) / 5 + d.day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }
    static func fromSerial(_ z0: Int) -> YMD {
        let z = z0 + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return YMD(year: month <= 2 ? y + 1 : y, month: month, day: day)
    }

    mutating func addDays(_ n: Int) { self = Self.fromSerial(Self.serial(self) + n) }
    mutating func subtractDays(_ n: Int) { addDays(-n) }
    static func daysBetween(_ a: YMD, _ b: YMD) -> Int { serial(b) - serial(a) }

    /// Adds `n` months (may be negative), clamping the day to the target
    /// month's length — GLib `g_date_add_months`'s behaviour.
    mutating func addMonths(_ n: Int) {
        let total = year * 12 + (month - 1) + n
        year = total.floorDiv(12)
        month = total.mod(12) + 1
        day = min(day, daysInMonth)
    }

    var isWeekend: Bool { gncWeekday == 6 || gncWeekday == 7 }

    /// Moves a weekend date off the weekend per `wadj`, for the month-ish types.
    mutating func adjustForWeekend(period: RecurrencePeriod, wadj: WeekendAdjust) {
        guard period == .yearly || period == .monthly || period == .endOfMonth else { return }
        guard isWeekend else { return }
        switch wadj {
        case .back: subtractDays(gncWeekday == 6 ? 1 : 2)
        case .forward: addDays(gncWeekday == 6 ? 2 : 1)
        case .none: break
        }
    }

    static func < (a: YMD, b: YMD) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }
}

private extension Int {
    /// Floored modulo (result has the sign of the divisor), like C++/GLib here.
    func mod(_ m: Int) -> Int { let r = self % m; return r < 0 ? r + m : r }
    func floorDiv(_ m: Int) -> Int { Int((Double(self) / Double(m)).rounded(.down)) }
}
