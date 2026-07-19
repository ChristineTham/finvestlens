// swift-tools-version: 6.2
//
//  Package.swift
//  FinvestLens — Engine
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import PackageDescription

let package = Package(
    name: "FinvestLensEngine",
    platforms: [
        .macOS("26.0"),
        .iOS("26.0"),
        .macCatalyst("26.0"),
    ],
    products: [
        .library(name: "FinvestLensEngine", targets: ["FinvestLensEngine"]),
    ],
    targets: [
        .target(
            name: "FinvestLensEngine"
        ),
        .testTarget(
            name: "FinvestLensEngineTests",
            dependencies: ["FinvestLensEngine"]
        ),
    ]
)
