//
//  GnuCashScheduledBudgetImport.swift
//  FinvestLens — Interchange
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Imports GnuCash scheduled transactions (`<gnc:schedxaction>`, FR-IMP-03) and
//  budgets (`<gnc:budget>`, FR-IMP-04), which the main importer leaves on the
//  floor. Runs as a second pass over the same XML so the main SAX machine stays
//  untouched, then writes the results into the FinvestLens KVP slots the app
//  reads (`finvestlens/scheduledTransactions`, `finvestlens/budgets`).
//
//  Schema references (libgnucash/backend/xml): gnc-schedxaction-xml-v2,
//  gnc-budget-xml-v2, gnc-recurrence-xml-v2. Verified against a real GnuCash
//  5.16 book. Amounts come from the template split's `sched-xaction` slot
//  (debit-numeric − credit-numeric); free-form formulas (FR-SCH-02) that aren't
//  plain numbers import as zero, which the user can edit.
//

import Foundation
import FinvestLensEngine

enum GnuCashScheduledBudgetImport {

    /// Parses SX + budgets from `xml` and writes them into `book`'s KVP slots.
    /// Returns the counts imported (for the import summary). Never throws — on
    /// any trouble it simply imports nothing.
    @discardableResult
    static func apply(xml: Data, to book: Book) -> (scheduled: Int, budgets: Int) {
        let parser = XMLParser(data: xml)
        parser.shouldProcessNamespaces = false
        let delegate = Delegate()
        parser.delegate = delegate
        guard parser.parse() else { return (0, 0) }

        let scheduled = delegate.buildScheduled(book: book)
        let budgets = delegate.buildBudgets(book: book)

        if !scheduled.isEmpty, book.kvp["finvestlens/scheduledTransactions"] == nil,
           let json = encode(scheduled) {
            book.kvp["finvestlens/scheduledTransactions"] = .string(json)
        }
        if !budgets.isEmpty, book.kvp["finvestlens/budgets"] == nil,
           let json = encode(budgets) {
            book.kvp["finvestlens/budgets"] = .string(json)
        }
        return (scheduled.count, budgets.count)
    }

    private static func encode<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Intermediate models

    private struct TemplateSplit {
        var templateAccountGUID: String = ""
        var realAccountGUID: String = ""
        var creditNumeric: Decimal = 0
        var debitNumeric: Decimal = 0
        var creditFormula = ""
        var debitFormula = ""
        var memo = ""
    }

    private struct TemplateTxn {
        var currencySpace = ""
        var currencyID = ""
        var descriptionText = ""
        var splits: [TemplateSplit] = []
    }

    private struct SXRecord {
        var guid = ""
        var name = ""
        var enabled = true
        var advanceCreateDays = 0
        var advanceRemindDays = 0
        var start: Date?
        var last: Date?
        var recPeriod = "month"
        var recMult = 1
        var recStart: Date?
        var weekendAdjust = "none"
    }

    private struct BudgetRecord {
        var guid = ""
        var name = ""
        var numPeriods = 12
        /// account GUID → (period → amount)
        var lines: [String: [Int: Decimal]] = [:]
    }

    // MARK: - SAX delegate

    private final class Delegate: NSObject, XMLParserDelegate {
        var stack: [String] = []
        var text = ""

        var inTemplateSection = false

        // Template accounts: guid → name (the name is the owning SX's guid).
        var templateAccountName: [String: String] = [:]
        var templateAccount: (guid: String, name: String)?

        // Template transactions.
        var templateTxns: [TemplateTxn] = []
        var templateTxn: TemplateTxn?
        var templateSplit: TemplateSplit?

        // Scheduled transactions.
        var scheduled: [SXRecord] = []
        var sx: SXRecord?

        // Budgets.
        var budgets: [BudgetRecord] = []
        var budget: BudgetRecord?

        // Generic slot reader (used for template split sched-xaction + budget).
        enum SlotContext { case none, schedXaction, budget }
        var slotContext: SlotContext = .none
        var slotKeys: [String] = []          // key per open <slot>
        var framePath: [String] = []         // keys of descended frames
        var valueIsFrame: [Bool] = []        // per open <slot:value>
        var scalarType = ""

