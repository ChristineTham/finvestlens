//
//  Alerts.swift
//  FinvestLens — Reports
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensEngine

/// The kind of proactive alert (`FR-PLAN-05`, Advisor-FYI).
public enum AlertKind: String, Sendable, Codable {
    case billDue, lowBalance, overBudget, priceTarget
}

/// Alert urgency.
public enum AlertSeverity: Int, Sendable, Codable, Comparable {
    case info, warning, critical
    public static func < (lhs: AlertSeverity, rhs: AlertSeverity) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A proactive alert surfaced on the dashboard / notifications.
public struct FinancialAlert: Identifiable, Hashable, Sendable {
    /// Stable across recomputes (kind + subject) so the UI can dedupe.
    public let id: String
    public var kind: AlertKind
    public var severity: AlertSeverity
    public var title: String
    public var message: String
    public var date: Date?
}

/// A user-set price target for a security (`FR-PLAN-05`).
public struct PriceTarget: Codable, Hashable, Sendable {
    public enum Direction: String, Codable, Sendable { case atOrAbove, atOrBelow }
    public var commodity: Commodity
    public var target: Decimal
    public var direction: Direction

    public init(commodity: Commodity, target: Decimal, direction: Direction) {
        self.commodity = commodity
        self.target = target
        self.direction = direction
    }
}

public extension FinancialReports {

    /// Computes proactive alerts from bills, budgets, a cash-flow forecast and
    /// price targets, most-severe first (`FR-PLAN-05`).
    static func alerts(
        _ book: Book,
        scheduled: [ScheduledTransaction] = [],
        budgets: [Budget] = [],
        currency: Commodity,
        asOf: Date = Date(),
        forecastAccountID: GncGUID? = nil,
        forecastMonths: Int = 3,
        lowBalanceThreshold: Decimal = 0,
        priceTargets: [PriceTarget] = []
    ) -> [FinancialAlert] {
        var alerts: [FinancialAlert] = []
        let df = ISO8601DateFormatter()

        // Bills — overdue (critical) / due soon (warning).
        let from = asOf.addingTimeInterval(-30 * 86_400)
        let to = asOf.addingTimeInterval(60 * 86_400)
        for bill in billReminders(book, scheduled: scheduled, from: from, to: to, asOf: asOf) {
            let severity: AlertSeverity
            switch bill.status {
            case .overdue: severity = .critical
            case .dueSoon: severity = .warning
            default: continue
            }
            alerts.append(FinancialAlert(
                id: "bill:\(bill.scheduledID.hexString):\(df.string(from: bill.dueDate))",
                kind: .billDue, severity: severity,
                title: severity == .critical ? "Bill overdue: \(bill.name)" : "Bill due soon: \(bill.name)",
                message: "\(AmountFormat.money(bill.amount, currency)) due \(mediumDate(bill.dueDate))",
                date: bill.dueDate))
        }

        // Over budget (warning).
        for budget in budgets {
            for line in budgetActuals(book, budget: budget, from: monthStart(asOf), to: asOf, currency: currency)
            where line.isOverBudget {
                alerts.append(FinancialAlert(
                    id: "budget:\(line.id.hexString)",
                    kind: .overBudget, severity: .warning,
                    title: "Over budget: \(line.accountName)",
                    message: "Spent \(AmountFormat.money(line.actual, currency)) of \(AmountFormat.money(line.effectiveBudget, currency))",
                    date: nil))
            }
        }

        // Projected low / negative balance.
        if let forecastAccountID {
            let horizon = asOf.addingTimeInterval(TimeInterval(forecastMonths) * 30 * 86_400)
            let points = cashFlowForecast(book, accountID: forecastAccountID, scheduled: scheduled,
                                          from: asOf, horizon: horizon, currency: currency)
            if let worst = points.min(by: { $0.balance < $1.balance }), worst.balance < lowBalanceThreshold {
                let negative = worst.balance < 0
                alerts.append(FinancialAlert(
                    id: "lowbalance:\(forecastAccountID.hexString)",
                    kind: .lowBalance, severity: negative ? .critical : .warning,
                    title: negative ? "Projected negative balance" : "Projected low balance",
                    message: "Reaches \(AmountFormat.money(worst.balance, currency)) around \(mediumDate(worst.date))",
                    date: worst.date))
            }
        }

        // Price targets.
        for target in priceTargets {
            guard let price = book.latestPrice(of: target.commodity, in: currency, on: asOf)?.value else { continue }
            let hit = target.direction == .atOrAbove ? price >= target.target : price <= target.target
            guard hit else { continue }
            let arrow = target.direction == .atOrAbove ? "≥" : "≤"
            alerts.append(FinancialAlert(
                id: "price:\(target.commodity.mnemonic)",
                kind: .priceTarget, severity: .info,
                title: "Price target: \(target.commodity.mnemonic)",
                message: "\(AmountFormat.money(price, currency)) \(arrow) \(AmountFormat.money(target.target, currency))",
                date: asOf))
        }

        return alerts.sorted { ($0.severity, $0.date ?? .distantFuture) > ($1.severity, $1.date ?? .distantFuture) }
    }

    private static func monthStart(_ date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal.date(from: cal.dateComponents([.year, .month], from: date)) ?? date
    }

    private static func mediumDate(_ date: Date) -> String {
        date.formatted(.dateTime.year().month().day())
    }
}

/// Small money formatter shared by report messages (avoids a FeatureUI dep).
enum AmountFormat {
    static func money(_ value: Decimal, _ currency: Commodity) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.mnemonic
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "\(value) \(currency.mnemonic)"
    }
}
