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

    /// The Trial Balance as a grouped statement: Debit/Credit columns, one
    /// section per top-level category in class order, caption rows with note
    /// detail, the unrealised valuation adjustment on its own line, and the
    /// double-ruled equal totals the report exists to state.
    func trialBalanceStatement(asOf: Date) -> Statement? {
        guard let book else { return nil }
        return cachedReport("stmt.tb:\(asOf.timeIntervalSinceReferenceDate)") {
            guard let report = trialBalance(asOf: asOf) else { return nil }
            let builder = StatementBuilder(book: book)

            let debits = report.rows.compactMap { row in
                row.debit.map { StatementBuilder.StatementLine(id: row.id, name: row.name, amount: $0) }
            }
            let credits = report.rows.compactMap { row in
                row.credit.map { StatementBuilder.StatementLine(id: row.id, name: row.name, amount: $0) }
            }
            var groups = builder.captionForestsByCategory(lineSets: [debits, credits])

            // Category order: assets, liabilities, equity, income, expenses,
            // then everything else; integrity groups last.
            func rank(_ group: (title: String, nodes: [StatementBuilder.Node])) -> Int {
                if group.title == "Uncategorised" { return 9 }
                var weights: [AccountType: Decimal] = [:]
                for node in group.nodes { node.typeWeights(into: &weights) }
                switch weights.max(by: { $0.value < $1.value })?.key {
                case .asset, .bank, .cash, .stock, .mutualFund, .receivable: return 0
                case .credit, .liability, .payable: return 1
                case .equity: return 2
                case .income: return 3
                case .expense: return 4
                default: return 5
                }
            }
            groups.sort { rank($0) < rank($1) }

            var builtSections: [StatementBuilder.BuiltSection] = []
            for group in groups {
                builtSections.append(builder.buildSection(
                    title: group.title,
                    totalLabel: "Total \(group.title)",
                    forest: group.nodes,
                    ordering: .magnitude,
                    columnCount: 2,
                    protected: { $0.name == "Uncategorised" }))
            }

            let format = AppDateFormat.current
            var basis = StatementNote(number: 1, title: "Basis of preparation", body: [
                "Balances in the raw double-entry convention: debit balances in the left column, credit balances in the right, converted to \(report.currencyCode) at \(format.long(asOf)) rates.",
                "The unrealised valuation adjustment is what valuing holdings at market adds over cost — printed, not hidden, because it is the number that makes the columns agree.",
            ])
            basis.body.append("Zero balances are omitted.")

            var (faces, notes) = { () -> ([StatementSection], [StatementNote]) in
                var allNotes: [StatementNote] = [basis]
                var sections: [StatementSection] = []
                for built in builtSections {
                    var face = built.section
                    for index in face.items.indices {
                        if let local = face.items[index].noteRef {
                            var note = built.notes[local]
                            note.number = allNotes.count + 1
                            allNotes.append(note)
                            face.items[index].noteRef = note.number
                        }
                    }
                    sections.append(face)
                }
                return (sections, allNotes)
            }()

            // The adjustment joins the credit column, as a gain would (or the
            // debit column when negative).
            if report.unrealisedAdjustment != 0 {
                let adjustment = report.unrealisedAdjustment
                let amounts: [Decimal?] = adjustment > 0 ? [nil, adjustment] : [-adjustment, nil]
                faces.append(StatementSection(
                    title: "Adjustments",
                    items: [StatementItem(caption: "Unrealised valuation adjustment (Note 1)",
                                          amounts: amounts, role: .line)],
                    totalLabel: "Total adjustments",
                    totalAmounts: amounts))
            }

            return Statement(
                title: "Trial Balance",
                entityName: statementEntityName,
                periodLabel: "As at \(format.long(asOf))",
                unitsLabel: "All amounts in \(report.currencyCode) · debits left, credits right",
                currencyCode: report.currencyCode,
                columns: ["Debit", "Credit"],
                sections: faces,
                grandTotal: ("Total (the books balance)",
                             [report.totalDebits, report.totalCredits]),
                notes: notes)
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
