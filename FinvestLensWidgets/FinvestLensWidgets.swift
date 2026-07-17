//
//  FinvestLensWidgets.swift
//  FinvestLens — Widgets extension
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Home-screen / Notification-Center widgets (FR-PLT-03). A widget runs in a
//  separate, memory-limited process that cannot open the book, so it reads the
//  small snapshot the app publishes to the shared App Group container
//  (WidgetSnapshot). The app reloads these timelines on every save/open.
//

import WidgetKit
import SwiftUI
import FinvestLensShared

// MARK: - Timeline

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: entryDate, snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: entryDate, snapshot: WidgetSnapshot.read() ?? .placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = SnapshotEntry(date: entryDate, snapshot: WidgetSnapshot.read() ?? .placeholder)
        // The app reloads on save/open; this periodic refresh is only a backstop
        // for when the app has not run for a while.
        let next = Calendar.current.date(byAdding: .hour, value: 6, to: entryDate) ?? entry.date
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    /// The provider has no injected clock; `Date()` here is the widget process's
    /// wall clock (not the workflow environment), which is correct for a timeline.
    private var entryDate: Date { Date() }
}

// MARK: - Views

struct NetWorthWidgetView: View {
    var entry: SnapshotEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Net Worth", systemImage: "chart.line.uptrend.xyaxis")
                .font(.caption).foregroundStyle(.secondary)
            Text(entry.snapshot.netWorth)
                .font(.title2).fontWeight(.semibold)
                .minimumScaleFactor(0.6).lineLimit(1)
            Spacer(minLength: 0)
            Text(entry.snapshot.upcomingBills)
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct AlertsWidgetView: View {
    var entry: SnapshotEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Alerts", systemImage: "bell.badge")
                .font(.caption).foregroundStyle(.secondary)
            if entry.snapshot.alerts.isEmpty {
                Text("Nothing needs your attention.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(Array(entry.snapshot.alerts.prefix(3).enumerated()), id: \.offset) { _, alert in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(color(for: alert.severity))
                            .frame(width: 7, height: 7)
                        Text(alert.title)
                            .font(.footnote).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func color(for severity: Int) -> Color {
        switch severity {
        case 2: return .red
        case 1: return .orange
        default: return .secondary
        }
    }
}

// MARK: - Widgets

struct NetWorthWidget: Widget {
    let kind = "FinvestLensNetWorth"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SnapshotProvider()) { entry in
            NetWorthWidgetView(entry: entry)
        }
        .configurationDisplayName("Net Worth")
        .description("Your latest net worth and upcoming bills.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct AlertsWidget: Widget {
    let kind = "FinvestLensAlerts"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SnapshotProvider()) { entry in
            AlertsWidgetView(entry: entry)
        }
        .configurationDisplayName("Alerts")
        .description("Bills due, over-budget spending and other alerts.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct FinvestLensWidgetBundle: WidgetBundle {
    var body: some Widget {
        NetWorthWidget()
        AlertsWidget()
    }
}
