//
//  AlertNotificationScheduler.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import UserNotifications
import FinvestLensReports

/// Delivers the proactive alerts engine (`FR-PLAN-05`) as local user
/// notifications. Remote push is intentionally out of scope — FinvestLens is
/// local-first, so there is no server to originate a push; these are
/// `UNUserNotificationCenter` local notifications scheduled on-device from the
/// same alerts the dashboard shows.
public enum AlertNotificationScheduler {

    /// Notification identifiers are namespaced so `sync` can reconcile the set
    /// it owns without disturbing anything else.
    private static let prefix = "finvestlens.alert."

    /// Requests authorization to post notifications. Returns whether it is
    /// granted. Safe to call repeatedly (the system prompts only once).
    @discardableResult
    public static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        return await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Reconciles delivered/pending notifications with the given alerts:
    /// schedules one per non-informational alert (deduped by the alert's stable
    /// id) and removes any previously scheduled alert notification that no
    /// longer applies. A no-op when authorization has not been granted.
    ///
    /// Takes an already-computed, `Sendable` `[FinancialAlert]` (the caller owns
    /// the non-`Sendable` `Book`), so it does no accounting work and touches no
    /// engine state — just `UNUserNotificationCenter`.
    public static func sync(alerts allAlerts: [FinancialAlert], asOf: Date = Date()) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized ||
              settings.authorizationStatus == .provisional else { return }

        let alerts = allAlerts.filter { $0.severity >= .warning }

        // Drop stale alert notifications this type previously scheduled.
        let keepIDs = Set(alerts.map { prefix + $0.id })
        let pending = await center.pendingNotificationRequests()
        let staleIDs = pending.map(\.identifier)
            .filter { $0.hasPrefix(prefix) && !keepIDs.contains($0) }
        if !staleIDs.isEmpty { center.removePendingNotificationRequests(withIdentifiers: staleIDs) }

        for alert in alerts {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.message
            content.sound = alert.severity == .critical ? .defaultCritical : .default

            // Fire on the alert's due date when it is in the future; otherwise
            // surface shortly (a small delay, since a zero-interval trigger is
            // rejected).
            let trigger: UNNotificationTrigger
            if let date = alert.date, date > asOf {
                let comps = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute], from: date
                )
                trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            } else {
                trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
            }

            let request = UNNotificationRequest(
                identifier: prefix + alert.id, content: content, trigger: trigger
            )
            try? await center.add(request)
        }
    }

    /// Cancels every alert notification this type scheduled (e.g. on closing a
    /// book).
    public static func cancelAll() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}
