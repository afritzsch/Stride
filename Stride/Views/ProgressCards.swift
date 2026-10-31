import SwiftUI

struct SkillsCard: View {
    var progress: ProgressReport
    @State private var showsRules = false

    var body: some View {
        Card(title: "Skills") {
            ForEach(Skill.allCases) { skill in
                let level = progress.skills[skill] ?? LevelProgress(xp: 0, base: LevelProgress.skillBase)
                NavigationLink(value: skill) {
                    HStack(spacing: 12) {
                        Image(systemName: skill.systemImage)
                            .foregroundStyle(skill.color)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(skill.title).font(.subheadline.bold())
                                Text("Lv \(level.level)").font(.subheadline).monospacedDigit().foregroundStyle(skill.color)
                                Spacer()
                                let week = progress.skillXP(skill, in: .week)
                                if week > 0 {
                                    Text("+\(Format.number(week)) this week").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            ProgressView(value: level.fraction).tint(skill.color)
                        }
                        LinkChevron()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            DisclosureGroup("How XP works", isExpanded: $showsRules) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Skill.allCases) { skill in
                        Text("**\(skill.title):** \(skill.rule)")
                    }
                    Text("Your athlete level adds up all skill XP. Each level takes a little more XP than the last, and XP never goes down.")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(.top, 6)
            }
            .font(.subheadline)
        }
    }
}

// MARK: - Records & achievements

struct PersonalRecordsCard: View {
    var records: [PersonalRecord]

    var body: some View {
        Card(title: "Personal records") {
            if records.isEmpty {
                Text("Records appear once you've logged workouts.").font(.footnote).foregroundStyle(.secondary)
            }
            DividedForEach(data: records) { record in
                HStack {
                    Image(systemName: record.systemImage).foregroundStyle(.yellow).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.title).font(.subheadline)
                        Text(record.date, format: .dateTime.day().month(.abbreviated).year()).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(record.value).font(.subheadline.bold()).monospacedDigit()
                }
            }
        }
    }
}

struct AchievementsCard: View {
    var achievements: [Achievement]

    /// Unlocked first (newest first), then the locked ones closest to done.
    private var sorted: [Achievement] {
        achievements.filter(\.isUnlocked).sorted { ($0.unlockedAt ?? .distantPast) > ($1.unlockedAt ?? .distantPast) }
            + achievements.filter { !$0.isUnlocked }.sorted { $0.fraction > $1.fraction }
    }

    var body: some View {
        Card(title: "Achievements") {
            Text("\(achievements.filter(\.isUnlocked).count) / \(achievements.count)")
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } content: {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 12) {
                ForEach(sorted) { AchievementBadge(achievement: $0) }
            }
        }
    }
}

private struct AchievementBadge: View {
    var achievement: Achievement

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: achievement.systemImage)
                .font(.title2)
                .frame(width: 52, height: 52)
                .background(achievement.isUnlocked ? AnyShapeStyle(Color.yellow.gradient) : AnyShapeStyle(.fill.tertiary), in: .circle)
                .foregroundStyle(achievement.isUnlocked ? .black : .secondary)
            Text(achievement.title)
                .font(.caption.bold())
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if let date = achievement.unlockedAt {
                Text(date, format: .dateTime.month(.abbreviated).year(.twoDigits)).font(.caption2).foregroundStyle(.secondary)
            } else {
                ProgressView(value: achievement.fraction).tint(.yellow)
            }
        }
        .frame(maxWidth: .infinity)
        .opacity(achievement.isUnlocked ? 1 : 0.75)
        .accessibilityElement(children: .combine)
        .accessibilityHint(achievement.detail)
    }
}
