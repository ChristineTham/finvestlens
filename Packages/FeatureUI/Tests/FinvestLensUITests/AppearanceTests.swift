//
//  AppearanceTests.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import Testing
@testable import FinvestLensUI

@Suite("Appearance settings")
struct AppearanceTests {

    @Test("Theme maps to a preferred color scheme")
    func theme() {
        #expect(ColorSchemePreference.system.colorScheme == nil)
        #expect(ColorSchemePreference.light.colorScheme == .light)
        #expect(ColorSchemePreference.dark.colorScheme == .dark)
    }

    @Test("Text-size steps: five, default is the middle and the system default")
    func textSize() {
        #expect(TextSize.steps.count == 5)
        #expect(TextSize.defaultStep == 2)
        #expect(TextSize.dynamicType(TextSize.defaultStep) == .large)   // SwiftUI default
        #expect(TextSize.dynamicType(0) == .small)
        #expect(TextSize.dynamicType(4) == .xxLarge)
        // Out-of-range steps clamp.
        #expect(TextSize.dynamicType(-3) == .small)
        #expect(TextSize.dynamicType(99) == .xxLarge)
    }

    @Test("Accent palette includes the default lavender and is stable")
    func accents() {
        #expect(AppAccent.allCases.contains(.lavender))
        #expect(AppAccent(rawValue: "lavender") == .lavender)
        // Every accent yields a colour and a label.
        for accent in AppAccent.allCases {
            #expect(!accent.label.isEmpty)
            _ = accent.color
        }
    }
}
