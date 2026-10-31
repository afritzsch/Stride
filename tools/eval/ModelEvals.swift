import Foundation
import FoundationModels

/// Runs the on-device model on the scenarios and reports how its output holds up against the rules.
/// Model output varies between runs, so these print measurements; only hard rules count as failures.
func runModelEvals(filter: String?) async {
    section("On-device model")
    let model = SystemLanguageModel.default
    guard case .available = model.availability else {
        print("  skipped: \(model.availability). Turn on Apple Intelligence (and let the model download) to run these.")
        return
    }
    print("  context window: \(model.contextSize) tokens")

    for scenario in Scenario.all() where filter == nil || scenario.name.localizedCaseInsensitiveContains(filter!) {
        await evalWeekly(scenario)
    }
    if filter == nil || "review".contains(filter!) {
        await evalRunReview(Scenario.demoWithHistory())
        await evalStrengthReview(Scenario.demoWithHistory())
    }
    if filter == nil || "adjust".contains(filter!) {
        await evalAdjustment(Scenario.demoWithHistory())
    }
}

private func tokens(_ instructions: String, _ prompt: String, _ schema: GenerationSchema) async -> Int? {
    let model = SystemLanguageModel.default
    guard let a = try? await model.tokenCount(for: instructions),
          let b = try? await model.tokenCount(for: prompt),
          let c = try? await model.tokenCount(for: schema) else { return nil }
    return a + b + c
}

/// Numbers in the output that don't appear in the prompt: a rough measure of invented data.
private func unsupportedNumbers(in text: String, prompt: String) -> [String] {
    let pattern = #/\d+(?:[.,]\d+)?/#
    let known = Set(prompt.matches(of: pattern).map { String($0.output).replacingOccurrences(of: ",", with: ".") })
    return text.matches(of: pattern).map { String($0.output).replacingOccurrences(of: ",", with: ".") }
        .filter { (Double($0) ?? 0) >= 10 && !known.contains($0) }
}

private func evalWeekly(_ scenario: Scenario) async {
    section("Weekly analysis: \(scenario.name)")
    let full = scenario.weeklyPrompt(compact: false)
    let compact = scenario.weeklyPrompt(compact: true)
    let schema = AnalysisReport.generationSchema
    let fullTokens = await tokens(PromptBuilder.instructions, full, schema)
    let compactTokens = await tokens(PromptBuilder.instructions, compact, schema)
    print("  tokens incl. instructions and schema: full \(fullTokens ?? -1), compact \(compactTokens ?? -1) of \(SystemLanguageModel.default.contextSize)")

    let start = Date.now
    do {
        let result = try await AppleAnalyzer(allowPrivateCloud: false).analyze(
            AnalysisReport.self, instructions: PromptBuilder.instructions, fullPrompt: full, compactPrompt: compact
        )
        var report = result.report
        print("  generated in \(Int(Date.now.timeIntervalSince(start))) s")
        print("  headline: \(report.headline) [\(report.trainingStatus.rawValue)]")
        let labels = scenario.planLabels
        let raw = PlanCheck.problems(PlanCheck.normalized(report.weekPlan, labels: labels), labels: labels, profile: scenario.profile)
        let labelsRight = report.weekPlan.map(\.day) == labels
        let left = await PlanRepair.run(&report, labels: labels, profile: scenario.profile, log: { print("  \($0)") }) { instructions, prompt in
            try await AppleAnalyzer(allowPrivateCloud: false).analyze(WeekPlan.self, instructions: instructions, fullPrompt: prompt, compactPrompt: prompt).report
        }
        print("  labels as asked: \(labelsRight); problems before repair: \(raw.count), after: \(left.count)")
        for day in report.weekPlan {
            print("    \(day.day) | \(day.sport) | \(day.intensity.rawValue) | \(day.session) | \(day.durationMinutes) min | Z\(day.targetZone)")
        }
        let text = ([report.headline, report.assessment, report.goalOutlook] + report.insights.map(\.detail) + report.recommendations.map { "\($0.action) \($0.rationale)" })
            .joined(separator: " ")
        let invented = unsupportedNumbers(in: text, prompt: full)
        print("  numbers not in the prompt: \(invented.isEmpty ? "none" : invented.joined(separator: ", "))")
        check(report.weekPlan.count == 7, "\(scenario.name): 7 plan days")
        if scenario.name.contains("no HRV") {
            check(!text.contains("HRV ") || text.localizedCaseInsensitiveContains("unavailable") || text.localizedCaseInsensitiveContains("missing") || text.localizedCaseInsensitiveContains("no hrv"),
                  "\(scenario.name): doesn't make up HRV values")
        }
    } catch {
        check(false, "\(scenario.name): \(error)")
    }
}

