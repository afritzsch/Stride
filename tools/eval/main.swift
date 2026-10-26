import Foundation

// Entry point of the macOS harness (see run.sh). Offline checks always run; `model` adds on-device runs.

nonisolated(unsafe) var failures = 0

func check(_ condition: Bool, _ message: @autoclosure () -> String) {
    if !condition {
        failures += 1
        print("  ✗ \(message())")
    }
}

func section(_ title: String) {
    print("\n== \(title)")
}

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "prompt":
    let scenario = Scenario.demoWithHistory()
    print(scenario.weeklyPrompt(compact: arguments.contains("compact")))
case "seed":
    // Writes saved analyses and reviews in the app's format, e.g. into the Simulator app's Application Support.
    guard let directory = arguments.dropFirst().first else { print("usage: seed <directory>"); exit(2) }
    try Scenario.demoWithHistory().seed(into: URL(filePath: directory))
    exit(0)
case "model":
    await runOfflineChecks()
    await runModelEvals(filter: arguments.dropFirst().first)
default:
    await runOfflineChecks()
}

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
