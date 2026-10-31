import Foundation
import FoundationModels
import Observation

/// One line of the coach conversation as the app shows it.
struct ChatMessage: Identifiable, Hashable {
    enum Role { case athlete, coach, notice }

    let id = UUID()
    var role: Role
    var text: String
}

/// A conversation with the on-device model, which looks data up through tools instead of getting it all up front,
/// so it fits the small context window.
@Observable
final class CoachChat {
    private(set) var messages: [ChatMessage] = []
    private(set) var isResponding = false
    /// What the coach is looking up right now, e.g. "Looking at your workouts…".
    private(set) var activity: String?
    var error: String?

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var session: LanguageModelSession?

    init(model: AppModel) {
        self.model = model
    }

    func send(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isResponding, let model else { return }
        model.refreshModelAvailability()
        if let blocker = model.onDeviceBlocker {
            error = blocker
            return
        }
        error = nil
        messages.append(ChatMessage(role: .athlete, text: text))
        isResponding = true
        defer {
            isResponding = false
            activity = nil
        }

        for attempt in 1...2 {
            let session = self.session ?? makeSession(model: model)
            self.session = session
            messages.append(ChatMessage(role: .coach, text: ""))
            let index = messages.count - 1
            do {
                for try await snapshot in session.streamResponse(to: text) {
                    activity = nil
                    messages[index].text = snapshot.content
                }
                return
            } catch LanguageModelError.contextSizeExceeded where attempt == 1 {
                // The window is small: start over with fresh context and ask again.
                messages.remove(at: index)
                messages.append(ChatMessage(role: .notice, text: "The conversation got long, so the coach started fresh."))
                self.session = nil
            } catch {
                messages.remove(at: index)
                self.error = Self.describe(error)
                model.debugLog("Coach chat failed: \(error)")
                return
            }
        }
    }

    func reset() {
        guard !isResponding else { return }
        messages = []
        session = nil
        error = nil
    }

    /// Loads the model while the athlete is typing.
    func prewarm() {
        guard let model, model.onDeviceBlocker == nil, session == nil else { return }
        let session = makeSession(model: model)
        session.prewarm()
        self.session = session
    }

    func setActivity(_ text: String) { activity = text }

    func notice(_ text: String) { messages.append(ChatMessage(role: .notice, text: text)) }

    private func makeSession(model: AppModel) -> LanguageModelSession {
        LanguageModelSession(
            tools: CoachTools.all(CoachToolbox(model: model, chat: self)),
            instructions: Self.instructions(model: model)
        )
    }

    private static func instructions(model: AppModel) -> String {
        let calendar = Calendar.current
        var lines = [
            """
            You are an experienced endurance coach chatting with your athlete in a phone app. Their watch data is \
            available through your tools: use them before answering questions about their training, recovery or \
            plan, and cite the numbers you find. Never invent data; if a tool has nothing, say so. When asked for a \
            prognosis, prediction or what to expect (fitness, race time, reaching the goal), always give your best \
            estimate: call trends first, then answer with a concrete range, the numbers it rests on and how sure you \
            are. For race times, call raceForecast and quote its times exactly; never calculate a time yourself. \
            Projecting from their data is coaching, not inventing data, and a training prognosis is not medical \
            advice. Change the plan only when the athlete asks for it, keep changes consistent with their \
            availability, and tell them what you changed. For when to train, use freeTimes (calendar and weather); add a \
            session to the calendar only when the athlete asks. Only for pain, injury or illness, recommend seeing a \
            professional. Answer in a few short sentences, addressing the athlete as "you".
            """,
            "",
            "TODAY: \(PromptBuilder.dayLabel(.now, calendar: calendar))",
        ]
        let profile = model.profile
        lines.append("ATHLETE: \(profile.primarySport), \(profile.experience.rawValue); \(profile.trainingDaysPerWeek) training days and \(PromptBuilder.num(profile.weeklyHoursAvailable, 1)) h a week")
        lines.append("HR ZONES: \(model.heartRateZones.summary)")
        if profile.hasGoal {
            lines.append("GOAL: \(PromptBuilder.goalSummary(profile, calendar: calendar))")
        }
        if !profile.notes.isEmpty { lines.append("ATHLETE NOTES: \(PromptBuilder.quote(profile.notes))") }
        if let readiness = model.readiness, readiness.level != .unknown {
            let signals = readiness.signals.map(\.text).joined(separator: "; ")
            lines.append("THIS MORNING: \(readiness.level.title.lowercased())\(signals.isEmpty ? "" : " (\(signals))")")
        }
        if let latest = model.latestAnalysis {
            lines.append("YOUR LAST WEEKLY VERDICT (\(PromptBuilder.dayLabel(latest.createdAt, calendar: calendar))): \(latest.report.headline)")
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? LanguageModelError {
            switch error {
            case .guardrailViolation, .refusal: return "The coach can't answer that. Try asking differently."
            case .rateLimited: return "Apple Intelligence is busy. Try again in a moment."
            case .unsupportedLanguageOrLocale: return "Apple Intelligence doesn't support your language for this yet."
            default: break
            }
        }
        return "The coach couldn't answer (\(error.localizedDescription))."
    }
}
