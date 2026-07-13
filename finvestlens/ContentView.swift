//
//  ContentView.swift
//  finvestlens
//
//  Created by Chris Tham on 12/7/2026.
//
//  This file is part of FinvestLens.
//
//  Copyright (C) 2026 Christine Tham
//
//  FinvestLens is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  FinvestLens is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with FinvestLens.  If not, see <https://www.gnu.org/licenses/>.
//

import SwiftUI
import UniformTypeIdentifiers
import FinvestLensUI

/// Hosts either the welcome screen or an open document.
struct RootHost: View {
    @Bindable var model: AppModel
    @State private var importing = false
    @State private var errorMessage: String?

    static var documentType: UTType {
        UTType(exportedAs: "com.hellotham.finvestlens.document", conformingTo: .database)
    }

    var body: some View {
        Group {
            if model.isOpen && model.isLocked {
                LockView(model: model)
            } else if model.isOpen {
                FinvestLensRootView(model: model)
            } else {
                WelcomeView(onNew: newTemporary) { importing = true }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [Self.documentType, .data]) { result in
            if case .success(let url) = result {
                do { try model.open(at: url) }
                catch { errorMessage = error.localizedDescription }
            }
        }
        .alert("Couldn’t open document",
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func newTemporary() {
        let name = "Untitled-\(UUID().uuidString.prefix(6)).finvestlens"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? model.newDocument(at: url)
    }
}

/// Animated splash / welcome screen shown when no document is open. The lavender
/// "building.columns" medallion mirrors the app icon; the backdrop and wordmark
/// follow the theme.
struct WelcomeView: View {
    let onNew: () -> Void
    let onOpen: () -> Void

    @Environment(\.appFontScale) private var appFontScale
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var appeared = false
    @State private var glow = false

    // Brand lavender/mauve palette — the app's identity colour, independent of
    // the user-selectable accent so the splash always reads as FinvestLens.
    private let brandLight = Color(.sRGB, red: 0.60, green: 0.49, blue: 0.95)
    private let brandMid   = Color(.sRGB, red: 0.49, green: 0.37, blue: 0.86)
    private let brandDeep  = Color(.sRGB, red: 0.35, green: 0.25, blue: 0.66)

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 20) {
                emblem
                    .padding(.bottom, 6)
                wordmark
                actions
                    .padding(.top, 10)
            }
            .padding(56)
        }
        .frame(minWidth: 500, minHeight: 460)
        .onAppear(perform: animateIn)
    }

    // MARK: Backdrop

    private var backdrop: some View {
        ZStack {
            LinearGradient(
                colors: scheme == .dark
                    ? [Color(.sRGB, red: 0.09, green: 0.07, blue: 0.15),
                       Color(.sRGB, red: 0.05, green: 0.04, blue: 0.09)]
                    : [Color(.sRGB, red: 0.98, green: 0.97, blue: 1.00),
                       Color(.sRGB, red: 0.93, green: 0.91, blue: 0.99)],
                startPoint: .top, endPoint: .bottom)

            // Soft lavender halo behind the emblem that breathes gently.
            RadialGradient(
                colors: [brandMid.opacity(scheme == .dark ? 0.55 : 0.35), .clear],
                center: .center, startRadius: 1, endRadius: 360)
                .scaleEffect(glow ? 1.08 : 0.9)
                .opacity(glow ? 1 : 0.7)
                .blur(radius: 40)
                .offset(y: -70)
        }
        .ignoresSafeArea()
    }

    // MARK: Emblem

    private var emblem: some View {
        let size: CGFloat = 118
        return ZStack {
            // Concentric halo rings.
            ForEach(0..<2) { i in
                Circle()
                    .strokeBorder(brandLight.opacity(0.16), lineWidth: 1)
                    .frame(width: size + CGFloat(i) * 46 + (glow ? 14 : 0),
                           height: size + CGFloat(i) * 46 + (glow ? 14 : 0))
                    .opacity(glow ? 0.35 : 0.7)
            }

            // Icon-style medallion.
            RoundedRectangle(cornerRadius: 27, style: .continuous)
                .fill(LinearGradient(colors: [brandLight, brandDeep],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size, height: size)
                .overlay(
                    RoundedRectangle(cornerRadius: 27, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.35), .clear],
                                             startPoint: .top, endPoint: .center))
                        .blendMode(.plusLighter))
                .overlay(
                    RoundedRectangle(cornerRadius: 27, style: .continuous)
                        .strokeBorder(.white.opacity(0.25), lineWidth: 1))
                .overlay(
                    Image(systemName: "building.columns")
                        .font(.system(size: 56, weight: .regular))
                        .foregroundStyle(.white)
                        .shadow(color: brandDeep.opacity(0.5), radius: 4, y: 2))
                .shadow(color: brandMid.opacity(0.55), radius: 26, y: 14)
        }
        .scaleEffect(appeared ? 1 : 0.82)
        .opacity(appeared ? 1 : 0)
        .offset(y: glow ? -4 : 4)
        .accessibilityHidden(true)
    }

    // MARK: Wordmark

    private var wordmark: some View {
        VStack(spacing: 8) {
            Text("FinvestLens")
                .font(.system(size: 42 * appFontScale, weight: .bold, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: scheme == .dark
                            ? [.white, Color(.sRGB, red: 0.80, green: 0.73, blue: 1.0)]
                            : [brandDeep, brandMid],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                .accessibilityAddTraits(.isHeader)
            Text("Native double-entry accounting")
                .font(.system(size: 15 * appFontScale, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 12)
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 14) {
            Button(action: onNew) {
                Label("New Book", systemImage: "plus")
                    .fontWeight(.semibold)
                    .frame(minWidth: 118)
            }
            .buttonStyle(.borderedProminent)
            .tint(brandMid)

            Button(action: onOpen) {
                Label("Open…", systemImage: "folder")
                    .frame(minWidth: 96)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 16)
    }

    // MARK: Animation

    private func animateIn() {
        if reduceMotion {
            appeared = true
            return
        }
        withAnimation(.spring(response: 0.75, dampingFraction: 0.72)) { appeared = true }
        withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true)) { glow = true }
    }
}
