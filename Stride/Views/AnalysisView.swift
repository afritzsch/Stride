import SwiftUI

struct AnalysisView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
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
                                .padding()
                                .background(.background.secondary, in: .rect(cornerRadius: 16))
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("AI Coach")
        }
    }
}

private struct RunAnalysisCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            HStack {
                Label(
                    model.engine == .claude ? "Claude" : "Apple on-device model",
                    systemImage: model.engine == .claude ? "sparkles" : "iphone"
                )
                .font(.subheadline.bold())
                Spacer()
                if let snapshot = model.snapshot {
                    Text("\(snapshot.workouts.count) workouts · \(snapshot.sleep.count) nights")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if model.isAnalyzing {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(model.engine == .claude ? "Claude is reviewing 8 weeks of data. This can take a minute…" : "Analyzing on device…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    Task { await model.runAnalysis() }
                } label: {
                    Label(model.latestAnalysis == nil ? "Analyze my data" : "Run a new analysis", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.snapshot == nil || model.engineBlocker != nil)
            }

            if let blocker = model.engineBlocker {
                Text(blocker).font(.footnote).foregroundStyle(.orange)
            } else if model.snapshot == nil {
                Text("Connect Apple Health on the Dashboard first.").font(.footnote).foregroundStyle(.secondary)
            }
            if let error = model.analysisError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
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
                    Text("\(analysis.engine.title) · \(analysis.createdAt.formatted(.relative(presentation: .named)))")
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

private struct HistoryList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            ForEach(model.history) { analysis in
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
                        Text("\(analysis.engine.title) · \(analysis.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { model.deleteAnalyses(at: $0) }
        }
        .navigationTitle("Past analyses")
    }
}
