//
//  ScheduledBudgetImportTests.swift
//  FinvestLens — Interchange
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Testing
import Foundation
import FinvestLensEngine
@testable import FinvestLensInterchange

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

struct ScheduledBudgetImportTests {

    // A hand-written GnuCash XML fragment with the account graph, one scheduled
    // transaction (with its template transaction) and one budget — the shapes a
    // real GnuCash 5.16 file uses.
    private let xml = """
    <?xml version="1.0" encoding="utf-8"?>
    <gnc-v2 xmlns:gnc="http://www.gnucash.org/XML/gnc" xmlns:act="http://www.gnucash.org/XML/act" xmlns:trn="http://www.gnucash.org/XML/trn" xmlns:split="http://www.gnucash.org/XML/split" xmlns:cmdty="http://www.gnucash.org/XML/cmdty" xmlns:ts="http://www.gnucash.org/XML/ts" xmlns:slot="http://www.gnucash.org/XML/slot" xmlns:sx="http://www.gnucash.org/XML/sx" xmlns:bgt="http://www.gnucash.org/XML/bgt" xmlns:recurrence="http://www.gnucash.org/XML/recurrence">
    <gnc:book version="2.0.0">
    <gnc:commodity version="2.0.0"><cmdty:space>CURRENCY</cmdty:space><cmdty:id>AUD</cmdty:id></gnc:commodity>
    <gnc:account version="2.0.0"><act:name>Root</act:name><act:id type="guid">00000000000000000000000000000000</act:id><act:type>ROOT</act:type></gnc:account>
    <gnc:account version="2.0.0"><act:name>Bank</act:name><act:id type="guid">aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa</act:id><act:type>BANK</act:type><act:commodity><cmdty:space>CURRENCY</cmdty:space><cmdty:id>AUD</cmdty:id></act:commodity><act:parent type="guid">00000000000000000000000000000000</act:parent></gnc:account>
    <gnc:account version="2.0.0"><act:name>Food</act:name><act:id type="guid">bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb</act:id><act:type>EXPENSE</act:type><act:commodity><cmdty:space>CURRENCY</cmdty:space><cmdty:id>AUD</cmdty:id></act:commodity><act:parent type="guid">00000000000000000000000000000000</act:parent></gnc:account>
    <gnc:template-transactions>
    <gnc:account version="2.0.0"><act:name>Template Root</act:name><act:id type="guid">cccccccccccccccccccccccccccccccc</act:id><act:type>ROOT</act:type><act:commodity><cmdty:space>template</cmdty:space><cmdty:id>template</cmdty:id></act:commodity></gnc:account>
    <gnc:account version="2.0.0"><act:name>1111111111111111aaaaaaaaaaaaaaaa</act:name><act:id type="guid">dddddddddddddddddddddddddddddddd</act:id><act:type>BANK</act:type><act:commodity><cmdty:space>template</cmdty:space><cmdty:id>template</cmdty:id></act:commodity><act:parent type="guid">cccccccccccccccccccccccccccccccc</act:parent></gnc:account>
    <gnc:transaction version="2.0.0">
    <trn:id type="guid">eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee</trn:id>
    <trn:currency><cmdty:space>CURRENCY</cmdty:space><cmdty:id>AUD</cmdty:id></trn:currency>
    <trn:description>Monthly Food Spend</trn:description>
    <trn:splits>
    <trn:split><split:id type="guid">f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1</split:id><split:reconciled-state>n</split:reconciled-state><split:value>0/100</split:value><split:quantity>0/1</split:quantity><split:account type="guid">dddddddddddddddddddddddddddddddd</split:account>
    <split:slots><slot><slot:key>sched-xaction</slot:key><slot:value type="frame">
    <slot><slot:key>account</slot:key><slot:value type="guid">bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb</slot:value></slot>
    <slot><slot:key>credit-numeric</slot:key><slot:value type="numeric">0/1</slot:value></slot>
    <slot><slot:key>debit-numeric</slot:key><slot:value type="numeric">20000/100</slot:value></slot>
    </slot:value></slot></split:slots></trn:split>
    <trn:split><split:id type="guid">f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2</split:id><split:reconciled-state>n</split:reconciled-state><split:value>0/100</split:value><split:quantity>0/1</split:quantity><split:account type="guid">dddddddddddddddddddddddddddddddd</split:account>
    <split:slots><slot><slot:key>sched-xaction</slot:key><slot:value type="frame">
    <slot><slot:key>account</slot:key><slot:value type="guid">aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa</slot:value></slot>
    <slot><slot:key>credit-numeric</slot:key><slot:value type="numeric">20000/100</slot:value></slot>
    <slot><slot:key>debit-numeric</slot:key><slot:value type="numeric">0/1</slot:value></slot>
    </slot:value></slot></split:slots></trn:split>
    </trn:splits></gnc:transaction>
    </gnc:template-transactions>
    <gnc:schedxaction version="2.0.0">
    <sx:id type="guid">1111111111111111aaaaaaaaaaaaaaaa</sx:id>
    <sx:name>Monthly Food Spend</sx:name>
    <sx:enabled>y</sx:enabled>
    <sx:advanceCreateDays>3</sx:advanceCreateDays>
    <sx:advanceRemindDays>5</sx:advanceRemindDays>
    <sx:start><gdate>2022-01-31</gdate></sx:start>
    <sx:last><gdate>2022-12-31</gdate></sx:last>
    <sx:templ-acct type="guid">dddddddddddddddddddddddddddddddd</sx:templ-acct>
    <sx:schedule><gnc:recurrence version="1.0.0"><recurrence:mult>1</recurrence:mult><recurrence:period_type>month</recurrence:period_type><recurrence:start><gdate>2022-01-31</gdate></recurrence:start></gnc:recurrence></sx:schedule>
    </gnc:schedxaction>
    <gnc:budget version="2.0.0">
    <bgt:id type="guid">22222222222222222222222222222222</bgt:id>
    <bgt:name>2022/2023 Budget</bgt:name>
    <bgt:num-periods>12</bgt:num-periods>
    <bgt:recurrence version="1.0.0"><recurrence:mult>1</recurrence:mult><recurrence:period_type>month</recurrence:period_type><recurrence:start><gdate>2022-07-01</gdate></recurrence:start></bgt:recurrence>
    <bgt:slots><slot><slot:key>bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb</slot:key><slot:value type="frame">
    <slot><slot:key>0</slot:key><slot:value type="numeric">2500/1</slot:value></slot>
    <slot><slot:key>1</slot:key><slot:value type="numeric">3000/1</slot:value></slot>
    </slot:value></slot></bgt:slots>
    </gnc:budget>
    </gnc:book>
    </gnc-v2>
    """

