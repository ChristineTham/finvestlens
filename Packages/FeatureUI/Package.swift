// swift-tools-version: 6.0
//
//  Package.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import PackageDescription

let package = Package(
    name: "FinvestLensUI",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .macCatalyst(.v17),
    ],
    products: [
        .library(name: "FinvestLensUI", targets: ["FinvestLensUI"]),
    ],
    dependencies: [
        .package(path: "../Engine"),
        .package(path: "../Persistence"),
        .package(path: "../Interchange"),
        .package(path: "../Reports"),
        .package(path: "../Rules"),
        .package(path: "../Quotes"),
        .package(path: "../Intelligence"),
    ],
    targets: [
        .target(
            name: "FinvestLensUI",
            dependencies: [
                .product(name: "FinvestLensEngine", package: "Engine"),
                .product(name: "FinvestLensPersistence", package: "Persistence"),
                .product(name: "FinvestLensInterchange", package: "Interchange"),
                .product(name: "FinvestLensReports", package: "Reports"),
                .product(name: "FinvestLensRules", package: "Rules"),
                .product(name: "FinvestLensQuotes", package: "Quotes"),
                .product(name: "FinvestLensIntelligence", package: "Intelligence"),
            ]
        ),
        .testTarget(
            name: "FinvestLensUITests",
            dependencies: ["FinvestLensUI"]
        ),
    ]
)
