import SwiftUI

struct AnalysisView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Button {
                        model.showsCoachChat = true
                    } label: {
                        Label("Ask the coach", systemImage: "bubble.left.and.text.bubble.right")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .cardBackground()
                    }
                    RunAnalysisCard()
                    if let latest = model.latestAnalysis {
                        ReportContent(analysis: latest)
                    }
                    if model.history.count > 1 {
                        NavigationLink {
                            HistoryList()
                        } label: {
                            Label("Past analyses (\(model.history.count - 1))", systemImage: "clock.arrow.circlepath")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .cardBackground()
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("AI Coach")
            .navigationDestination(isPresented: $model.showsCoachChat) { ChatView(chat: model.chat) }
            .onAppear {
                if !model.isAnalyzing { AppleAnalyzer.prewarm(instructions: PromptBuilder.instructions) }
            }
        }
    }
}

private struct RunAnalysisCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            HStack {
                Label(modelLabel, systemImage: "apple.intelligence")
                .font(.subheadline.bold())
                Spacer()
                if let snapshot = model.snapshot {
                    Text("\(snapshot.workouts.count) workouts · \(snapshot.sleep.count) nights")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            AnalyzeControls(
                isRunning: model.isAnalyzing,
                runningText: model.analysisStep ?? "Apple Intelligence is analyzing your data…",
                buttonTitle: model.latestAnalysis == nil ? "Analyze my data" : "Run a new analysis",
                isDisabled: model.snapshot == nil,
                notice: model.analysisNotice,
                error: model.analysisError
            ) {
                Task { await model.runAnalysis() }
            }
            if model.isAnalyzing, let preview = model.analysisPreview {
                ReportPreview(report: preview)
            }
            if model.snapshot == nil, model.aiBlocker == nil {
                Text("Connect Apple Health on the Dashboard first.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var modelLabel: String {
        model.usesPrivateCloud ? "Apple Intelligence · Private Cloud" : "Apple Intelligence · On-device"
    }
}

/// The weekly analysis while Apple Intelligence is still writing it.
private struct ReportPreview: View {
    var report: AnalysisReport.PartiallyGenerated

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if let headline = report.headline {
                Text(headline).font(.headline)
            }
            if let assessment = report.assessment {
                Text(assessment).font(.subheadline).foregroundStyle(.secondary)
            }
            if let insights = report.insights, !insights.isEmpty {
                ForEach(Array(insights.enumerated()), id: \.offset) { _, insight in
                    if let title = insight.title {
                        Label(title, systemImage: "sparkle").font(.footnote)
                    }
                }
            }
            if let plan = report.weekPlan, !plan.isEmpty {
                Label("Planning day \(min(plan.count, 7)) of 7…", systemImage: "calendar").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .animation(.default, value: report.headline)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ReportContent: View {
    var analysis: SavedAnalysis

    private var report: AnalysisReport { analysis.report }

    var body: some View {
        VStack(spacing: 16) {
            Card {
                HStack {
                    StatusBadge(text: report.trainingStatus.title, color: report.trainingStatus.color)
                    Spacer()
                    Text("\(analysis.modelName) · \(analysis.createdAt.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(report.headline).font(.title3.bold())
                Text(report.assessment).font(.subheadline)
            }

            Card(title: "Insights") {
                ForEach(Array(report.insights.enumerated()), id: \.offset) { _, insight in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: insight.tone.systemImage)
                            .foregroundStyle(insight.tone.color)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(insight.title).font(.subheadline.bold())
                                Image(systemName: insight.area.focusArea.systemImage)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(insight.detail).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Card(title: "What to change") {
                let sorted = report.recommendations.sorted { $0.priority.rank < $1.priority.rank }
                ForEach(Array(sorted.enumerated()), id: \.offset) { index, recommendation in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(recommendation.priority.rawValue.uppercased())
                                .font(.caption2.bold())
                                .foregroundStyle(recommendation.priority.color)
                            Label(recommendation.area.focusArea.title, systemImage: recommendation.area.focusArea.systemImage)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(recommendation.action).font(.subheadline.bold())
                        Text(recommendation.rationale).font(.footnote).foregroundStyle(.secondary)
                    }
                    if index < sorted.count - 1 { Divider() }
                }
            }

            if !report.goalOutlook.isEmpty {
                Card(title: "Goal outlook") {
                    Text(report.goalOutlook).font(.subheadline)
                }
            }
        }
    }
}

/// Analyses before the latest one, which the Coach tab already shows.
private struct HistoryList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            ForEach(model.history.dropFirst()) { analysis in
                NavigationLink {
                    ScrollView {
                        VStack(spacing: 16) {
                            ReportContent(analysis: analysis)
                            WeekPlanList(analysis: analysis)
                        }
                        .padding()
                    }
                    .navigationTitle(analysis.createdAt.formatted(date: .abbreviated, time: .omitted))
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(analysis.report.headline).font(.subheadline).lineLimit(2)
                        Text("\(analysis.modelName) · \(analysis.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in model.deleteAnalyses(at: IndexSet(offsets.map { $0 + 1 })) }
        }
        .navigationTitle("Past analyses")
    }
}
