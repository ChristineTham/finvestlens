//
//  DashboardView.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import Charts
import FinvestLensEngine
import FinvestLensReports

/// The home dashboard: net-worth trend, alerts, balances, upcoming bills and
/// budget status (`FR-PLAN-08`).
struct DashboardView: View {
    @Bindable var model: AppModel

    private var code: String { model.reportCurrency.mnemonic }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                netWorthCard
                alertsCard
                HStack(alignment: .top, spacing: 16) {
                    accountsCard
                    billsCard
                }
                budgetCard
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Dashboard")
    }

    // MARK: Net worth

    private var netWorthCard: some View {
        let series = model.netWorthSeries(months: 12)
        let current = series.last?.netWorth ?? 0
        return Card("Net Worth", systemImage: "chart.line.uptrend.xyaxis") {
            Text(AmountFormat.string(current, code: code))
                .scaledFont(.largeTitle, weight: .bold, design: .rounded).monospacedDigit()
                .foregroundStyle(current < 0 ? .red : .primary)
                .accessibilityLabel("Net worth")
                .accessibilityValue(AmountFormat.string(current, code: code))
            if series.count >= 2 {
                Chart(series) { point in
                    AreaMark(x: .value("Month", point.date), y: .value("Net worth", asDouble(point.netWorth)))
                        .foregroundStyle(.tint.opacity(0.15))
                    LineMark(x: .value("Month", point.date), y: .value("Net worth", asDouble(point.netWorth)))
                }
                .frame(height: 120)
                .chartXAxis { AxisMarks(values: .stride(by: .month, count: 3)) }
                .accessibilityLabel("Net worth trend over the last 12 months")
            }
        }
    }

    // MARK: Alerts

    private var alertsCard: some View {
        let alerts = model.alerts()
        return Card("Alerts", systemImage: "bell.badge") {
            if alerts.isEmpty {
                Label("Nothing needs attention", systemImage: "checkmark.circle")
                    .foregroundStyle(.green).scaledFont(.callout)
            } else {
                ForEach(alerts) { alert in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: icon(for: alert.severity))
                            .foregroundStyle(color(for: alert.severity))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(alert.title).fontWeight(.medium)
                            Text(alert.message).scaledFont(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(severityWord(alert.severity)) alert. \(alert.title). \(alert.message)")
                }
            }
        }
    }

    // MARK: Accounts

    private var accountsCard: some View {
        Card("Accounts", systemImage: "list.bullet") {
            if model.accountTree.isEmpty {
                Text("No accounts yet.").scaledFont(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(model.accountTree) { node in
                    Button {
                        model.selectedAccountID = node.id
                    } label: {
                        HStack {
                            Text(node.name)
                            Spacer()
                            Text(AmountFormat.string(node.balance, code: node.currencyCode))
                                .monospacedDigit()
                                .foregroundStyle(node.balance < 0 ? .red : .primary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Bills

    private var billsCard: some View {
        let bills = model.billReminders().filter { $0.status != .paid }.prefix(6)
        return Card("Upcoming Bills", systemImage: "calendar") {
            if bills.isEmpty {
                Text("No upcoming bills.").scaledFont(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(Array(bills)) { bill in
                    HStack {
                        Text(bill.name)
                        Spacer()
                        Text(bill.dueDate, format: .dateTime.month().day())
                            .scaledFont(.caption).foregroundStyle(.secondary)
                        Text(AmountFormat.string(bill.amount, code: code)).monospacedDigit()
                    }
                }
            }
        }
    }

    // MARK: Budget

    @ViewBuilder
    private var budgetCard: some View {
        if let budget = model.budgets.first {
            let actuals = model.budgetActuals(budget)
            Card("Budget", systemImage: "chart.bar.doc.horizontal") {
                if actuals.isEmpty {
                    Text("No budget lines set.").scaledFont(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(actuals) { actual in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(actual.accountName)
                                Spacer()
                                Text("\(AmountFormat.string(actual.actual, code: code)) / \(AmountFormat.string(actual.effectiveBudget, code: code))")
                                    .scaledFont(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                            ProgressView(value: min(1, max(0, actual.fractionUsed ?? 0)))
                                .tint(actual.isOverBudget ? .red : .accentColor)
                        }
                    }
                }
            }
        }
    }

    // MARK: Helpers

    private func asDouble(_ d: Decimal) -> Double { NSDecimalNumber(decimal: d).doubleValue }
    private func icon(for s: AlertSeverity) -> String {
        switch s { case .critical: "exclamationmark.octagon.fill"; case .warning: "exclamationmark.triangle.fill"; case .info: "info.circle.fill" }
    }
    private func color(for s: AlertSeverity) -> Color {
        switch s { case .critical: .red; case .warning: .orange; case .info: .blue }
    }
    private func severityWord(_ s: AlertSeverity) -> String {
        switch s { case .critical: "Critical"; case .warning: "Warning"; case .info: "Information" }
    }
}

/// A titled dashboard card.
private struct Card<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    init(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .scaledFont(.headline).foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}
