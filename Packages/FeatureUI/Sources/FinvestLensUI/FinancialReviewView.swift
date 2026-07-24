//
//  FinancialReviewView.swift
//  FinvestLens — FeatureUI
//
//  The Financial Review deck (docs/report-redesign.md §3.3): 16:9 slides in
//  the shape of a CFO's results presentation — kicker, action title, big
//  callouts, one focused chart, footnote — paged horizontally with arrow
//  keys, exportable as a landscape PDF. The action title is deterministic;
//  when Apple Intelligence is available, each slide's headline and a short
//  insight are rewritten on-device from that slide's own facts pack.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import Charts
import PDFKit
import FinvestLensEngine
import FinvestLensReports
import FinvestLensIntelligence

// MARK: - Deck screen

struct FinancialReviewSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var period: ReportPeriod = .previousFinancialYear
    @State private var slides: [ReviewSlide] = []
    @State private var index = 0
    @State private var building = false
    @State private var exporting = false
    @State private var exportDocument: PDFReportDocument?
    /// Per-slide model stories, keyed by slide id (session-scoped view of
    /// the model's revision-keyed cache).
    @State private var stories: [String: ReviewSlideStory] = [:]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if building && slides.isEmpty {
                    ProgressView("Preparing the review…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if slides.isEmpty {
                    ContentUnavailableView("Nothing to review", systemImage: "chart.bar.doc.horizontal",
                                           description: Text("This period has no activity to present."))
                } else {
                    deck
                }
            }
            .navigationTitle("Financial Review")
            .onEscapeCommand { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem {
                    PeriodSelector(model: model, period: $period)
                }
                ToolbarItem {
                    Button("Export PDF…", systemImage: "arrow.up.doc") { exportDeck() }
                        .disabled(slides.isEmpty)
                        .help("Export the deck as a landscape PDF, one slide per page")
                }
            }
            .task(id: period) { await rebuild() }
            .fileExporter(isPresented: $exporting, document: exportDocument,
                          contentType: .pdf,
                          defaultFilename: "Financial Review — \(model.label(for: period))") { _ in }
        }
        .frame(minWidth: 980, minHeight: 660)
    }

    private var deck: some View {
        VStack(spacing: 10) {
            SlideCard(slide: slides[index], story: stories[slides[index].id])
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .id(slides[index].id)
                .transition(.opacity)
                .task(id: "\(slides[index].id):\(index)") {
                    // Fetch the story for the slide being viewed (cached in
                    // the model per book revision).
                    let slide = slides[index]
                    if stories[slide.id] == nil,
                       let story = await model.reviewStory(for: slide) {
                        stories[slide.id] = story
                    }
                }

            HStack(spacing: 16) {
                Button { withAnimation { index = max(0, index - 1) } } label: {
                    Image(systemName: "chevron.left")
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(index == 0)
                .accessibilityLabel("Previous slide")

                HStack(spacing: 6) {
                    ForEach(slides.indices, id: \.self) { slideIndex in
                        Circle()
                            .fill(slideIndex == index ? Color.accentColor : Color.secondary.opacity(0.35))
                            .frame(width: 7, height: 7)
                            .onTapGesture { withAnimation { index = slideIndex } }
                            .accessibilityLabel("Slide \(slideIndex + 1)")
                    }
                }

                Button { withAnimation { index = min(slides.count - 1, index + 1) } } label: {
                    Image(systemName: "chevron.right")
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(index == slides.count - 1)
                .accessibilityLabel("Next slide")

                Text("\(index + 1) of \(slides.count)")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.bottom, 12)
        }
    }

    private func rebuild() async {
        building = true
        defer { building = false }
        await Task.yield()
        let (from, to) = model.resolve(period)
        slides = model.financialReviewSlides(from: from, to: to,
                                             label: model.label(for: period))
        index = min(index, max(0, slides.count - 1))
        stories = [:]
    }

    /// One landscape page per slide, using whatever stories have been
    /// written so far (deterministic headlines otherwise).
    private func exportDeck() {
        let merged = PDFDocument()
        for slide in slides {
            let view = SlideCard(slide: slide, story: stories[slide.id])
                .frame(width: 960, height: 540)
            guard let data = ReportExport.pdfPage(view, size: CGSize(width: 960, height: 540)),
                  let pdf = PDFDocument(data: data) else { continue }
            for pageIndex in 0..<pdf.pageCount {
                if let page = pdf.page(at: pageIndex) {
                    merged.insert(page, at: merged.pageCount)
                }
            }
        }
        guard merged.pageCount > 0, let data = merged.dataRepresentation() else { return }
        exportDocument = PDFReportDocument(data: data)
        exporting = true
    }
}

// MARK: - One slide

struct SlideCard: View {
    let slide: ReviewSlide
    let story: ReviewSlideStory?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(slide.kicker.uppercased())
                .scaledFont(.caption, weight: .semibold)
                .kerning(1.2)
                .foregroundStyle(Color.accentColor)
                .padding(.bottom, 6)
            Text(story?.headline ?? slide.headline)
                .scaledFont(.title, weight: .bold)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)

            calloutRow
                .padding(.bottom, 14)

            chartView
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let story {
                Label {
                    Text(story.insight)
                        .scaledFont(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Color.accentColor)
                }
                .padding(.top, 10)
            }
            Text(slide.footnote)
                .scaledFont(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 6)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(white: 0.98))
                .shadow(color: .black.opacity(0.18), radius: 14, y: 5))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))
        .environment(\.colorScheme, .light)   // slides present like paper
    }

    private var calloutRow: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(slide.callouts) { callout in
                VStack(alignment: .leading, spacing: 2) {
                    Text(callout.label)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(callout.value)
                        .scaledFont(.title2, weight: .semibold)
                        .monospacedDigit()
                        .foregroundStyle(callout.deltaPositive == false ? .red : .primary)
                    if let delta = callout.delta {
                        Text(delta)
                            .scaledFont(.caption)
                            .foregroundStyle(callout.deltaPositive == true ? .green : .red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var chartView: some View {
        switch slide.chart {
        case .netWorthLine(let points):
            Chart(points) { point in
                LineMark(x: .value("Date", point.date),
                         y: .value("Net worth", asDouble(point.netWorth)))
                    .interpolationMethod(.monotone)
                AreaMark(x: .value("Date", point.date),
                         y: .value("Net worth", asDouble(point.netWorth)))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.linearGradient(colors: [.accentColor.opacity(0.25), .clear],
                                                     startPoint: .top, endPoint: .bottom))
            }
        case .waterfall(let steps):
            Chart(steps) { step in
                BarMark(x: .value("Step", step.label),
                        yStart: .value("From", asDouble(step.start)),
                        yEnd: .value("To", asDouble(step.end)))
                    .foregroundStyle(color(for: step.kind))
                    .cornerRadius(3)
            }
            .chartXAxis { AxisMarks { AxisValueLabel() } }
        case .categoryBars(let bars):
            Chart(bars) { bar in
                BarMark(x: .value("Amount", asDouble(bar.current)),
                        y: .value("Category", bar.label))
                    .foregroundStyle(asDouble(bar.current) < 0 ? Color.red.opacity(0.75)
                                                               : Color.accentColor)
                    .cornerRadius(3)
                if let prior = bar.prior {
                    PointMark(x: .value("Prior", asDouble(prior)),
                              y: .value("Category", bar.label))
                        .foregroundStyle(Color.secondary)
                        .symbol(.diamond)
                }
            }
            .chartLegend(.hidden)
        case .monthlyFlows(let months):
            Chart(months) { month in
                BarMark(x: .value("Month", month.month, unit: .month),
                        y: .value("Net", asDouble(month.income - month.expenses)))
                    .foregroundStyle(month.income >= month.expenses
                                     ? Color.accentColor : Color.red.opacity(0.75))
                    .cornerRadius(2)
            }
        case .allocation(let holdings):
            Chart(holdings, id: \.symbol) { holding in
                SectorMark(angle: .value("Value", asDouble(holding.value)),
                           innerRadius: .ratio(0.6), angularInset: 1)
                    .cornerRadius(2)
                    .foregroundStyle(by: .value("Security", holding.symbol))
            }
            .chartLegend(position: .trailing, alignment: .center)
        case .none:
            Color.clear
        }
    }

    private func color(for kind: WaterfallStep.Kind) -> Color {
        switch kind {
        case .anchor: Color.accentColor
        case .rise: Color.green.opacity(0.8)
        case .fall: Color.red.opacity(0.75)
        }
    }

    private func asDouble(_ value: Decimal) -> Double {
        NSDecimalNumber(decimal: value).doubleValue
    }
}
