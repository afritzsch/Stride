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
    /// Notices of changes the athlete can still undo (a plan day, a calendar session).
    private(set) var undoable: Set<UUID> = []

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var session: LanguageModelSession?
    @ObservationIgnored private var undoActions: [UUID: @MainActor () -> Void] = [:]
    /// Set when a tool changed the plan or calendar while answering the current message.
    @ObservationIgnored private var changedThisTurn = false
    /// Changes the athlete undid since the coach last answered, told to the model with the next message.
    @ObservationIgnored private var undoneChanges: [String] = []

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

        changedThisTurn = false
        let prompt = undoneChanges.isEmpty ? text : "(I undid this change: \(undoneChanges.joined(separator: " "))) \(text)"
        undoneChanges = []
        var earlier: [(athlete: String, coach: String)] = []
        for attempt in 1...2 {
            let session = self.session ?? makeSession(model: model, earlier: earlier)
            self.session = session
            messages.append(ChatMessage(role: .coach, text: ""))
            let index = messages.count - 1
            do {
                for try await snapshot in session.streamResponse(to: prompt) {
                    activity = nil
                    messages[index].text = snapshot.content
                }
                return
            } catch LanguageModelError.contextSizeExceeded where attempt == 1 {
                // The window is small: start over, keeping the last exchanges as text instead of the tool output.
                messages.remove(at: index)
                self.session = nil
                if changedThisTurn {
                    // Asking again would repeat the change (and its undo would only undo the repeat).
                    notice("The conversation got long, so the coach started fresh. Your change is saved.")
                    return
                }
                notice("The conversation got long, so the coach started fresh.")
                earlier = Self.lastExchanges(in: messages.dropLast(2))
            } catch {
                messages.remove(at: index)
                self.error = Self.describe(error)
                model.debugLog("Coach chat failed: \(error)")
                return
            }
        }
    }

    /// Up to two athlete/coach exchanges from the end of a conversation, without notices.
    private static func lastExchanges(in messages: ArraySlice<ChatMessage>) -> [(athlete: String, coach: String)] {
        var exchanges: [(athlete: String, coach: String)] = []
        var reply: String?
        for message in messages.reversed() where exchanges.count < 2 {
            switch message.role {
            case .coach where !message.text.isEmpty: reply = message.text
            case .athlete:
                if let coach = reply { exchanges.insert((message.text, coach), at: 0) }
                reply = nil
            default: break
            }
        }
        return exchanges
    }

    func reset() {
        guard !isResponding else { return }
        messages = []
        session = nil
        error = nil
        undoable = []
        undoActions = [:]
        undoneChanges = []
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

    /// A notice of a change the coach made, with a way to take it back.
    func change(_ text: String, undo: @escaping @MainActor () -> Void) {
        let message = ChatMessage(role: .notice, text: text)
        messages.append(message)
        undoable.insert(message.id)
        undoActions[message.id] = undo
        changedThisTurn = true
    }

    func undo(_ id: UUID) {
        guard undoable.remove(id) != nil, let action = undoActions.removeValue(forKey: id) else { return }
        action()
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        // The session still remembers the change: tell it with the next message, so it doesn't build on it.
        undoneChanges.append(messages[index].text)
        messages[index].text += " Undone."
    }

    private func makeSession(model: AppModel, earlier: [(athlete: String, coach: String)] = []) -> LanguageModelSession {
        LanguageModelSession(
            tools: CoachTools.all(CoachToolbox(model: model, chat: self)),
            instructions: CoachTools.instructions(
                profile: model.profile, zones: model.heartRateZones, readiness: model.readiness,
                lastVerdict: model.latestAnalysis, earlier: earlier
            )
        )
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