        private var parent: String? { stack.count >= 2 ? stack[stack.count - 2] : nil }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            stack.append(name)
            text = ""
            switch name {
            case "gnc:template-transactions": inTemplateSection = true
            case "gnc:account" where inTemplateSection: templateAccount = (guid: "", name: "")
            case "gnc:transaction" where inTemplateSection: templateTxn = TemplateTxn()
            case "trn:split" where templateTxn != nil: templateSplit = TemplateSplit()

            case "gnc:schedxaction": sx = SXRecord()
            case "gnc:budget": budget = BudgetRecord()

            case "split:slots" where templateSplit != nil: slotContext = .schedXaction
            case "bgt:slots" where budget != nil: slotContext = .budget

            case "slot" where slotContext != .none:
                slotKeys.append("")
            case "slot:value" where slotContext != .none:
                let type = attributes["type"] ?? "string"
                scalarType = type
                if type == "frame" {
                    framePath.append(slotKeys.last ?? "")
                    valueIsFrame.append(true)
                } else {
                    valueIsFrame.append(false)
                }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                    qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            defer { if stack.last == name { stack.removeLast() }; text = "" }

            switch name {
            case "gnc:template-transactions": inTemplateSection = false

            // Template accounts.
            case "act:id" where templateAccount != nil: templateAccount?.guid = value
            case "act:name" where templateAccount != nil: templateAccount?.name = value
            case "gnc:account" where inTemplateSection:
                if let a = templateAccount, !a.guid.isEmpty { templateAccountName[a.guid] = a.name }
                templateAccount = nil

            // Template transaction fields.
            case "cmdty:space" where templateTxn != nil && templateSplit == nil: templateTxn?.currencySpace = value
            case "cmdty:id" where templateTxn != nil && templateSplit == nil: templateTxn?.currencyID = value
            case "trn:description" where templateTxn != nil: templateTxn?.descriptionText = value
            case "split:account" where templateSplit != nil: templateSplit?.templateAccountGUID = value
            case "split:memo" where templateSplit != nil: templateSplit?.memo = value
            case "trn:split" where templateTxn != nil:
                if let s = templateSplit { templateTxn?.splits.append(s) }
                templateSplit = nil
            case "split:slots" where slotContext == .schedXaction: slotContext = .none
            case "gnc:transaction" where inTemplateSection:
                if let t = templateTxn { templateTxns.append(t) }
                templateTxn = nil

            // Scheduled transaction fields.
            case "sx:id": sx?.guid = value
            case "sx:name": sx?.name = value
            case "sx:enabled": sx?.enabled = (value == "y")
            case "sx:advanceCreateDays": sx?.advanceCreateDays = Int(value) ?? 0
            case "sx:advanceRemindDays": sx?.advanceRemindDays = Int(value) ?? 0
            case "recurrence:mult" where sx != nil: sx?.recMult = Int(value) ?? 1
            case "recurrence:period_type" where sx != nil: sx?.recPeriod = value
            case "recurrence:weekend_adj" where sx != nil: sx?.weekendAdjust = value
            case "gdate":
                setGDate(value)
            case "gnc:schedxaction":
                if let s = sx, !s.guid.isEmpty { scheduled.append(s) }
                sx = nil

            // Budget fields.
            case "bgt:id": budget?.guid = value
            case "bgt:name": budget?.name = value
            case "bgt:num-periods": budget?.numPeriods = Int(value) ?? 12
            case "recurrence:period_type" where budget != nil: break  // budgets: period type unused
            case "gnc:budget":
                if let b = budget, !b.guid.isEmpty { budgets.append(b) }
                budget = nil

            // Slot reader.
            case "slot:key" where slotContext != .none:
                if let idx = slotKeys.indices.last { slotKeys[idx] = value }
            case "slot:value" where slotContext != .none:
                let wasFrame = valueIsFrame.popLast() ?? false
                if wasFrame {
                    if !framePath.isEmpty { framePath.removeLast() }
                } else {
                    recordScalar(value)
                }
            case "slot" where slotContext != .none:
                if !slotKeys.isEmpty { slotKeys.removeLast() }

            default: break
            }
        }

        // MARK: gdate context

        private func setGDate(_ value: String) {
            let date = Self.gdate(value)
            // Which date this is depends on the open element two levels up.
            switch parent {
            case "sx:start": sx?.start = date
            case "sx:last": sx?.last = date
            case "recurrence:start":
                if sx != nil { sx?.recStart = date }
            default:
                // Also handle gdate inside a numeric-less slot value (ignored).
                break
            }
        }

        // MARK: slot scalar dispatch

        private func recordScalar(_ value: String) {
            let key = slotKeys.last ?? ""
            switch slotContext {
            case .schedXaction:
                // Path is [sched-xaction, <field>] on a template split.
                guard framePath.first == "sched-xaction" else { return }
                switch key {
                case "account": templateSplit?.realAccountGUID = value
                case "credit-numeric": templateSplit?.creditNumeric = GnuCashNumeric.parse(value) ?? 0
                case "debit-numeric": templateSplit?.debitNumeric = GnuCashNumeric.parse(value) ?? 0
                case "credit-formula": templateSplit?.creditFormula = value
                case "debit-formula": templateSplit?.debitFormula = value
                default: break
                }
            case .budget:
                // Path is [<accountGUID>, <periodIndex>] with a numeric value.
                guard framePath.count == 1, let accountGUID = framePath.first,
                      let period = Int(key), let amount = GnuCashNumeric.parse(value) else { return }
                budget?.lines[accountGUID, default: [:]][period] = amount
            case .none:
                break
            }
        }

