// swift-tools-version: 6.0
//
//  Package.swift
//  FinvestLens — Persistence
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import PackageDescription

let package = Package(
    name: "FinvestLensPersistence",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .macCatalyst(.v17),
    ],
    products: [
        .library(name: "FinvestLensPersistence", targets: ["FinvestLensPersistence"]),
    ],
    dependencies: [
        .package(path: "../Engine"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "FinvestLensPersistence",
            dependencies: [
                .product(name: "FinvestLensEngine", package: "Engine"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "FinvestLensPersistenceTests",
            dependencies: ["FinvestLensPersistence"]
        ),
    ]
)
