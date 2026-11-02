import Foundation

/// A planned day that the logged pain or illness doesn't allow, and how it would fit.
struct HealthConflict: Hashable {
    var date: Date
    var planned: PlannedDay
    var fixed: PlannedDay
    var limit: DayLimit
}

/// The athlete's pain and illness log, and the training block: what both mean for the plan.
extension AppModel {
    // MARK: - Health log

    var healthLog: HealthLog { HealthLog(issues: healthIssues) }

    /// Adds an issue, or replaces the one with the same ID.
    func saveHealthIssue(_ issue: HealthIssue) {
        if let index = healthIssues.firstIndex(where: { $0.id == issue.id }) {
            healthIssues[index] = issue
        } else {
            healthIssues.append(issue)
        }
        healthIssues.sort { $0.started < $1.started }
        healthLogChanged()
    }

    /// Today's severity for an ongoing issue.
    func checkIn(_ id: UUID, severity: HealthIssue.Severity) {
        guard let index = healthIssues.firstIndex(where: { $0.id == id }) else { return }
        healthIssues[index].checkIn(severity, on: .now)
        healthLogChanged()
    }

    /// Marks an issue as gone from today.
    func resolveHealthIssue(_ id: UUID) {
        guard let index = healthIssues.firstIndex(where: { $0.id == id }) else { return }
        healthIssues[index].resolvedOn = Calendar.current.startOfDay(for: .now)
        healthLogChanged()
    }

    func deleteHealthIssue(_ id: UUID) {
        healthIssues.removeAll { $0.id == id }
        healthLogChanged()
    }

    /// Days from today on whose planned session the log doesn't allow, with the session made to fit.
    var healthConflicts: [HealthConflict] {
        let calendar = Calendar.current
        let log = healthLog
        let today = calendar.startOfDay(for: .now)
        return (0..<7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: today),
                  let limit = log.limit(on: date),
                  let planned = plannedSession(on: date),
                  !(offset == 0 && !todaysWorkouts.isEmpty),
                  let fixed = limit.apply(to: planned) else { return nil }
            return HealthConflict(date: date, planned: planned, fixed: fixed, limit: limit)
        }
    }

    /// Changes the planned days the log doesn't allow, as the athlete asked from the Today card.
    func resolveHealthConflicts() {
        for conflict in healthConflicts {
            updatePlannedDay(on: conflict.date, with: conflict.fixed)
        }
        syncSessionReminders()
        writeDebugState()
    }

    private func healthLogChanged() {
        healthIssues = healthLog.pruned(now: .now)
        writeDebugState()
    }

    // MARK: - Training block

    /// The block week the next plan covers (from tomorrow, like the weekly analysis).
    var trainingBlockWeek: BlockWeek {
        TrainingBlock.week(start: nextPlanStart, profile: profile, weeks: metrics?.weeks ?? [])
    }

    /// The weeks from the next plan to the goal, empty without a goal.
    var trainingBlockOutline: [BlockWeek] {
        TrainingBlock.outline(start: nextPlanStart, profile: profile)
    }

    private var nextPlanStart: Date {
        let calendar = Calendar.current
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)) ?? .now
    }
}