private func evalRunReview(_ scenario: Scenario) async {
    section("Run review")
    guard let run = scenario.snapshot.workouts.last(where: { $0.sport == "Running" }) else { return }
    let detail = DemoData.detail(for: run)
    func prompt(_ compact: Bool) -> String {
        RunPromptBuilder(
            detail: detail, snapshot: scenario.snapshot, metrics: scenario.metrics, profile: scenario.profile,
            plannedSession: scenario.history.plannedDay(on: run.start, calendar: scenario.calendar), note: "", compact: compact
        ).prompt
    }
    print("  tokens: \(await tokens(RunPromptBuilder.instructions(for: .endurance), prompt(false), RunAnalysis.generationSchema) ?? -1)")
    let start = Date.now
    do {
        let review = try await AppleAnalyzer(allowPrivateCloud: false).analyze(
            RunAnalysis.self, instructions: RunPromptBuilder.instructions(for: .endurance), fullPrompt: prompt(false), compactPrompt: prompt(true)
        ).report
        print("  generated in \(Int(Date.now.timeIntervalSince(start))) s: \(review.headline) [\(review.effort?.rawValue ?? "no effort")]")
        review.summary.forEach { print("    • \($0)") }
        print("  plan: \(review.planComparison)")
        let words = review.headline.split(separator: " ").count
        check(words <= 14, "headline is short (\(words) words)")
        let text = (review.summary + review.highlights + review.improvements + [review.recovery, review.nextSession]).joined(separator: " ")
        check(!text.contains("–"), "doesn't echo missing-value dashes")
        print("  numbers not in the prompt: \(unsupportedNumbers(in: text, prompt: prompt(false)))")
    } catch {
        check(false, "run review: \(error)")
    }
}

/// A gym session on a day with an easy run planned: the case that came out as "Recovery run missed easy-run goal".
private func evalStrengthReview(_ scenario: Scenario) async {
    section("Strength review")
    guard let gym = scenario.snapshot.workouts.last(where: { $0.sport == "Strength" }) else { return }
    let detail = DemoData.detail(for: gym)
    let easyRun = PlannedDay(
        day: scenario.label(0), sport: "Running", intensity: .easy, session: "Easy run",
        durationMinutes: 30, targetZone: 1, details: ""
    )
    func prompt(_ compact: Bool) -> String {
        RunPromptBuilder(
            detail: detail, snapshot: scenario.snapshot, metrics: scenario.metrics, profile: scenario.profile,
            plannedSession: easyRun, note: "", compact: compact
        ).prompt
    }
    let instructions = RunPromptBuilder.instructions(for: .strength)
    print("  tokens: \(await tokens(instructions, prompt(false), RunAnalysis.generationSchema) ?? -1)")
    do {
        let review = try await AppleAnalyzer(allowPrivateCloud: false).analyze(
            RunAnalysis.self, instructions: instructions, fullPrompt: prompt(false), compactPrompt: prompt(true)
        ).report
        print("  \(review.headline)")
        (review.summary + review.highlights + review.improvements).forEach { print("    • \($0)") }
        print("  plan: \(review.planComparison)")
        print("  next: \(review.nextSession)")
        let headline = review.headline.lowercased()
        let callsItARun = ["recovery run", "easy run", "missed"].contains(where: headline.contains)
            || (headline.contains("run") && !headline.contains("instead"))
        check(!callsItARun, "headline doesn't call it a run (\(review.headline))")
        let advice = (review.improvements + review.highlights).joined(separator: " ").lowercased()
        let runningWords = ["pace", "split", "tempo", "interval", "400"]
        check(!runningWords.contains(where: advice.contains), "no running advice in highlights or improvements")
        check(!advice.contains("too light") && !advice.contains("too low"), "doesn't call the session too light")
    } catch {
        check(false, "strength review: \(error)")
    }
}

private func evalAdjustment(_ scenario: Scenario) async {
    section("Today's adjustment")
    let readiness = Readiness(snapshot: scenario.snapshot, metrics: scenario.metrics, profile: scenario.profile, calendar: scenario.calendar)
    let planned = PlannedDay(
        day: scenario.label(0), sport: "Running", intensity: .hard, session: "Intervals 6×3 min",
        durationMinutes: 55, targetZone: 4, details: "3 min at Z4, 2 min jog"
    )
    let prompt = DayAdjustment.prompt(planned: planned, readiness: readiness, metrics: scenario.metrics, profile: scenario.profile)
    do {
        let raw = try await AppleAnalyzer(allowPrivateCloud: false).analyze(
            DayAdjustment.self, instructions: DayAdjustment.instructions, fullPrompt: prompt, compactPrompt: prompt
        ).report
        let clamped = raw.clamped(to: planned)
        print("  readiness \(readiness.level): \(raw.session.briefDescription) — \(raw.reason)")
        check(raw.session == clamped.session, "model kept to the rules without clamping (raw \(raw.session.briefDescription))")
        check(clamped.session.intensity != .hard, "a hard session gets lighter on a low-readiness day")
    } catch {
        check(false, "adjustment: \(error)")
    }
}
