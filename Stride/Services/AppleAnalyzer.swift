import Foundation
import FoundationModels

nonisolated enum AnalyzerError: LocalizedError {
    case onDeviceUnavailable(String)
    case notReady(String)
    case appleIntelligence(String)
    case contextTooLarge

    var errorDescription: String? {
        switch self {
        case .onDeviceUnavailable(let reason), .notReady(let reason), .appleIntelligence(let reason): reason
        case .contextTooLarge: "Too much data for the on-device model."
        }
    }
}

nonisolated enum AppleModelRoute: String, Codable, Sendable {
    case privateCloud, onDevice

    var title: String {
        switch self {
        case .privateCloud: "Apple Private Cloud Compute"
        case .onDevice: "Apple on-device model"
        }
    }
}

/// Prefers Apple's larger server model on Private Cloud Compute (free, quota-limited) and falls back
/// to the on-device model when it's off, unreachable, or out of quota.
nonisolated struct AppleAnalyzer {
    var allowPrivateCloud: Bool

    struct Result<Output> {
        var report: Output
        var route: AppleModelRoute
        /// Set when Private Cloud Compute was wanted but the on-device model ran instead.
        var fallbackReason: String?
    }

    /// Tokens kept free in the on-device context window for the generated report.
    private static let outputReserve = 2000

    /// Creating `PrivateCloudComputeLanguageModel` traps unless the app is signed with the
    /// `com.apple.developer.private-cloud-compute` entitlement, which free Personal Teams can't get.
    /// Build with the PRIVATE_CLOUD_COMPUTE compilation condition (and that entitlement) to enable it.
    #if PRIVATE_CLOUD_COMPUTE
    static let isPrivateCloudInBuild = true
    #else
    static let isPrivateCloudInBuild = false
    #endif

    /// nil when at least one route can run, otherwise a user-facing reason.
    static func unavailableReason(allowPrivateCloud: Bool) -> String? {
        if allowPrivateCloud, privateCloudBlocker == nil { return nil }
        return onDeviceBlocker
    }

    static var onDeviceBlocker: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            nil
        case .unavailable(.deviceNotEligible):
            "This device doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            "Turn on Apple Intelligence in the Settings app."
        case .unavailable(.modelNotReady):
            "The on-device model is still downloading. Try again later."
        case .unavailable:
            "The on-device model is unavailable."
        }
    }

    static var privateCloudBlocker: String? {
        #if PRIVATE_CLOUD_COMPUTE
        let model = PrivateCloudComputeLanguageModel()
        switch model.availability {
        case .available:
            break
        case .unavailable(.deviceNotEligible):
            return "Private Cloud Compute isn't available on this device."
        case .unavailable(.systemNotReady):
            return "Private Cloud Compute isn't ready yet."
        case .unavailable:
            return "Private Cloud Compute is unavailable."
        }
        if model.quotaUsage.isLimitReached {
            return quotaMessage(resetDate: model.quotaUsage.resetDate)
        }
        return nil
        #else
        return "Private Cloud Compute needs an entitlement only paid Apple Developer accounts can get."
        #endif
    }

    /// Short status for Settings.
    static var privateCloudStatus: String {
        if let blocker = privateCloudBlocker { return blocker }
        #if PRIVATE_CLOUD_COMPUTE
        if case .belowLimit(let usage) = PrivateCloudComputeLanguageModel().quotaUsage.status, usage.isApproachingLimit {
            return "Ready, close to the usage limit"
        }
        #endif
        return "Ready"
    }

    /// Called on the main actor with each partial result while the model writes, so the UI can show it as it streams.
    typealias PartialHandler<Output: Generable> = @MainActor (Output.PartiallyGenerated) -> Void

    func analyze<Output: Generable & Sendable>(
        _: Output.Type,
        instructions: String,
        fullPrompt: String,
        compactPrompt: String,
        onPartial: PartialHandler<Output>? = nil
    ) async throws -> Result<Output> {
        var fallbackReason: String?

        #if PRIVATE_CLOUD_COMPUTE
        if allowPrivateCloud {
            if let blocker = Self.privateCloudBlocker {
                fallbackReason = blocker
            } else {
                do {
                    let report: Output = try await Self.respond(
                        model: PrivateCloudComputeLanguageModel(),
                        instructions: instructions,
                        prompts: [fullPrompt, compactPrompt],
                        onPartial: onPartial
                    )
                    return Result(report: report, route: .privateCloud)
                } catch let error as PrivateCloudComputeLanguageModel.Error {
                    fallbackReason = Self.describe(error)
                } catch LanguageModelError.rateLimited(let limit) {
                    fallbackReason = Self.quotaMessage(resetDate: limit.resetDate)
                }
            }
        }
        #else
        if allowPrivateCloud { fallbackReason = Self.privateCloudBlocker }
        #endif

        if let blocker = Self.onDeviceBlocker {
            throw AnalyzerError.onDeviceUnavailable([fallbackReason, blocker].compactMap(\.self).joined(separator: " "))
        }
        // Send the full 8 weeks when it fits the small on-device window, otherwise the compact brief.
        let prompts = await Self.fitsOnDevice(Output.self, instructions: instructions, prompt: fullPrompt)
            ? [fullPrompt, compactPrompt]
            : [compactPrompt]
        let report: Output = try await Self.respond(model: SystemLanguageModel.default, instructions: instructions, prompts: prompts, onPartial: onPartial)
        return Result(report: report, route: .onDevice, fallbackReason: fallbackReason)
    }

    /// Tries each prompt in order, moving to the next (smaller) one if the context window overflows.
    private static func respond<Output: Generable & Sendable>(
        model: some LanguageModel,
        instructions: String,
        prompts: [String],
        onPartial: PartialHandler<Output>?
    ) async throws -> Output {
        for (index, prompt) in prompts.enumerated() {
            let session = LanguageModelSession(model: model, instructions: instructions)
            do {
                // Stream so the UI can show the report as it's written; the on-device model is slow enough to notice.
                var final: GeneratedContent?
                for try await snapshot in session.streamResponse(to: prompt, generating: Output.self) {
                    final = snapshot.rawContent
                    if let onPartial { await onPartial(snapshot.content) }
                }
                guard let final else { throw AnalyzerError.appleIntelligence("Apple Intelligence returned nothing.") }
                return try Output(final)
            } catch LanguageModelError.contextSizeExceeded {
                if index == prompts.count - 1 { throw AnalyzerError.contextTooLarge }
            } catch let error as LanguageModelError {
                // Let Private Cloud Compute rate limits through, so `analyze` falls back to on-device.
                if case .rateLimited = error, model is PrivateCloudComputeLanguageModel { throw error }
                throw AnalyzerError.appleIntelligence(Self.describe(error))
            } catch let error as NSError where error.domain.hasPrefix("FoundationModels") {
                // Some failures while streaming arrive bridged, not as `LanguageModelError` (e.g. the Simulator's
                // missing guardrail backend).
                throw AnalyzerError.appleIntelligence("Apple Intelligence couldn't complete this (\(error.localizedDescription)).")
            }
        }
        throw AnalyzerError.contextTooLarge
    }

    /// Loads the on-device model ahead of a likely request, so the first response starts sooner.
    static func prewarm(instructions: String) {
        guard onDeviceBlocker == nil else { return }
        LanguageModelSession(instructions: instructions).prewarm()
    }

    private static func fitsOnDevice<Output: Generable>(_: Output.Type, instructions: String, prompt: String) async -> Bool {
        let model = SystemLanguageModel.default
        do {
            let used = try await model.tokenCount(for: instructions)
                + model.tokenCount(for: prompt)
                + model.tokenCount(for: Output.generationSchema)
            return used + outputReserve <= model.contextSize
        } catch {
            return false
        }
    }

    private static func describe(_ error: PrivateCloudComputeLanguageModel.Error) -> String {
        switch error {
        case .networkFailure: "Couldn't reach Private Cloud Compute."
        case .quotaLimitReached(let limit): quotaMessage(resetDate: limit.resetDate)
        case .serviceUnavailable: "Private Cloud Compute is temporarily unavailable."
        @unknown default: "Private Cloud Compute failed."
        }
    }

    private static func describe(_ error: LanguageModelError) -> String {
        switch error {
        case .guardrailViolation: "Apple Intelligence's safety filter blocked this request."
        case .refusal: "Apple Intelligence declined to analyze this."
        case .rateLimited: "Apple Intelligence is busy. Try again in a moment."
        case .timeout: "Apple Intelligence took too long. Try again."
        case .unsupportedLanguageOrLocale: "Apple Intelligence doesn't support your device's language for this yet."
        default: "Apple Intelligence couldn't complete the analysis (\(error.localizedDescription))."
        }
    }

    private static func quotaMessage(resetDate: Date?) -> String {
        guard let resetDate else { return "Private Cloud Compute usage limit reached." }
        return "Private Cloud Compute usage limit reached until \(resetDate.formatted(date: .abbreviated, time: .shortened))."
    }
}