    /// The fixture, exposed for the variant suite below.
    var fixtureXML: String { xml }

    private func decodeScheduled(_ book: Book) -> [ScheduledTransaction] {
        guard case let .string(json)? = book.kvp["finvestlens/scheduledTransactions"],
              let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ScheduledTransaction].self, from: data)) ?? []
    }
    private func decodeBudgets(_ book: Book) -> [Budget] {
        guard case let .string(json)? = book.kvp["finvestlens/budgets"],
              let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([Budget].self, from: data)) ?? []
    }

    @Test("A GnuCash scheduled transaction imports with its recurrence and template splits (FR-IMP-03)")
    func importsScheduled() throws {
        let book = try GnuCashXMLImporter.importBook(from: Data(xml.utf8)).book
        let sx = decodeScheduled(book)
        #expect(sx.count == 1)
        let food = try #require(sx.first)
        #expect(food.name == "Monthly Food Spend")
        #expect(food.isEnabled)
        #expect(food.advanceCreateDays == 3)
        #expect(food.advanceRemindDays == 5)
        #expect(food.recurrence.period == .monthly)
        #expect(food.splits.count == 2)
        #expect(food.isBalanced)
        // Food debited 200, Bank credited 200.
        let foodGUID = try #require(GncGUID(hex: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"))
        #expect(food.splits.first { $0.accountGUID == foodGUID }?.value == dec("200"))
    }

    /// Verifies against the real standard test book when supplied via
    /// `FL_ROUNDTRIP_FILE` (skipped otherwise, like the live round-trip test).
    @Test("Real GnuCash book: scheduled transactions and budgets import",
          .enabled(if: ProcessInfo.processInfo.environment["FL_ROUNDTRIP_FILE"] != nil))
    func realBook() throws {
        let path = try #require(ProcessInfo.processInfo.environment["FL_ROUNDTRIP_FILE"])
        let book = try GnuCashXMLImporter.importBook(from: Data(contentsOf: URL(fileURLWithPath: path))).book
        // Ashley Bears.gnucash carries 2 scheduled transactions and 1 budget.
        #expect(decodeScheduled(book).count >= 1)
        #expect(decodeBudgets(book).count >= 1)
    }

    @Test("A GnuCash budget imports with per-period amounts (FR-IMP-04)")
    func importsBudget() throws {
        let book = try GnuCashXMLImporter.importBook(from: Data(xml.utf8)).book
        let budgets = decodeBudgets(book)
        #expect(budgets.count == 1)
        let budget = try #require(budgets.first)
        #expect(budget.name == "2022/2023 Budget")
        #expect(budget.numPeriods == 12)
        let line = try #require(budget.lines.first)
        #expect(line.amount(inPeriod: 0) == dec("2500"))
        #expect(line.amount(inPeriod: 1) == dec("3000"))
    }
}

