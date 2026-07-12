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
    ],
    targets: [
        .target(
            name: "FinvestLensUI",
            dependencies: [
                .product(name: "FinvestLensEngine", package: "Engine"),
                .product(name: "FinvestLensPersistence", package: "Persistence"),
                .product(name: "FinvestLensInterchange", package: "Interchange"),
            ]
        ),
        .testTarget(
            name: "FinvestLensUITests",
            dependencies: ["FinvestLensUI"]
        ),
    ]
)
