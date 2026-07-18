//
//  SharedAppGroup.swift
//  FinvestLens — Shared
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The App Group shared between the app and its WidgetKit / Quick Look
/// extensions. The identifier must match the `com.apple.security.application-groups`
/// entry in every target's entitlements.
public enum SharedAppGroup {

    /// Keep in sync with `finvestlens/finvestlens.entitlements` and each
    /// extension's `.entitlements`.
    public static let identifier = "group.com.hellotham.finvestlens.shared"

    /// The shared container directory, or `nil` if the App Group is not yet
    /// provisioned (development before the capability is enabled).
    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// The file the app writes and the extensions read.
    public static var snapshotURL: URL? {
        containerURL?.appendingPathComponent("widget-snapshot.json", isDirectory: false)
    }

    /// A `UserDefaults` suite shared across the App Group (small scalar state).
    public static var defaults: UserDefaults? {
        UserDefaults(suiteName: identifier)
    }
}
