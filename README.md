# Stride

Stride is an iPhone and iPad training coach that runs on your device. It reads training, sleep and recovery data from Apple Health, computes training metrics, and uses Apple Intelligence to review your workouts and plan your week.

It works with any watch that syncs to Apple Health and is built around Garmin Connect's sync. Stride has no server and needs no account or API key for its core features.

## Features

- **Weekly analysis and 7-day plan.** The on-device model writes the assessment and plan. Code then checks the plan against your settings, recent load, training phase, goal date, free time and logged injuries.
- **Workout reviews.** Each run or ride gets a coach review with splits, zones and effort. Strength, core, climbing, yoga and mobility sessions get their own kind of review.
- **Daily readiness.** Stride compares this morning's resting heart rate, HRV, sleep and load with your baselines, and suggests a lighter session when they're down.
- **Coach chat.** Ask about your training, get race forecasts, change planned days or schedule a session.
- **Your own plan.** Days you plan yourself always win over what the model writes.
- **Pain and illness log.** Logged issues limit what the plan can ask of you on the days they affect.
- **Training times.** Suggestions based on your calendar, the forecast, daylight and when you usually train.
- **Progress.** XP and levels per skill, records and achievements over up to 10 years of history.
- **Strength log (optional).** Reads sets and weights from [Hevy](https://www.hevy.com) with a Hevy Pro API key.
- **Playlists.** Builds a playlist for today's session from your own music library.
- **Notifications.** Morning readiness, new workout reviews and session reminders, even while the app is closed.

## Requirements

- Xcode 27
- iOS or iPadOS 27 or later
- A device with Apple Intelligence for the AI features
- [uv](https://docs.astral.sh/uv/) for the Simulator tooling

Foundation Models reports itself as available in the Simulator, but every generation fails there. To see AI output, use a real device or the model evals on a Mac with Apple Intelligence.

## Getting started

1. Open `Stride.xcodeproj` in Xcode.
2. Under **Signing & Capabilities**, select your own team. If you aren't the original author, also change the bundle ID (`com.afritzsch.stride`), since bundle IDs are unique to a team.
3. Build and run on your device, then grant access to Apple Health.

A free Personal Team is enough. Apple's free provisioning profiles expire after 7 days, so you'll need to reinstall the app from Xcode after that.

To look around without any health data, launch with demo data:

```sh
uv run --quiet tools/stride-mcp/server.py cli build
uv run --quiet tools/stride-mcp/server.py cli launch --demo
uv run --quiet tools/stride-mcp/server.py cli screenshot /tmp/shot.png
```

These commands use a dedicated simulator named "Stride Test", which is created on first use.

## Testing

The project has no XCTest target and no linter. Changes are verified with a macOS harness for the pure logic and by driving the app in the Simulator.

```sh
tools/eval/run.sh                # offline checks: plans, prompts, readiness, notifications and more
tools/eval/run.sh model [filter] # also runs the on-device model (needs Apple Intelligence on this Mac)
```

To inspect what the app computed for a screen:

```sh
uv run --quiet tools/stride-mcp/server.py cli launch --demo --route workout:latest-run --scroll-to splits
uv run --quiet tools/stride-mcp/server.py cli state detail
```

The same tools are available to coding agents as the `stride-simulator` MCP server, configured in `.mcp.json`. [CLAUDE.md](CLAUDE.md) lists every route and command and describes the architecture in detail.

## Project layout

| Path | Contents |
| --- | --- |
| `Stride/Models` | Data types |
| `Stride/Services` | HealthKit, Apple Intelligence, calendar, weather and Hevy, plus metrics, prompts, plan checks and demo data |
| `Stride/Views` | SwiftUI screens |
| `Stride/AppModel*.swift` | App state, persistence and model calls |
| `tools/eval` | macOS harness for checks and model evals |
| `tools/stride-mcp` | Simulator CLI and MCP server |
| `scripts` | App icon renderer |

## Privacy

AI runs on the device, and your health data isn't sent to a server. Stride only uses the network for optional features: it fetches the forecast from [Open-Meteo](https://open-meteo.com) for your location, or from WeatherKit in builds that include it, and reads your workouts from Hevy if you add an API key.

## Limitations

- Garmin doesn't share Body Battery, Training Readiness, stress or, usually, running dynamics with Apple Health, so Stride can't use them.
- Garmin often writes sparse or coarse samples. When the data is too coarse for splits or cadence, Stride leaves them out and says so rather than estimating.
- Private Cloud Compute and WeatherKit need entitlements that a free Personal Team can't get, so both are compiled out by default.
