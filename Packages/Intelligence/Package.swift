// swift-tools-version: 6.0
//
//  Package.swift
//  FinvestLens — Intelligence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import PackageDescription

let package = Package(
    name: "FinvestLensIntelligence",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .macCatalyst(.v17),
    ],
    products: [
        .library(name: "FinvestLensIntelligence", targets: ["FinvestLensIntelligence"]),
    ],
    dependencies: [
        .package(path: "../Engine"),
        .package(path: "../Interchange"),
    ],
    targets: [
        .target(
            name: "FinvestLensIntelligence",
            dependencies: [
                .product(name: "FinvestLensEngine", package: "Engine"),
                .product(name: "FinvestLensInterchange", package: "Interchange"),
            ]
        ),
        .testTarget(
            name: "FinvestLensIntelligenceTests",
            dependencies: ["FinvestLensIntelligence"]
        ),
    ]
)
