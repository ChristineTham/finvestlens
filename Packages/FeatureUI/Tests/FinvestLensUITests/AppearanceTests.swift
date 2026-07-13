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

    @Test("Text-size steps: five, default is the middle at 1.0×")
    func textSize() {
        #expect(TextSize.stepCount == 5)
        #expect(TextSize.defaultStep == 2)
        #expect(TextSize.scale(TextSize.defaultStep) == 1.0)
        #expect(TextSize.scale(0) < 1.0)   // smaller
        #expect(TextSize.scale(4) > 1.0)   // larger
        // Monotonic increasing across the range.
        #expect(TextSize.scale(0) < TextSize.scale(2))
        #expect(TextSize.scale(2) < TextSize.scale(4))
        // Out-of-range steps clamp to the ends.
        #expect(TextSize.scale(-3) == TextSize.scale(0))
        #expect(TextSize.scale(99) == TextSize.scale(4))
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
