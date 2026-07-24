//
//  AppModel+Statements.swift
//  FinvestLens — FeatureUI
//
//  Memoised accessors for the annual-report statements: derive the prior
//  comparative period (one year back, only when the book actually has data
//  there), label the columns the way statements do (the year for annual
//  periods, the end date otherwise), and hand the engine's verified reports
//  to the StatementBuilder.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine
import FinvestLensReports

@MainActor
extension AppModel {

    /// The entity line on a statement masthead: the book's name.
    var statementEntityName: String {
        documentURL?.deletingPathExtension().lastPathComponent ?? "FinvestLens"
    }

    private func bookHasData(before date: Date) -> Bool {
        book?.transactions.contains { $0.datePosted < date } ?? false
    }

    /// Statement column header: the year for a year-like period, the end
    /// date otherwise — "2026 / 2025" is how annual reports head columns.
    private func columnLabel(from: Date?, to: Date) -> String {
        let calendar = Calendar.current
        if let from, let days = calendar.dateComponents([.day], from: from, to: to).day,
           days < 300 {
            return AppDateFormat.current.short(to)
        }
        return String(calendar.component(.year, from: to))
    }

    /// Statement of Financial Position as at `asOf`, with a prior-year
    /// comparative when the book reaches back that far.
    func financialPositionStatement(asOf: Date) -> Statement? {
        guard let book else { return nil }
        return cachedReport("stmt.fp:\(asOf.timeIntervalSinceReferenceDate)") {
            guard let current = balanceSheet(asOf: asOf) else { return nil }
            let format = AppDateFormat.current
            let priorDate = Calendar.current.date(byAdding: .year, value: -1, to: asOf)
            var prior: BalanceSheet?
            var priorLabel: String?
            if let priorDate, bookHasData(before: priorDate) {
                prior = balanceSheet(asOf: priorDate)
                priorLabel = format.long(priorDate)
            }
            return StatementBuilder(book: book).financialPosition(
                entityName: statementEntityName,
                current: current, currentLabel: format.long(asOf),
                prior: prior, priorLabel: priorLabel)
        }
    }

    /// Income Statement for the period, with the year-earlier period as the
    /// comparative when the book has data there.
    func incomeStatementStatement(from: Date, to: Date, periodLabel: String) -> Statement? {
        guard let book else { return nil }
        return cachedReport("stmt.is:\(from.timeIntervalSinceReferenceDate):\(to.timeIntervalSinceReferenceDate)") {
            guard let current = incomeStatement(from: from, to: to) else { return nil }
            let calendar = Calendar.current
            var prior: IncomeStatement?
            var priorColumn: String?
            if let priorFrom = calendar.date(byAdding: .year, value: -1, to: from),
               let priorTo = calendar.date(byAdding: .year, value: -1, to: to),
               bookHasData(before: from), from > .distantPast {
                prior = incomeStatement(from: priorFrom, to: priorTo)
                priorColumn = columnLabel(from: priorFrom, to: priorTo)
            }
            var statement = StatementBuilder(book: book).incomeStatement(
                entityName: statementEntityName,
                current: current, currentLabel: columnLabel(from: from, to: to),
                prior: prior, priorLabel: priorColumn)
            statement.periodLabel = periodLabel
            return statement
        }
    }

    /// Statement of Changes in Net Worth over the period: opening net worth,
    /// the surplus, and the valuation/FX movement as the balancing figure.
    func changesInNetWorthStatement(from: Date, to: Date, periodLabel: String) -> Statement? {
        guard let book else { return nil }
        return cachedReport("stmt.nw:\(from.timeIntervalSinceReferenceDate):\(to.timeIntervalSinceReferenceDate)") {
            // Opening = the instant before the period starts; a posting dated
            // on the first day belongs to the period, not the opening.
            let openingDate = from == .distantPast ? from : from.addingTimeInterval(-1)
            guard let opening = balanceSheet(asOf: openingDate),
                  let closing = balanceSheet(asOf: to),
                  let period = incomeStatement(from: from, to: to) else { return nil }
            var statement = StatementBuilder(book: book).changesInNetWorth(
                entityName: statementEntityName,
                opening: opening, closing: closing, period: period,
                currentLabel: columnLabel(from: from, to: to))
            statement.periodLabel = periodLabel
            return statement
        }
    }
}
