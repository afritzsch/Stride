# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Stride is a SwiftUI iOS app (iPhone/iPad, iOS 27+, Xcode 27) that reads training, sleep and recovery data from Apple Health (any watch that syncs there; built around Garmin Connect's sync), computes training metrics, and uses Apple Intelligence (Foundation Models, on-device) for a weekly analysis + 7-day plan, per-workout coach reviews, a daily readiness adjustment and a coach chat. The athlete can also plan days themselves, and the app suggests training times from the calendar (EventKit) and the forecast (Open-Meteo, or WeatherKit in builds that have it). There is no server or API key; Claude support was removed. Bundle ID `com.afritzsch.stride`, signed with a free Personal Team.

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

The same tools are exposed as the `stride-simulator` MCP server via `.mcp.json`. It uses a dedicated simulator named "Stride Test" (created on first use). Routes: `dashboard | progress | coach | chat | plan | settings | workouts | strength | workout:<latest|latest-run|latest-strength|index|uuid> | skill:<name> | metric:<name>` (`--scroll-to adherence` and `--sheet week|edit:<n>|time:<n>` on `plan`; the `chat` route also dumps the chat tools' output to `state coachTools`); `--analyze` runs the analysis for the opened workout. The app side of these hooks is `Stride/AppModel+Debug.swift` (debug builds only). `Documents/debug-state.json` is written in the Simulator only; on a device pass `-debugState YES` (a debug build is what runs on the phone, and the dump holds health data).

Pure logic (models, metrics, prompt builders, plan checks, readiness, demo data) has no UIKit/HealthKit dependency and is compiled into the macOS harness in `tools/eval`:

```sh
tools/eval/run.sh                  # offline checks: plan adherence, prompts, plan check/repair, readiness, time suggestions
tools/eval/run.sh model [filter]   # also runs the on-device model on scenarios (needs Apple Intelligence on this Mac)
tools/eval/run.sh prompt [compact] # print the weekly prompt for the demo data with history
tools/eval/run.sh seed <dir>       # write saved analyses, a review and today's adjustment in the app's format
```

To see history-dependent UI in the Simulator without a model, seed the app container: `tools/eval/run.sh seed "$(xcrun simctl get_app_container <udid> com.afritzsch.stride data)/Library/Application Support"` (today's adjustment goes in UserDefaults key `todayAdjustment`). The view and HealthKit files can't be compiled into the harness.

Regenerate the app icon: `xcrun swift scripts/render-app-icon.swift Stride/Assets.xcassets/AppIcon.appiconset`.

## Architecture

**Data flow.** `HealthKitService` → `HealthSnapshot` (8 weeks of daily metrics, sleep nights, workout summaries) → `MetricsReport` (Banister TRIMP load per workout, acute:chronic ratio, monotony, sleep regularity, weekly rollups) → `PromptBuilder` → analyzer → `AnalysisReport`. Per workout: `RawWorkoutData` (raw samples) → `WorkoutDetail.build` → `RunPromptBuilder` → `RunAnalysis`. `AppModel` (`@Observable`, injected via `.environment`) owns state, persistence and model calls (`generate(_:...)`).

**Long-term progress.** The Progress tab uses `ProgressReport` (XP and levels per `Skill`, week/month/year buckets for every `ProgressMetric`, records, achievements) over `snapshot.prepending(archive)`. The archive is up to 10 years of history from `HealthKitService.fetchHistory()`, cached in `history-archive.json` and reread at most weekly (or on pull to refresh); demo mode uses `DemoData.archive`, fixtures have none. All XP numbers live in `XPRules`; `Skill.rule` (shown in the UI) is built from them, so change them there. UserDefaults keys are in `DefaultsKey` (`Persistence.swift`); sport names are `Sport.*`.

**Three interchangeable data sources** feed the same pipeline: HealthKit, `DemoData` (seeded synthetic data), and a `HealthFixture` JSON (an export of real data, replayed in debug builds from `Documents/fixture.json`). All workout processing goes through `WorkoutDetail.build(summary:raw:)` so that demo data and fixtures exercise the real code. Users create fixtures from Settings → "Export data for debugging". Fixture dates are ISO 8601 (`HealthFixture.encoder()/decoder()`).

**Data-quality rules live in `WorkoutDetail.build`.** Garmin often writes sparse heart rate and distance/steps in coarse chunks that overlap the workout boundaries. Samples are filtered to the workout's own source and clipped/prorated to the workout window. Splits are only produced when distance samples are ≤120 s apart and sum within 15% of the workout distance; cadence only from fine-grained steps. Otherwise a `dataNotes` entry is added; notes are shown in the UI and passed to the AI. Don't derive numbers from coarse data.

**The coach remembers.** `PromptBuilder` takes `history` and `reviews` and adds LAST PLAN VS ACTUAL (`PlanAdherence`: each planned day compared with recorded workouts by sport, minutes and average-HR zone), SESSION FEEDBACK (review verdicts and the athlete's notes) and a COACH LOG (one earlier headline per week). Compact mode keeps these short for the on-device context window. Plan lookups by date go through `[SavedAnalysis].plannedDay(on:)` (by position from `planStartDate`, newest plan wins).

**Plans are checked in code.** `PlannedDay` has `sport` (one of `PlannedDay.sports`, matching HealthKit names) and `targetZone` (0–5); old saved plans decode with `""`/0. After a weekly analysis, `PlanRepair.run` normalizes labels and rest days, checks `PlanCheck.problems` (training days, weekly hours, back-to-back hard days, zero-minute sessions) and asks the model once for a fixed `WeekPlan`, kept only if it's 7 days with fewer problems. Remaining problems become a notice.

**The athlete's own plan.** Days the athlete plans or edits (Plan tab, "Plan week") are `AthletePlanDay`s in `athlete-plan.json`. `TrainingPlan` (analyses + athlete days) answers every plan lookup (`AppModel.plannedSession(on:)`, `PlanAdherence`); athlete days always win. The weekly prompt lists them under THE ATHLETE'S OWN PLAN, and `PlanRepair.run(pinned:)` puts them back over whatever the model wrote. `updatePlannedDay` (readiness adjustment, chat) changes the athlete day if there is one, else the covering analysis, else creates an athlete day.

**Training times.** `SessionScheduler` (pure) finds free gaps around `BusyInterval`s within the settings' window and buffer, and ranks 15-minute candidates by rain, "feels like" temperature per sport, wind, UV, daylight (`SunTimes`), the athlete's usual start hours (`StartHabits`) and late hard sessions; indoor sports ignore weather. `ScheduleModel` (owned by `AppModel` like `chat`) holds `ScheduleSettings`, reads the calendar through `CalendarService`, fetches the forecast through `WeatherClient` (refetched hourly or when source/location change), and computes `DaySchedule`s on demand. Events Stride adds carry a `stride://session/<yyyy-MM-dd>` URL, so they count as that day's scheduled session instead of busy time; plan edits move or remove them (`sessionChanged(on:)`). Demo data uses `DemoSchedule` (fake calendar and forecast) and keeps added sessions in memory. The weekly prompt gets a FREE TIME section (`availabilityLine`) when suggestions are on, and the chat has `freeTimes`, `weather` and `scheduleSession` tools.

**Apple Intelligence features.** Analyses and reviews stream (`AppleAnalyzer` `onPartial` → `AppModel.analysisPreview` / `runPreviews`). `Readiness` flags this morning's resting HR, HRV, sleep and load against baselines; when it's down and a session is planned, the Dashboard's Today card gets a `DayAdjustment` (automatic once a day on Apple, applied only when the athlete accepts; `clamped(to:)` keeps it from getting harder or longer). `CoachChat` is a `LanguageModelSession` with tools (`recentDays`, `listWorkouts`, `workoutDetail`, `trends`, `raceForecast`, `getPlan`, `changePlanDay`, `freeTimes`, `weather`, `scheduleSession`) backed by `CoachToolbox`; race times are computed in code (`RaceForecast`, Riegel plus a capped monthly gain) because the model can't do the arithmetic; it restarts the session on `contextSizeExceeded`. Workout reviews depend on `WorkoutSummary.kind`: strength, core, climbing, yoga and mobility sessions get `RunPromptBuilder.instructions(for: .strength)`, no zones or measured effort in the prompt, and a nil `RunAnalysis.effort` (heart rate says little about lifting, and Health gets no sets or weights). `reviewNewWorkouts()` reviews unreviewed workouts from the last 2 days after each refresh (each tried once, setting "Review new workouts automatically").

**Strength log (Hevy).** Apple Health gets only time and heart rate for gym sessions. `StrengthModel` (owned by `AppModel` like `schedule`) reads the athlete's Hevy workouts through `HevyClient` (Hevy Pro API key in the Keychain, `HevyKeychain`): a year of history on first sync, then `/v1/workouts/events` since the last sync, cached in `hevy-workouts.json`. `StrengthLog` (pure) matches a logged `StrengthSession` to a watch workout by time overlap (20 min tolerance), finds personal bests (Epley est. 1RM, sets ≤12 reps) and writes the LOGGED EXERCISES prompt section that `RunPromptBuilder` adds to strength reviews; `StrengthReport` is the 8-week overview (`StrengthView`, route `strength`). Without Hevy every strength screen falls back to watch data (`sessions == nil`). Demo data comes with a made-up log (`DemoStrength`); launch with `-demoHevy NO` to see the fallback.

**Guided generation.** `AnalysisReport`, `RunAnalysis`, `WeekPlan` and `DayAdjustment` are `@Generable` (and `Codable` where they're saved). Generation order follows property declaration order. Saved JSON must keep decoding after model changes: add custom `init(from:)` with defaults for new fields (see `PlannedDay`, `RunAnalysis`, `SavedAnalysis`).

**`AppleAnalyzer` (`Services/AppleAnalyzer.swift`).** On-device `SystemLanguageModel` with a small context window, so `PromptBuilder` has a `compact` mode and the analyzer token-counts to decide full vs compact, retrying smaller on `contextSizeExceeded`. It streams (`onPartial` previews) and can `prewarm`. Private Cloud Compute support exists but is compiled out (see gotchas).

Analyses saved by older versions carry `"engine": "claude"|"onDevice"` instead of `modelName`; `SavedAnalysis` decodes both. On first launch `AppModel` deletes the old Anthropic key from the Keychain (`LegacyKeychain`) and the `engine` default.

## Gotchas

- **Private Cloud Compute:** constructing `PrivateCloudComputeLanguageModel` traps unless the app has the `com.apple.developer.private-cloud-compute` entitlement, which the Personal Team can't get (provisioning rejects it). It's gated by the `PRIVATE_CLOUD_COMPUTE` compilation condition (`AppleAnalyzer.isPrivateCloudInBuild`); never create the model outside that gate.
- **WeatherKit** needs the `com.apple.developer.weatherkit` entitlement (paid accounts only). It's gated by the `WEATHERKIT` compilation condition (`WeatherClient.isAppleWeatherInBuild`); to enable it, add the condition, the entitlement in `Stride.entitlements`, and WeatherKit for the App ID in the developer portal. Apple requires its Weather mark and legal link next to WeatherKit data (`ScheduleModel.appleAttribution`); Open-Meteo asks for a credit link. Without the flag a saved `.apple` setting falls back to Open-Meteo.
- **Calendar and location** need `NSCalendarsFullAccessUsageDescription` / `NSLocationWhenInUseUsageDescription` (`INFOPLIST_KEY_*` build settings). Busy time needs full access; all-day, free, cancelled and declined events don't block time.
- **Foundation Models in the Simulator** reports "available" but every generation fails (`SensitiveContentAnalysisML error 15`: guardrail backend missing). AI output can only be tested on a device, or with `tools/eval/run.sh model` on a Mac with Apple Intelligence. While streaming, this and some other failures arrive as a bridged `NSError` (domain `FoundationModels…`), not as `LanguageModelError`.
- **Model availability on a device** (`SystemLanguageModel.availability`) isn't observable and changes while the app runs; `AppModel.onDeviceBlocker` holds a copy that `refreshModelAvailability()` updates (on activation, every 5 s while blocked, and before each request). `modelNotReady` also happens when the iPhone and Siri languages don't match. To see what the device really reports, launch a debug build with `-probeModel YES` (`xcrun devicectl device process launch --device <id> com.afritzsch.stride -- -probeModel YES`) and read `Documents/model-probe.json` with `devicectl device copy from`.
- **`simctl spawn <udid> defaults read`** doesn't see the app's own preferences; read `<data container>/Library/Preferences/com.afritzsch.stride.plist` instead.
- **Simulator builds must be code-signed** (don't add `CODE_SIGNING_ALLOWED=NO`), otherwise there are no HealthKit entitlements and HealthKit calls hang.
- **Launch arguments override UserDefaults as strings** (`-useDemoData YES`): read bools with `bool(forKey:)`, not `object(forKey:) as? Bool`.
- **HealthKit never reveals whether read access was granted**, only whether the prompt was shown (`statusForAuthorizationRequest`). Adding a read type re-prompts the user.
- **Garmin doesn't share** Body Battery, Training Readiness, stress, or usually running dynamics (power, stride, GCT) with Apple Health. Some workouts only carry legacy totals, read via `value(forKey: "totalDistance")` to avoid deprecation warnings.
- **Build settings:** default actor isolation is `MainActor` with approachable concurrency, Swift 5 language mode, and `MemberImportVisibility`. Mark pure data types and services `nonisolated` (otherwise Codable/Generable conformances become main-actor-isolated). Import the module that defines a member you use.
- **The project uses file-system-synchronized groups:** new files under `Stride/` are picked up automatically, so don't hand-edit `project.pbxproj` to add files. Info.plist is generated (`INFOPLIST_KEY_*` build settings); entitlements are in `Stride/Stride.entitlements`.
