// swift-tools-version: 6.0
//
//  Package.swift
//  FinvestLens — Quotes
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import PackageDescription

let package = Package(
    name: "FinvestLensQuotes",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .macCatalyst(.v17),
    ],
    products: [
        .library(name: "FinvestLensQuotes", targets: ["FinvestLensQuotes"]),
    ],
    dependencies: [
        .package(path: "../Engine"),
    ],
    targets: [
        .target(
            name: "FinvestLensQuotes",
            dependencies: [
                .product(name: "FinvestLensEngine", package: "Engine"),
            ]
        ),
        .testTarget(
            name: "FinvestLensQuotesTests",
            dependencies: ["FinvestLensQuotes"]
        ),
    ]
)
