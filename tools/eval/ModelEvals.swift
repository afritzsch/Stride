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
    if filter == nil || "steps".contains(filter!) {
        await evalWeeklyInSteps(Scenario.demoWithHistory())
    }
    if filter == nil || "review".contains(filter!) {
        await evalRunReview(Scenario.demoWithHistory())
        await evalStrengthReview(Scenario.demoWithHistory())
    }
    if filter == nil || "adjust".contains(filter!) {
        await evalAdjustment(Scenario.demoWithHistory())
    }
    if filter == nil || "chat".contains(filter!) {
        await evalChat(Scenario.demoWithHistory())
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
        let model = SystemLanguageModel.default
        let outputTokens = try? await model.tokenCount(for: result.report.generatedContent.jsonString)
        let instructionTokens = try? await model.tokenCount(for: PromptBuilder.instructions)
        let schemaTokens = try? await model.tokenCount(for: schema)
        print("  output \(outputTokens ?? -1) tokens; instructions \(instructionTokens ?? -1), schema \(schemaTokens ?? -1)")
        print("  headline: \(report.headline) [\(report.trainingStatus.rawValue)]")
        let labels = scenario.planLabels
        let context = PlanContext(metrics: scenario.metrics, profile: scenario.profile, planStart: scenario.planStart, calendar: scenario.calendar)
        let raw = PlanCheck.problems(PlanCheck.normalized(report.weekPlan, labels: labels), labels: labels, profile: scenario.profile, context: context)
        let labelsRight = report.weekPlan.map(\.day) == labels
        let outcome = await PlanRepair.run(&report, labels: labels, profile: scenario.profile, context: context, log: { print("  \($0)") }) { instructions, prompt in
            try await AppleAnalyzer(allowPrivateCloud: false).analyze(WeekPlan.self, instructions: instructions, fullPrompt: prompt, compactPrompt: prompt, options: AppleAnalyzer.precise).report
        }
        // Problems the model left before any fixes: the number to watch across prompt changes and iOS updates.
        print("  labels as asked: \(labelsRight); problems as generated: \(raw.count), fixed in code: \(outcome.changes.count) changes, left: \(outcome.problems.count)")
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

/// The iPhone's on-device window is 4096 tokens (a Mac has 8192), too small for the brief plus the whole report, so
/// the app writes the assessment and the plan in two requests. A Mac never takes that path, so run it here.
private func evalWeeklyInSteps(_ scenario: Scenario) async {
    section("Weekly analysis in two steps (iPhone window)")
    let model = SystemLanguageModel.default
    let phoneWindow = 4096
    let analyzer = AppleAnalyzer(allowPrivateCloud: false)
    func report(_ name: String, instructions: String, prompt: String, schema: GenerationSchema, output: GeneratedContent) async {
        let input = await tokens(instructions, prompt, schema) ?? -1
        let out = (try? await model.tokenCount(for: output.jsonString)) ?? -1
        print("  \(name): \(input) in + \(out) out = \(input + out) of \(phoneWindow)")
        check(input + out < phoneWindow, "\(scenario.name): \(name) fits the iPhone window")
    }
    do {
        let assessmentPrompt = scenario.weeklyPrompt(compact: true, part: .assessment)
        let assessmentInstructions = PromptBuilder.instructions(for: .assessment)
        let assessment = try await analyzer.analyze(
            AnalysisAssessment.self, instructions: assessmentInstructions, fullPrompt: assessmentPrompt, compactPrompt: assessmentPrompt
        ).report
        await report("assessment", instructions: assessmentInstructions, prompt: assessmentPrompt, schema: AnalysisAssessment.generationSchema, output: assessment.generatedContent)
        print("  headline: \(assessment.headline) [\(assessment.trainingStatus.rawValue)]")

        let part = PromptBuilder.Part.plan(assessment: "\(assessment.headline) \(assessment.assessment)")
        let planPrompt = scenario.weeklyPrompt(compact: true, part: part)
        let planInstructions = PromptBuilder.instructions(for: part)
        let plan = try await analyzer.analyze(
            WeekPlan.self, instructions: planInstructions, fullPrompt: planPrompt, compactPrompt: planPrompt, options: AppleAnalyzer.precise
        ).report
        await report("plan", instructions: planInstructions, prompt: planPrompt, schema: WeekPlan.generationSchema, output: plan.generatedContent)
        for day in plan.days {
            print("    \(day.day) | \(day.sport) | \(day.intensity.rawValue) | \(day.session) | \(day.durationMinutes) min | Z\(day.targetZone)")
        }
        check(plan.days.map(\.day) == scenario.planLabels, "\(scenario.name): two-step plan has the 7 labels in order")
    } catch {
        check(false, "\(scenario.name), two steps: \(error)")
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
        // A dash standing alone, as the brief writes a missing value; ranges like "Z4–Z5" are fine.
        check(text.range(of: #"(^|\s)–($|[\s.,;])"#, options: .regularExpression) == nil, "doesn't echo missing-value dashes")
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
    print("  tokens: \(await tokens(instructions, prompt(false), StrengthReview.generationSchema) ?? -1)")
    do {
        let review = try await AppleAnalyzer(allowPrivateCloud: false).analyze(
            StrengthReview.self, instructions: instructions, fullPrompt: prompt(false), compactPrompt: prompt(true)
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
            DayAdjustment.self, instructions: DayAdjustment.instructions, fullPrompt: prompt, compactPrompt: prompt, options: AppleAnalyzer.precise
        ).report
        let clamped = raw.clamped(to: planned)
        print("  readiness \(readiness.level): \(raw.session.briefDescription) [\(raw.session.sport), \(raw.session.intensity.rawValue), \(raw.session.durationMinutes) min, Z\(raw.session.targetZone)] — \(raw.reason)")
        // Often a rest day with minutes left on it; `clamped(to:)` enforces the fields, so this is measured, not required.
        print("  kept to the rules without clamping: \(raw.session == clamped.session)")
        check(clamped.session.intensity != .hard, "a hard session gets lighter on a low-readiness day")
    } catch {
        check(false, "adjustment: \(error)")
    }
}
