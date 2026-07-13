//
//  WelcomeView.swift
//  finvestlens
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import FinvestLensUI

// MARK: - Brand palette (matches the app icon)

private enum Brand {
    static let violet = Color(.sRGB, red: 0.478, green: 0.357, blue: 0.941)   // #7A5BF0
    static let mauve  = Color(.sRGB, red: 0.757, green: 0.451, blue: 0.651)   // #C173A6
    static let apricot = Color(.sRGB, red: 0.969, green: 0.627, blue: 0.373)  // #F7A05F
    static let cream  = Color(.sRGB, red: 1.0, green: 0.969, blue: 0.937)     // #FFF7EF
}

// MARK: - Icon mark, reproduced

/// A 4-point sparkle (concave star).
private struct SparkleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cx = rect.midX, cy = rect.midY
        let rx = rect.width / 2, ry = rect.height / 2
        let k: CGFloat = 0.26
        var p = Path()
        p.move(to: CGPoint(x: cx, y: cy - ry))
        p.addQuadCurve(to: CGPoint(x: cx + rx, y: cy), control: CGPoint(x: cx + rx * k, y: cy - ry * k))
        p.addQuadCurve(to: CGPoint(x: cx, y: cy + ry), control: CGPoint(x: cx + rx * k, y: cy + ry * k))
        p.addQuadCurve(to: CGPoint(x: cx - rx, y: cy), control: CGPoint(x: cx - rx * k, y: cy + ry * k))
        p.addQuadCurve(to: CGPoint(x: cx, y: cy - ry), control: CGPoint(x: cx - rx * k, y: cy - ry * k))
        p.closeSubpath()
        return p
    }
}

