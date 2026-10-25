# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Stride is a SwiftUI iOS app (iPhone/iPad, iOS 27+, Xcode 27) that reads training, sleep and recovery data from Apple Health (any watch that syncs there; built around Garmin Connect's sync), computes training metrics, and asks an AI engine for a weekly analysis + 7-day plan and for per-workout coach reviews. Engines: Claude (Messages API with the user's own key) or Apple Intelligence (Foundation Models). Bundle ID `com.afritzsch.stride`, signed with a free Personal Team.

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

The same tools are exposed as the `stride-simulator` MCP server via `.mcp.json`. It uses a dedicated simulator named "Stride Test" (created on first use). Routes: `dashboard | coach | plan | settings | workouts | workout:<latest|latest-run|index|uuid>`; `--engine claude|onDevice`; `--analyze` runs the analysis for the opened workout. The app side of these hooks is `Stride/AppModel+Debug.swift` (debug builds only).

Pure logic (models, metrics, prompt builders, demo data) has no UIKit/HealthKit dependency and can be compiled into a quick macOS harness with `xcrun swiftc -target arm64-apple-macos27.0` plus a `main.swift`. The view, HealthKit and analyzer files can't.

Regenerate the app icon: `xcrun swift scripts/render-app-icon.swift Stride/Assets.xcassets/AppIcon.appiconset`.

## Architecture

**Data flow.** `HealthKitService` → `HealthSnapshot` (8 weeks of daily metrics, sleep nights, workout summaries) → `MetricsReport` (Banister TRIMP load per workout, acute:chronic ratio, monotony, sleep regularity, weekly rollups) → `PromptBuilder` → analyzer → `AnalysisReport`. Per workout: `RawWorkoutData` (raw samples) → `WorkoutDetail.build` → `RunPromptBuilder` → `RunAnalysis`. `AppModel` (`@Observable`, injected via `.environment`) owns state, persistence and engine dispatch (`generate(_:...)`).

**Three interchangeable data sources** feed the same pipeline: HealthKit, `DemoData` (seeded synthetic data), and a `HealthFixture` JSON (an export of real data, replayed in debug builds from `Documents/fixture.json`). All workout processing goes through `WorkoutDetail.build(summary:raw:)` so that demo data and fixtures exercise the real code. Users create fixtures from Settings → "Export data for debugging". Fixture dates are ISO 8601 (`HealthFixture.encoder()/decoder()`).

**Data-quality rules live in `WorkoutDetail.build`.** Garmin often writes sparse heart rate and distance/steps in coarse chunks that overlap the workout boundaries. Samples are filtered to the workout's own source and clipped/prorated to the workout window. Splits are only produced when distance samples are ≤120 s apart and sum within 15% of the workout distance; cadence only from fine-grained steps. Otherwise a `dataNotes` entry is added; notes are shown in the UI and passed to the AI. Don't derive numbers from coarse data.

**One result type per analysis, two engines.** `AnalysisReport` and `RunAnalysis` are both `@Generable` (Apple guided generation) and `Codable` (Claude JSON), and conform to `StructuredOutput`, which also requires a hand-written `jsonSchema` for Claude's `output_config.format`. When changing these structs, update `jsonSchema` to match the Codable keys/enum raw values. Generation order follows property declaration order.

**Engines (`Services/Analyzers.swift`).**
- `ClaudeAnalyzer`: raw `URLSession` to `/v1/messages`, model `claude-opus-5-5`, header `anthropic-version: 2026-10-21`, `output_config: {effort: "high", format: json_schema}`, and server-side refusal fallbacks (`anthropic-beta: server-side-fallback-2026-07-01`, `fallbacks: "default"`). Do not send `temperature`/`top_p`/`top_k` (rejected on this API version). Key is stored in the Keychain.
- `AppleAnalyzer`: on-device `SystemLanguageModel` (small context window, so `PromptBuilder` has a `compact` mode and the analyzer token-counts to decide full vs compact, retrying smaller on `contextSizeExceeded`). Private Cloud Compute support exists but is compiled out (see gotchas).

`AIEngine.apple` has raw value `"onDevice"` for backward compatibility with saved settings/analyses; keep it.

## Gotchas

- **Private Cloud Compute:** constructing `PrivateCloudComputeLanguageModel` traps unless the app has the `com.apple.developer.private-cloud-compute` entitlement, which the Personal Team can't get (provisioning rejects it). It's gated by the `PRIVATE_CLOUD_COMPUTE` compilation condition (`AppleAnalyzer.isPrivateCloudInBuild`); never create the model outside that gate.
- **Foundation Models in the Simulator** reports "available" but every generation fails (`SensitiveContentAnalysisML error 15`: guardrail backend missing). AI output can only be tested on a device, or with a Claude key.
- **Simulator builds must be code-signed** (don't add `CODE_SIGNING_ALLOWED=NO`), otherwise there are no HealthKit entitlements and HealthKit calls hang.
- **Launch arguments override UserDefaults as strings** (`-useDemoData YES`): read bools with `bool(forKey:)`, not `object(forKey:) as? Bool`.
- **HealthKit never reveals whether read access was granted**, only whether the prompt was shown (`statusForAuthorizationRequest`). Adding a read type re-prompts the user.
- **Garmin doesn't share** Body Battery, Training Readiness, stress, or usually running dynamics (power, stride, GCT) with Apple Health. Some workouts only carry legacy totals, read via `value(forKey: "totalDistance")` to avoid deprecation warnings.
- **Build settings:** default actor isolation is `MainActor` with approachable concurrency, Swift 5 language mode, and `MemberImportVisibility`. Mark pure data types and services `nonisolated` (otherwise Codable/Generable conformances become main-actor-isolated). Import the module that defines a member you use.
- **The project uses file-system-synchronized groups:** new files under `Stride/` are picked up automatically, so don't hand-edit `project.pbxproj` to add files. Info.plist is generated (`INFOPLIST_KEY_*` build settings); entitlements are in `Stride/Stride.entitlements`.