        // MARK: - Assembly

        func buildScheduled(book: Book) -> [ScheduledTransaction] {
            // Group template transactions by the SX they belong to (a template
            // split's account is a template account whose name is the SX guid).
            var templatesBySX: [String: TemplateTxn] = [:]
            for txn in templateTxns {
                guard let first = txn.splits.first,
                      let sxGUID = templateAccountName[first.templateAccountGUID] else { continue }
                templatesBySX[sxGUID] = txn
            }

            var result: [ScheduledTransaction] = []
            for record in scheduled {
                guard let start = record.recStart ?? record.start else { continue }
                let period = Self.period(record.recPeriod)
                let recurrence = Recurrence(period: period, interval: max(1, record.recMult),
                                            startDate: start,
                                            weekendAdjust: Self.weekend(record.weekendAdjust))

                var currency = book.commodities.first { $0.namespace == .currency } ?? .aud
                var splits: [ScheduledSplit] = []
                if let template = templatesBySX[record.guid] {
                    if let matched = book.commodities.first(where: { $0.mnemonic == template.currencyID }) {
                        currency = matched
                    }
                    for ts in template.splits {
                        guard let accountGUID = GncGUID(hex: ts.realAccountGUID),
                              book.account(with: accountGUID) != nil else { continue }
                        let value = Self.amount(ts)
                        splits.append(ScheduledSplit(accountGUID: accountGUID, value: value, memo: ts.memo))
                    }
                }

                let sxID = GncGUID(hex: record.guid) ?? .random()
                result.append(ScheduledTransaction(
                    id: sxID, name: record.name, currency: currency,
                    description: templatesBySX[record.guid]?.descriptionText ?? record.name,
                    recurrence: recurrence, splits: splits,
                    lastPosted: record.last, isEnabled: record.enabled,
                    advanceCreateDays: record.advanceCreateDays,
                    advanceRemindDays: record.advanceRemindDays))
            }
            return result
        }

        func buildBudgets(book: Book) -> [Budget] {
            budgets.map { record in
                var lines: [BudgetLine] = []
                for (accountHex, periods) in record.lines {
                    guard let accountGUID = GncGUID(hex: accountHex),
                          book.account(with: accountGUID) != nil, !periods.isEmpty else { continue }
                    let flat = periods[0] ?? periods.values.first ?? 0
                    lines.append(BudgetLine(accountGUID: accountGUID, amount: flat, periodAmounts: periods))
                }
                return Budget(id: GncGUID(hex: record.guid) ?? .random(),
                              name: record.name, lines: lines.sorted { $0.accountGUID.hexString < $1.accountGUID.hexString },
                              numPeriods: record.numPeriods)
            }
        }

        // MARK: helpers

        /// A template split's signed value from the SX account's perspective:
        /// debit − credit (numerics; a plain-number formula is used if the
        /// numeric is zero but the formula parses).
        static func amount(_ split: TemplateSplit) -> Decimal {
            let debit = split.debitNumeric != 0 ? split.debitNumeric : (Decimal(string: split.debitFormula) ?? 0)
            let credit = split.creditNumeric != 0 ? split.creditNumeric : (Decimal(string: split.creditFormula) ?? 0)
            return debit - credit
        }

        static func period(_ raw: String) -> RecurrencePeriod {
            switch raw.lowercased() {
            case "day", "daily", "days": return .daily
            case "week", "weekly": return .weekly
            case "month", "monthly": return .monthly
            case "end of month", "end-of-month": return .endOfMonth
            case "nth weekday", "nth-weekday": return .nthWeekday
            case "last weekday", "last-weekday": return .lastWeekday
            case "year", "yearly": return .yearly
            case "once", "none": return .once
            default: return .monthly
            }
        }

        static func weekend(_ raw: String) -> WeekendAdjust {
            switch raw.lowercased() {
            case "back": return .back
            case "forward": return .forward
            default: return .none
            }
        }

        static let gdateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.calendar = Calendar(identifier: .gregorian)
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd"
            return f
        }()

        static func gdate(_ value: String) -> Date? {
            gdateFormatter.date(from: String(value.prefix(10)))
        }
    }
}