/// The "rising insight" mark from the app icon: a growth line into a focal lens
/// node, with a sparkle. Drawn in normalised coordinates so it scales cleanly.
private struct RisingMark: View {
    var tint: Color = Brand.cream

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let pt: (CGFloat, CGFloat) -> CGPoint = { x, y in CGPoint(x: x * s, y: y * s) }
            ZStack {
                Path { p in
                    p.move(to: pt(0.24, 0.66))
                    p.addLine(to: pt(0.41, 0.53))
                    p.addLine(to: pt(0.54, 0.60))
                    p.addLine(to: pt(0.72, 0.36))
                }
                .stroke(tint, style: StrokeStyle(lineWidth: 0.05 * s, lineCap: .round, lineJoin: .round))

                Circle().strokeBorder(tint, lineWidth: 0.019 * s)
                    .frame(width: 0.19 * s, height: 0.19 * s).position(pt(0.72, 0.36))
                Circle().fill(tint)
                    .frame(width: 0.10 * s, height: 0.10 * s).position(pt(0.72, 0.36))
                SparkleShape().fill(tint)
                    .frame(width: 0.17 * s, height: 0.17 * s).position(pt(0.83, 0.24))
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - Splash / welcome

/// Adobe-style splash shown when no document is open: branded hero matching the
/// app icon, a tagline, actions (including GnuCash migration and recent books),
/// and a version / copyright credits strip.
struct WelcomeView: View {
    @Bindable var model: AppModel
    let onNew: () -> Void
    let onOpen: () -> Void

    @Environment(\.appFontScale) private var appFontScale
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 0) {
                Spacer(minLength: 24)
                hero
                Spacer(minLength: 20)
                actions
                recents
                Spacer(minLength: 22)
                credits
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 30)
        }
        .frame(minWidth: 560, minHeight: 520)
    }

    // MARK: Backdrop

    private var backdrop: some View {
        ZStack {
            LinearGradient(
                colors: scheme == .dark
                    ? [Color(.sRGB, red: 0.10, green: 0.07, blue: 0.16),
                       Color(.sRGB, red: 0.06, green: 0.04, blue: 0.09)]
                    : [Color(.sRGB, red: 0.99, green: 0.98, blue: 1.0),
                       Color(.sRGB, red: 0.98, green: 0.94, blue: 0.93)],
                startPoint: .topLeading, endPoint: .bottomTrailing)

            // Cool lavender glow, upper-left.
            RadialGradient(colors: [Brand.violet.opacity(scheme == .dark ? 0.42 : 0.28), .clear],
                           center: .init(x: 0.2, y: 0.15), startRadius: 1, endRadius: 460)
            // Warm apricot glow, lower-right — the sunrise from the icon.
            RadialGradient(colors: [Brand.apricot.opacity(scheme == .dark ? 0.34 : 0.30), .clear],
                           center: .init(x: 0.82, y: 0.9), startRadius: 1, endRadius: 520)

            // Faint oversized watermark of the mark, bottom-left.
            RisingMark(tint: (scheme == .dark ? Color.white : Brand.violet).opacity(0.05))
                .frame(width: 460, height: 460)
                .offset(x: -170, y: 190)
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 20) {
            medallion
            VStack(spacing: 10) {
                Text("FinvestLens")
                    .font(.system(size: 46 * appFontScale, weight: .bold, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: scheme == .dark
                                ? [.white, Color(.sRGB, red: 0.82, green: 0.75, blue: 1.0)]
                                : [Color(.sRGB, red: 0.32, green: 0.22, blue: 0.60), Brand.mauve],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                    .accessibilityAddTraits(.isHeader)
                Text("Bring your money into focus.")
                    .font(.system(size: 16 * appFontScale, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var medallion: some View {
        let size: CGFloat = 132
        return ZStack {
            ForEach(0..<2) { i in
                Circle()
                    .strokeBorder(Brand.apricot.opacity(0.18), lineWidth: 1)
                    .frame(width: size + CGFloat(i) * 48,
                           height: size + CGFloat(i) * 48)
                    .opacity(0.6)
            }
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(LinearGradient(colors: [Brand.violet, Brand.mauve, Brand.apricot],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size, height: size)
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(RadialGradient(colors: [Brand.apricot.opacity(0.6), .clear],
                                             center: .init(x: 0.7, y: 0.95), startRadius: 1, endRadius: size))
                        .blendMode(.plusLighter))
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.32), .clear],
                                             startPoint: .top, endPoint: .center))
                        .blendMode(.plusLighter))
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .strokeBorder(.white.opacity(0.28), lineWidth: 1))
                .overlay(RisingMark().padding(size * 0.14))
                .shadow(color: Brand.mauve.opacity(0.55), radius: 28, y: 16)
        }
        .accessibilityHidden(true)
    }

    // MARK: Actions

    private var actions: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Button(action: onNew) {
                    Label("New Book", systemImage: "plus")
                        .fontWeight(.semibold).frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.mauve)

                Button(action: onOpen) {
                    Label("Open…", systemImage: "folder").frame(minWidth: 96)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
            #if os(macOS)
            Button("Migrating from GnuCash? Import your file…") {
                DocumentDialogs.importGnuCash(model)
            }
            .buttonStyle(.link)
            .font(.system(size: 12.5 * appFontScale, design: .rounded))
            #endif
        }
    }

    /// Up to three recently opened books, one click away.
    @ViewBuilder
    private var recents: some View {
        if !model.recentBooks.isEmpty {
            VStack(spacing: 4) {
                Text("Recent")
                    .font(.system(size: 11 * appFontScale, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                ForEach(model.recentBooks.prefix(3), id: \.self) { url in
                    Button {
                        model.openBook(at: url)
                    } label: {
                        Label(url.deletingPathExtension().lastPathComponent,
                              systemImage: "clock.arrow.circlepath")
                            .font(.system(size: 12.5 * appFontScale, design: .rounded))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Brand.mauve)
                    .help(url.path)
                }
            }
            .padding(.top, 16)
        }
    }

    // MARK: Credits

    private var credits: some View {
        VStack(spacing: 6) {
            Rectangle()
                .fill(.primary.opacity(0.08))
                .frame(width: 220, height: 1)
                .padding(.bottom, 4)
            Text("\(BuildInfo.versionString)  ·  Built \(BuildInfo.buildDate)")
                .font(.system(size: 11.5 * appFontScale, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            Text("© 2026 Hello Tham  ·  Crafted by Chris Tham")
                .font(.system(size: 11.5 * appFontScale, design: .rounded))
                .foregroundStyle(.tertiary)
        }
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(BuildInfo.versionString), built \(BuildInfo.buildDate). Copyright 2026 Hello Tham, crafted by Chris Tham.")
    }

}
