//
//  AppearanceSettingsView.swift
//  FinvestLens — FeatureUI
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

/// The Appearance preferences: theme, accent colour and text size — mirroring
/// macOS System Settings ▸ Appearance.
public struct AppearanceSettingsView: View {
    @AppStorage(AppearanceKey.colorScheme) private var schemeRaw = ColorSchemePreference.system.rawValue
    @AppStorage(AppearanceKey.accent) private var accentRaw = AppAccent.lavender.rawValue
    @AppStorage(AppearanceKey.textStep) private var textStep = TextSize.defaultStep

    public init() {}

    private var accent: AppAccent { AppAccent(rawValue: accentRaw) ?? .lavender }

    public var body: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $schemeRaw) {
                    ForEach(ColorSchemePreference.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Appearance theme")
            }

            Section("Accent Colour") {
                accentSwatches
            }

            Section("Text Size") {
                HStack(spacing: 12) {
                    Text("A").font(.footnote)
                    Slider(value: Binding(
                        get: { Double(textStep) },
                        set: { textStep = Int($0.rounded()) }),
                        in: 0...Double(TextSize.stepCount - 1), step: 1)
                    .accessibilityLabel("Text size")
                    .accessibilityValue(textSizeLabel)
                    Text("A").font(.title2)
                }
                Button("Reset to Default") { textStep = TextSize.defaultStep }
                    .font(.caption)
                    .disabled(textStep == TextSize.defaultStep)
            }

            Section("Preview") {
                previewCard
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 460)
        .tint(accent.color)
        .navigationTitle("Appearance")
    }

    private var accentSwatches: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 12)], spacing: 12) {
            ForEach(AppAccent.allCases) { option in
                Button {
                    accentRaw = option.rawValue
                } label: {
                    Circle()
                        .fill(option.color)
                        .frame(width: 30, height: 30)
                        .overlay {
                            if option == accent {
                                Image(systemName: "checkmark")
                                    .font(.caption.bold())
                                    .foregroundStyle(.white)
                            }
                        }
                        .overlay {
                            Circle().strokeBorder(.primary.opacity(option == accent ? 0.6 : 0), lineWidth: 2)
                        }
                }
                .buttonStyle(.plain)
                .help(option.label)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(option == accent ? [.isSelected] : [])
            }
        }
        .padding(.vertical, 4)
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The quick brown fox").scaledFont(.headline)
            Text("Accent-tinted controls and text scale with your settings.")
                .scaledFont(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Primary") {}.buttonStyle(.borderedProminent)
                Button("Secondary") {}.buttonStyle(.bordered)
                Toggle("On", isOn: .constant(true)).labelsHidden()
                ProgressView(value: 0.6).frame(width: 80)
            }
        }
        .padding(.vertical, 4)
    }

    private var textSizeLabel: String {
        switch textStep {
        case 0: "Small"; case 1: "Medium small"; case 2: "Default"
        case 3: "Large"; default: "Extra large"
        }
    }
}
