#!/bin/sh
# Compiles the app's pure logic (models, metrics, prompt builders, plan checks, demo data) with the
# harness in this folder into a macOS binary and runs it.
#
#   tools/eval/run.sh                  offline checks of plan adherence, plan checks, prompts and time suggestions
#   tools/eval/run.sh model            also runs the on-device model on demo scenarios (needs Apple Intelligence)
#   tools/eval/run.sh prompt [compact] prints the weekly prompt for the demo data
#   tools/eval/run.sh seed <dir>       writes saved analyses, a review and today's adjustment in the app's format
set -e
cd "$(dirname "$0")/../.."
out=build/eval
mkdir -p "$out"
xcrun swiftc -target "$(uname -m)-apple-macos27.0" -default-isolation MainActor -O \
    Stride/Models/*.swift \
    Stride/Services/TrainingMetrics.swift Stride/Services/PromptBuilder.swift Stride/Services/RunPromptBuilder.swift \
    Stride/Services/DemoData.swift Stride/Services/HealthKitService.swift Stride/Services/PlanAdherence.swift Stride/Services/PlanCheck.swift Stride/Services/Readiness.swift Stride/Services/RaceForecast.swift Stride/Services/AppleAnalyzer.swift \
    Stride/Services/SessionScheduler.swift Stride/Services/OpenMeteo.swift Stride/Services/DemoSchedule.swift Stride/Services/DemoStrength.swift Stride/Services/HevyClient.swift \
    tools/eval/*.swift \
    -o "$out/eval"
"$out/eval" "$@"
