import SwiftUI

/// The note field, the run button and the coach's review of one workout. It owns the note and the review state,
/// so typing or a streaming preview doesn't rebuild the charts and the map above it.
struct CoachReviewSection: View {
    @Environment(AppModel.self) private var model
    var workout: WorkoutSummary
    var detail: WorkoutDetail?
    /// Debug launch hook: run the review as soon as the workout has loaded.
    var analyzesOnLoad = false

    @State private var note = ""
    @State private var analysisError: String?
    @State private var notice: String?

    private var isAnalyzing: Bool { model.analyzingWorkoutIDs.contains(workout.id) }
    private var showsEffort: Bool { workout.kind == .endurance }

    var body: some View {
        VStack(spacing: 16) {
            Card(title: "Coach review") {
                TextField("How did it feel? What was the plan? (optional)", text: $note, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
                AnalyzeControls(
                    isRunning: isAnalyzing,
                    runningText: "Reviewing your session…",
                    buttonTitle: model.runAnalyses[workout.id] == nil ? "Analyze this \(workout.sport.lowercased())" : "Analyze again",
                    isDisabled: detail == nil,
                    notice: notice,
                    error: analysisError
                ) {
                    Task { await analyze() }
                }
            }
            .id("review")
            if isAnalyzing, let preview = model.runPreviews[workout.id] {
                RunAnalysisPreview(analysis: preview, showsEffort: showsEffort)
            } else if let saved = model.runAnalyses[workout.id] {
                RunAnalysisContent(saved: saved, showsEffort: showsEffort).id("analysis")
            }
        }
        .task {
            if note.isEmpty, let saved = model.runAnalyses[workout.id] { note = saved.note }
        }
        .task(id: analyzesOnLoad) {
            guard analyzesOnLoad, detail != nil, model.runAnalyses[workout.id] == nil else { return }
            await analyze()
        }
    }

    private func analyze() async {
        guard let detail else { return }
        analysisError = nil
        notice = nil
        do {
            notice = try await model.analyzeWorkout(detail, note: note)
            if let notice { model.debugLog("Run analysis notice: \(notice)") }
        } catch {
            analysisError = error.localizedDescription
            model.debugLog("Run analysis failed: \(error)")
        }
    }
}

/// The coach review while Apple Intelligence is still writing it.
struct RunAnalysisPreview: View {
    var analysis: RunAnalysis.PartiallyGenerated
    var showsEffort: Bool

    var body: some View {
        Card {
            if showsEffort, let effort = analysis.effort {
                StatusBadge(text: effort.rawValue.capitalized, color: effort.color)
            }
            if let headline = analysis.headline {
                Text(headline).font(.title3.bold())
            }
            ForEach(Array((analysis.summary ?? []).enumerated()), id: \.offset) { _, point in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(.secondary)
                    Text(point)
                }
                .font(.subheadline)
            }
            ProgressView().frame(maxWidth: .infinity)
        }
    }
}

struct RunAnalysisContent: View {
    var saved: SavedRunAnalysis
    /// Off for strength sessions, including reviews saved before they stopped getting a heart-rate effort.
    var showsEffort: Bool

    private var analysis: RunAnalysis { saved.analysis }
    private var effort: EffortLevel? { showsEffort ? analysis.effort : nil }

    var body: some View {
        VStack(spacing: 16) {
            Card {
                GeneratedHeader(
                    status: effort?.rawValue.capitalized,
                    color: effort?.color ?? .secondary,
                    modelName: saved.modelName,
                    createdAt: saved.createdAt
                )
                Text(analysis.headline).font(.title3.bold())
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(analysis.summary, id: \.self) { point in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•").foregroundStyle(effort?.color ?? .secondary)
                            Text(point)
                        }
                    }
                }
                .font(.subheadline)
                if !analysis.planComparison.isEmpty {
                    Label(analysis.planComparison, systemImage: "calendar")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Card(title: "What went well") {
                ForEach(Array(analysis.highlights.enumerated()), id: \.offset) { _, item in
                    Label(item, systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .symbolRenderingMode(.multicolor)
                }
            }
            Card(title: "Do differently") {
                ForEach(Array(analysis.improvements.enumerated()), id: \.offset) { _, item in
                    Label(item, systemImage: "arrow.up.right.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.primary, .orange)
                }
            }
            Card(title: "Recovery") {
                Text(analysis.recovery).font(.subheadline)
            }
            Card(title: "Next session") {
                Text(analysis.nextSession).font(.subheadline)
            }
        }
    }
}
