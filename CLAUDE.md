# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Stride is a SwiftUI iOS app (iPhone/iPad, iOS 27+, Xcode 27) that reads training, sleep and recovery data from Apple Health (any watch that syncs there; built around Garmin Connect's sync), computes training metrics, and uses Apple Intelligence (Foundation Models, on-device) for a weekly analysis + 7-day plan, per-workout coach reviews, a daily readiness adjustment and a coach chat. There is no server or API key; Claude support was removed. Bundle ID `com.afritzsch.stride`, signed with a free Personal Team.

## Commands

There is no test target and no linter. Verify changes by building and by driving the app in the Simulator.

```sh
# Build for the Simulator (the stride-mcp tool wraps this; derived data in build/sim, gitignored)
uv run --quiet tools/stride-mcp/server.py cli build

# Launch on a screen with demo data and inspect what the app computed
uv run --quiet tools/stride-mcp/server.py cli launch --demo --route workout:latest-run --scroll-to splits
uv run --quiet tools/stride-mcp/server.py cli screenshot /tmp/shot.png
uv run --quiet tools/stride-mcp/server.py cli state detail      # splits, zones, data notes, exact AI prompt
uv run --quiet tools/stride-mcp/server.py cli state events      # recent errors/notices
uv run --quiet tools/stride-mcp/server.py cli logs --seconds 60

# Replay data instead of HealthKit: export demo data, make it sparse like Garmin, replay
uv run --quiet tools/stride-mcp/server.py cli export-fixture /tmp/demo.json
uv run --quiet tools/stride-mcp/server.py cli coarsen-fixture /tmp/demo.json /tmp/coarse.json
uv run --quiet tools/stride-mcp/server.py cli launch --fixture /tmp/coarse.json --route workout:latest-run
```