@Suite("Scheduled import — recurrence & formula variants")
struct ScheduledVariantTests {

    /// The proven fixture from `ScheduledBudgetImportTests`, with the schedule
    /// line and the split slots swapped per variant.
    private func imported(schedule: String, enabled: String = "y",
                          debitSlots: String? = nil) -> [ScheduledTransaction] {
        var xml = ScheduledBudgetImportTests().fixtureXML
        xml = xml.replacingOccurrences(
            of: "<sx:schedule><gnc:recurrence version=\"1.0.0\"><recurrence:mult>1</recurrence:mult><recurrence:period_type>month</recurrence:period_type><recurrence:start><gdate>2022-01-31</gdate></recurrence:start></gnc:recurrence></sx:schedule>",
            with: schedule)
        xml = xml.replacingOccurrences(of: "<sx:enabled>y</sx:enabled>",
                                       with: "<sx:enabled>\(enabled)</sx:enabled>")
        if let debitSlots {
            xml = xml.replacingOccurrences(
                of: "<slot><slot:key>debit-numeric</slot:key><slot:value type=\"numeric\">20000/100</slot:value></slot>",
                with: debitSlots)
        }
        let book = Book(baseCurrency: .aud)
        // The SX importer resolves template-split accounts against the BOOK,
        // so the fixture's account GUIDs must exist on it.
        book.addAccount(Account(guid: GncGUID(hex: String(repeating: "a", count: 32))!,
                                name: "Bank", type: .bank, commodity: .aud))
        book.addAccount(Account(guid: GncGUID(hex: String(repeating: "b", count: 32))!,
                                name: "Food", type: .expense, commodity: .aud))
        _ = GnuCashScheduledBudgetImport.apply(xml: Data(xml.utf8), to: book)
        guard case let .string(json)? = book.kvp["finvestlens/scheduledTransactions"],
              let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ScheduledTransaction].self, from: data)) ?? []
    }

    @Test("Weekly multiplier and weekend adjustment map onto the recurrence")
    func weeklyVariant() throws {
        let schedule = "<sx:schedule><gnc:recurrence version=\"1.0.0\">"
            + "<recurrence:mult>2</recurrence:mult>"
            + "<recurrence:period_type>week</recurrence:period_type>"
            + "<recurrence:start><gdate>2022-01-31</gdate></recurrence:start>"
            + "<recurrence:weekend_adj>forward</recurrence:weekend_adj>"
            + "</gnc:recurrence></sx:schedule>"
        let sx = try #require(imported(schedule: schedule).first)
        #expect(sx.recurrence.period == .weekly)
        #expect(sx.recurrence.interval == 2)
        // Weekend adjustment is month-anchored semantics: a weekly recurrence
        // deliberately discards it (Recurrence.init, GnuCash-faithful).
        #expect(sx.recurrence.weekendAdjust == WeekendAdjust.none)
        #expect(sx.isEnabled)
        #expect(sx.splits.contains { $0.value == Decimal(200) })
    }

    @Test("A disabled end-of-month SX imports disabled with the right period")
    func disabledEndOfMonth() throws {
        let schedule = "<sx:schedule><gnc:recurrence version=\"1.0.0\">"
            + "<recurrence:mult>1</recurrence:mult>"
            + "<recurrence:period_type>end of month</recurrence:period_type>"
            + "<recurrence:start><gdate>2022-01-31</gdate></recurrence:start>"
            + "<recurrence:weekend_adj>back</recurrence:weekend_adj>"
            + "</gnc:recurrence></sx:schedule>"
        let sx = try #require(imported(schedule: schedule, enabled: "n").first)
        #expect(sx.recurrence.period == .endOfMonth)
        #expect(sx.recurrence.weekendAdjust == .back)
        #expect(!sx.isEnabled)
    }

    @Test("Formula slots stand in when the numeric slots are zero")
    func formulaFallback() throws {
        let formulas = "<slot><slot:key>debit-formula</slot:key><slot:value type=\"string\">1234.50</slot:value></slot>"
        let schedule = "<sx:schedule><gnc:recurrence version=\"1.0.0\">"
            + "<recurrence:mult>1</recurrence:mult>"
            + "<recurrence:period_type>year</recurrence:period_type>"
            + "<recurrence:start><gdate>2022-01-31</gdate></recurrence:start>"
            + "</gnc:recurrence></sx:schedule>"
        let sx = try #require(imported(schedule: schedule, debitSlots: formulas).first)
        #expect(sx.recurrence.period == .yearly)
        #expect(sx.splits.contains { $0.value == Decimal(string: "1234.50") })
    }
}
