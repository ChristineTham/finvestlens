// swift-tools-version: 6.2
//
//  Package.swift
//  FinvestLens — Shared
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import PackageDescription

// A Foundation-only leaf package: the App Group container helper and the small
// Codable snapshot the app publishes for its WidgetKit and Quick Look
// extensions. It deliberately depends on nothing (no Engine / GRDB / SwiftUI)
// so a memory-limited extension can link it without pulling the whole app.
let package = Package(
    name: "FinvestLensShared",
    platforms: [
        .macOS("26.0"),
        .iOS("26.0"),
        .macCatalyst("26.0"),
    ],
    products: [
        .library(name: "FinvestLensShared", targets: ["FinvestLensShared"]),
    ],
    targets: [
        .target(
            name: "FinvestLensShared"
        ),
        .testTarget(
            name: "FinvestLensSharedTests",
            dependencies: ["FinvestLensShared"]
        ),
    ]
)