The same tools are exposed as the `stride-simulator` MCP server via `.mcp.json`. It uses a dedicated simulator named "Stride Test" (created on first use). Routes: `dashboard | coach | chat | plan | settings | workouts | workout:<latest|latest-run|index|uuid>` (`--scroll-to adherence` on `plan`; the `chat` route also dumps the chat tools' output to `state coachTools`); `--analyze` runs the analysis for the opened workout. The app side of these hooks is `Stride/AppModel+Debug.swift` (debug builds only).

Pure logic (models, metrics, prompt builders, plan checks, readiness, demo data) has no UIKit/HealthKit dependency and is compiled into the macOS harness in `tools/eval`:

```sh
tools/eval/run.sh                  # offline checks: plan adherence, prompts, plan check/repair, readiness
tools/eval/run.sh model [filter]   # also runs the on-device model on scenarios (needs Apple Intelligence on this Mac)
tools/eval/run.sh prompt [compact] # print the weekly prompt for the demo data with history
tools/eval/run.sh seed <dir>       # write saved analyses, a review and today's adjustment in the app's format
```

To see history-dependent UI in the Simulator without a model, seed the app container: `tools/eval/run.sh seed "$(xcrun simctl get_app_container <udid> com.afritzsch.stride data)/Library/Application Support"` (today's adjustment goes in UserDefaults key `todayAdjustment`). The view and HealthKit files can't be compiled into the harness.

Regenerate the app icon: `xcrun swift scripts/render-app-icon.swift Stride/Assets.xcassets/AppIcon.appiconset`.

## Architecture

**Data flow.** `HealthKitService` → `HealthSnapshot` (8 weeks of daily metrics, sleep nights, workout summaries) → `MetricsReport` (Banister TRIMP load per workout, acute:chronic ratio, monotony, sleep regularity, weekly rollups) → `PromptBuilder` → analyzer → `AnalysisReport`. Per workout: `RawWorkoutData` (raw samples) → `WorkoutDetail.build` → `RunPromptBuilder` → `RunAnalysis`. `AppModel` (`@Observable`, injected via `.environment`) owns state, persistence and model calls (`generate(_:...)`).

**Three interchangeable data sources** feed the same pipeline: HealthKit, `DemoData` (seeded synthetic data), and a `HealthFixture` JSON (an export of real data, replayed in debug builds from `Documents/fixture.json`). All workout processing goes through `WorkoutDetail.build(summary:raw:)` so that demo data and fixtures exercise the real code. Users create fixtures from Settings → "Export data for debugging". Fixture dates are ISO 8601 (`HealthFixture.encoder()/decoder()`).

**Data-quality rules live in `WorkoutDetail.build`.** Garmin often writes sparse heart rate and distance/steps in coarse chunks that overlap the workout boundaries. Samples are filtered to the workout's own source and clipped/prorated to the workout window. Splits are only produced when distance samples are ≤120 s apart and sum within 15% of the workout distance; cadence only from fine-grained steps. Otherwise a `dataNotes` entry is added; notes are shown in the UI and passed to the AI. Don't derive numbers from coarse data.

**The coach remembers.** `PromptBuilder` takes `history` and `reviews` and adds LAST PLAN VS ACTUAL (`PlanAdherence`: each planned day compared with recorded workouts by sport, minutes and average-HR zone), SESSION FEEDBACK (review verdicts and the athlete's notes) and a COACH LOG (one earlier headline per week). Compact mode keeps these short for the on-device context window. Plan lookups by date go through `[SavedAnalysis].plannedDay(on:)` (by position from `planStartDate`, newest plan wins).

**Plans are checked in code.** `PlannedDay` has `sport` (one of `PlannedDay.sports`, matching HealthKit names) and `targetZone` (0–5); old saved plans decode with `""`/0. After a weekly analysis, `PlanRepair.run` normalizes labels and rest days, checks `PlanCheck.problems` (training days, weekly hours, back-to-back hard days, zero-minute sessions) and asks the model once for a fixed `WeekPlan`, kept only if it's 7 days with fewer problems. Remaining problems become a notice.

**Apple Intelligence features.** Analyses and reviews stream (`AppleAnalyzer` `onPartial` → `AppModel.analysisPreview` / `runPreviews`). `Readiness` flags this morning's resting HR, HRV, sleep and load against baselines; when it's down and a session is planned, the Dashboard's Today card gets a `DayAdjustment` (automatic once a day on Apple, applied only when the athlete accepts; `clamped(to:)` keeps it from getting harder or longer). `CoachChat` is a `LanguageModelSession` with tools (`recentDays`, `listWorkouts`, `workoutDetail`, `getPlan`, `changePlanDay`) backed by `CoachToolbox`; it restarts the session on `contextSizeExceeded`. `reviewNewWorkouts()` reviews unreviewed workouts from the last 2 days after each refresh (each tried once, setting "Review new workouts automatically").

**Guided generation.** `AnalysisReport`, `RunAnalysis`, `WeekPlan` and `DayAdjustment` are `@Generable` (and `Codable` where they're saved). Generation order follows property declaration order. Saved JSON must keep decoding after model changes: add custom `init(from:)` with defaults for new fields (see `PlannedDay`, `RunAnalysis`, `SavedAnalysis`).

**`AppleAnalyzer` (`Services/AppleAnalyzer.swift`).** On-device `SystemLanguageModel` with a small context window, so `PromptBuilder` has a `compact` mode and the analyzer token-counts to decide full vs compact, retrying smaller on `contextSizeExceeded`. It streams (`onPartial` previews) and can `prewarm`. Private Cloud Compute support exists but is compiled out (see gotchas).

Analyses saved by older versions carry `"engine": "claude"|"onDevice"` instead of `modelName`; `SavedAnalysis` decodes both. On first launch `AppModel` deletes the old Anthropic key from the Keychain (`LegacyKeychain`) and the `engine` default.

## Gotchas

- **Private Cloud Compute:** constructing `PrivateCloudComputeLanguageModel` traps unless the app has the `com.apple.developer.private-cloud-compute` entitlement, which the Personal Team can't get (provisioning rejects it). It's gated by the `PRIVATE_CLOUD_COMPUTE` compilation condition (`AppleAnalyzer.isPrivateCloudInBuild`); never create the model outside that gate.
- **Foundation Models in the Simulator** reports "available" but every generation fails (`SensitiveContentAnalysisML error 15`: guardrail backend missing). AI output can only be tested on a device, or with `tools/eval/run.sh model` on a Mac with Apple Intelligence. While streaming, this and some other failures arrive as a bridged `NSError` (domain `FoundationModels…`), not as `LanguageModelError`.
- **`simctl spawn <udid> defaults read`** doesn't see the app's own preferences; read `<data container>/Library/Preferences/com.afritzsch.stride.plist` instead.
- **Simulator builds must be code-signed** (don't add `CODE_SIGNING_ALLOWED=NO`), otherwise there are no HealthKit entitlements and HealthKit calls hang.
- **Launch arguments override UserDefaults as strings** (`-useDemoData YES`): read bools with `bool(forKey:)`, not `object(forKey:) as? Bool`.
- **HealthKit never reveals whether read access was granted**, only whether the prompt was shown (`statusForAuthorizationRequest`). Adding a read type re-prompts the user.
- **Garmin doesn't share** Body Battery, Training Readiness, stress, or usually running dynamics (power, stride, GCT) with Apple Health. Some workouts only carry legacy totals, read via `value(forKey: "totalDistance")` to avoid deprecation warnings.
- **Build settings:** default actor isolation is `MainActor` with approachable concurrency, Swift 5 language mode, and `MemberImportVisibility`. Mark pure data types and services `nonisolated` (otherwise Codable/Generable conformances become main-actor-isolated). Import the module that defines a member you use.
- **The project uses file-system-synchronized groups:** new files under `Stride/` are picked up automatically, so don't hand-edit `project.pbxproj` to add files. Info.plist is generated (`INFOPLIST_KEY_*` build settings); entitlements are in `Stride/Stride.entitlements`.
