// swift-tools-version: 6.0
//
//  Package.swift
//  FinvestLens — Interchange
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import PackageDescription

let package = Package(
    name: "FinvestLensInterchange",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .macCatalyst(.v17),
    ],
    products: [
        .library(name: "FinvestLensInterchange", targets: ["FinvestLensInterchange"]),
    ],
    dependencies: [
        .package(path: "../Engine"),
    ],
    targets: [
        .target(
            name: "FinvestLensInterchange",
            dependencies: [
                .product(name: "FinvestLensEngine", package: "Engine"),
            ]
        ),
        .testTarget(
            name: "FinvestLensInterchangeTests",
            dependencies: ["FinvestLensInterchange"]
        ),
    ]
)
