//
//  Appearance.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Persisted appearance-preference keys (shared by the modifier and the
/// settings pane).
public enum AppearanceKey {
    public static let colorScheme = "appearance.colorScheme"
    public static let accent = "appearance.accent"
    public static let textStep = "appearance.textStep"
}

/// Theme mode: follow the system, or force light/dark.
public enum ColorSchemePreference: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    public var id: String { rawValue }
    public var label: String {
        switch self { case .system: "Auto"; case .light: "Light"; case .dark: "Dark" }
    }
    public var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

/// The selectable UI accent colours (macOS-style). Each adapts to light/dark for
/// legible contrast in both. Lavender/mauve is the default.
public enum AppAccent: String, CaseIterable, Identifiable, Sendable {
    case lavender, blue, teal, green, yellow, orange, pink, red, graphite

    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }

    /// A colour that resolves lighter in dark mode and richer in light mode, so
    /// text/fills keep enough contrast either way.
    public var color: Color {
        switch self {
        case .lavender: Color.dynamic(light: rgb(0.46, 0.36, 0.80), dark: rgb(0.74, 0.64, 0.98))
        case .blue:     Color.dynamic(light: rgb(0.00, 0.48, 1.00), dark: rgb(0.34, 0.64, 1.00))
        case .teal:     Color.dynamic(light: rgb(0.00, 0.52, 0.56), dark: rgb(0.32, 0.80, 0.83))
        case .green:    Color.dynamic(light: rgb(0.15, 0.53, 0.25), dark: rgb(0.40, 0.78, 0.46))
        case .yellow:   Color.dynamic(light: rgb(0.72, 0.55, 0.00), dark: rgb(0.95, 0.80, 0.32))
        case .orange:   Color.dynamic(light: rgb(0.84, 0.44, 0.00), dark: rgb(1.00, 0.62, 0.26))
        case .pink:     Color.dynamic(light: rgb(0.83, 0.24, 0.54), dark: rgb(1.00, 0.47, 0.71))
        case .red:      Color.dynamic(light: rgb(0.78, 0.19, 0.19), dark: rgb(1.00, 0.44, 0.44))
        case .graphite: Color.dynamic(light: rgb(0.38, 0.38, 0.41), dark: rgb(0.64, 0.64, 0.67))
        }
    }

    private func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

/// The stepped text-size scale (small … large, default in the middle).
///
/// macOS has no Dynamic Type: SwiftUI text does not respond to
/// `dynamicTypeSize` there. So text size is driven by an explicit multiplier
/// applied to font point sizes (see ``ScaledFont`` and `\.appFontScale`), which
/// works identically on every platform.
public enum TextSize {
    /// Five slider steps; index 2 is the (1.0×) default and the mid-point.
    public static let stepCount = 5
    public static let defaultStep = 2

    /// Font-size multiplier for a slider step. Clamps out-of-range steps.
    public static func scale(_ step: Int) -> CGFloat {
        let factors: [CGFloat] = [0.85, 0.92, 1.0, 1.15, 1.30]
        return factors[min(max(step, 0), factors.count - 1)]
    }
}

/// Base point sizes for the semantic text styles (macOS metrics). Used by
/// ``ScaledFont`` to produce a crisp, explicitly-scaled font.
enum TextStyleMetrics {
    static func size(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline: 13
        case .body: 13
        case .callout: 12
        case .subheadline: 11
        case .footnote: 10
        case .caption: 10
        case .caption2: 10
        @unknown default: 13
        }
    }

    static func weight(_ style: Font.TextStyle) -> Font.Weight {
        style == .headline ? .semibold : .regular
    }
}

/// The app-wide font-size multiplier, published through the environment so
/// text re-scales when the user moves the Text Size slider.
private struct AppFontScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

public extension EnvironmentValues {
    var appFontScale: CGFloat {
        get { self[AppFontScaleKey.self] }
        set { self[AppFontScaleKey.self] = newValue }
    }
}

/// Applies a semantic text style as an explicitly-scaled system font, so it
/// grows/shrinks with the user's Text Size preference on every platform
/// (including macOS, which ignores Dynamic Type).
struct ScaledFont: ViewModifier {
    @Environment(\.appFontScale) private var scale
    let style: Font.TextStyle
    let weight: Font.Weight?
    let design: Font.Design?

    func body(content: Content) -> some View {
        content.font(.system(
            size: TextStyleMetrics.size(style) * scale,
            weight: weight ?? TextStyleMetrics.weight(style),
            design: design ?? .default))
    }
}

public extension View {
    /// Drop-in replacement for `.font(.<style>)` that honours the app's Text
    /// Size preference. Optional `weight`/`design` mirror `.font(.system(...))`.
    func scaledFont(_ style: Font.TextStyle,
                    weight: Font.Weight? = nil,
                    design: Font.Design? = nil) -> some View {
        modifier(ScaledFont(style: style, weight: weight, design: design))
    }
}

public extension Color {
    /// A colour that resolves differently in light vs dark appearance, so accents
    /// keep contrast in both (context-adaptive).
    static func dynamic(light: Color, dark: Color) -> Color {
        #if canImport(AppKit)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
        #elseif canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            UIColor(traits.userInterfaceStyle == .dark ? dark : light)
        })
        #else
        return light
        #endif
    }
}

/// Applies the persisted appearance (theme, accent, text size) to a view tree.
/// Attach once at the app root.
public struct AppearanceModifier: ViewModifier {
    @AppStorage(AppearanceKey.colorScheme) private var schemeRaw = ColorSchemePreference.system.rawValue
    @AppStorage(AppearanceKey.accent) private var accentRaw = AppAccent.lavender.rawValue
    @AppStorage(AppearanceKey.textStep) private var textStep = TextSize.defaultStep

    public init() {}

    private var scheme: ColorSchemePreference { ColorSchemePreference(rawValue: schemeRaw) ?? .system }

    private var fontScale: CGFloat { TextSize.scale(textStep) }

    public func body(content: Content) -> some View {
        content
            .tint((AppAccent(rawValue: accentRaw) ?? .lavender).color)
            // Explicit scaling — macOS ignores Dynamic Type. Publish the factor
            // for `.scaledFont(...)` and scale the default font so text that
            // relies on the body style (lists, forms, labels) scales too.
            .environment(\.appFontScale, fontScale)
            .environment(\.font, .system(size: TextStyleMetrics.size(.body) * fontScale))
        #if canImport(AppKit)
            // Drive NSApp.appearance directly: unlike preferredColorScheme(nil),
            // this reliably reverts to the system appearance when switching back
            // to Auto within a session.
            .onAppear { Self.applyAppKitAppearance(scheme) }
            .onChange(of: schemeRaw) { Self.applyAppKitAppearance(scheme) }
        #else
            .preferredColorScheme(scheme.colorScheme)
        #endif
    }

    #if canImport(AppKit)
    private static func applyAppKitAppearance(_ preference: ColorSchemePreference) {
        let appearance: NSAppearance? = switch preference {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        NSApplication.shared.appearance = appearance
    }
    #endif
}

public extension View {
    /// Applies the user's persisted appearance preferences.
    func finvestLensAppearance() -> some View { modifier(AppearanceModifier()) }
}
