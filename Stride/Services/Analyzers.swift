import Foundation
import FoundationModels

nonisolated enum AnalyzerError: LocalizedError {
    case missingAPIKey
    case api(status: Int, message: String)
    case refused
    case truncated
    /// Carries the decoding error and the start of the text for debugging; the user sees a generic message.
    case malformedResponse(String)
    case onDeviceUnavailable(String)
    case notReady(String)
    case appleIntelligence(String)
    case contextTooLarge

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Add your Anthropic API key in Settings."
        case .api(let status, let message): "Claude API error \(status): \(message)"
        case .refused: "Claude declined to analyze this request."
        case .truncated: "The analysis was cut off. Please try again."
        case .malformedResponse: "Couldn't read the analysis. Please try again."
        case .onDeviceUnavailable(let reason), .notReady(let reason), .appleIntelligence(let reason): reason
        case .contextTooLarge: "Too much data for the on-device model. Try Claude instead."
        }
    }
}

// MARK: - Claude

/// Calls the Claude Messages API directly with the user's own API key and decodes the structured JSON output.
nonisolated struct ClaudeAnalyzer {
    var apiKey: String
    var model = "claude-opus-5-5"
    static let displayName = "Claude Opus 5.5"

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    /// Thinking (always on for this model) counts toward this, so leave room beyond the report itself.
    private static let maxTokens = 32000
    private static let maxAttempts = 3

    func analyze<Output: StructuredOutput>(_: Output.Type, instructions: String, prompt: String) async throws -> Output {
        guard !apiKey.isEmpty else { throw AnalyzerError.missingAPIKey }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        // Lets the API retry on a fallback model server-side if a safety classifier declines.
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": Self.maxTokens,
            "fallbacks": "default",
            "system": instructions,
            "messages": [["role": "user", "content": prompt]],
            "output_config": [
                "effort": "high",
                "format": ["type": "json_schema", "schema": Output.jsonSchema],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await send(request)
        let message = try JSONDecoder().decode(MessageResponse.self, from: data)
        switch message.stopReason {
        case "refusal": throw AnalyzerError.refused
        case "max_tokens": throw AnalyzerError.truncated
        default: break
        }
        // After a server-side fallback, content holds the first model's partial output, a "fallback"
        // block, then the fallback model's full output. Only the part after the last fallback counts.
        let start = message.content.lastIndex { $0.type == "fallback" }.map { $0 + 1 } ?? 0
        let text = message.content[start...].filter { $0.type == "text" }.compactMap(\.text).joined()
        do {
            return try JSONDecoder().decode(Output.self, from: Data(text.utf8))
        } catch {
            throw AnalyzerError.malformedResponse("\(error) in: \(text.prefix(300))")
        }
    }

    /// Sends the request, retrying rate limits, overload and server errors with backoff.
    private func send(_ request: URLRequest) async throws -> Data {
        for attempt in 1...Self.maxAttempts {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if status == 200 { return data }

            let retryable = [408, 409, 429].contains(status) || status >= 500
            if retryable, attempt < Self.maxAttempts {
                let retryAfter = http?.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
                try await Task.sleep(for: .seconds(min(retryAfter ?? Double(2 << attempt), 60)))
                continue
            }
            let message = (try? JSONDecoder().decode(APIErrorEnvelope.self, from: data))?.error.message
            throw AnalyzerError.api(status: status, message: message ?? HTTPURLResponse.localizedString(forStatusCode: status))
        }
        preconditionFailure("unreachable")
    }

    private struct MessageResponse: Decodable {
        struct Block: Decodable {
            var type: String
            var text: String?
        }
        var content: [Block]
        var stopReason: String?

        enum CodingKeys: String, CodingKey {
            case content
            case stopReason = "stop_reason"
        }
    }

    private struct APIErrorEnvelope: Decodable {
        struct Detail: Decodable { var message: String }
        var error: Detail
    }
}

// MARK: - Apple Intelligence (Foundation Models)

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

    func analyze<Output: StructuredOutput>(
        _: Output.Type,
        instructions: String,
        fullPrompt: String,
        compactPrompt: String
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
                        prompts: [fullPrompt, compactPrompt]
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
        let report: Output = try await Self.respond(model: SystemLanguageModel.default, instructions: instructions, prompts: prompts)
        return Result(report: report, route: .onDevice, fallbackReason: fallbackReason)
    }

    /// Tries each prompt in order, moving to the next (smaller) one if the context window overflows.
    private static func respond<Output: StructuredOutput>(model: some LanguageModel, instructions: String, prompts: [String]) async throws -> Output {
        for (index, prompt) in prompts.enumerated() {
            let session = LanguageModelSession(model: model, instructions: instructions)
            do {
                return try await session.respond(to: prompt, generating: Output.self).content
            } catch LanguageModelError.contextSizeExceeded {
                if index == prompts.count - 1 { throw AnalyzerError.contextTooLarge }
            } catch let error as LanguageModelError {
                // Let Private Cloud Compute rate limits through, so `analyze` falls back to on-device.
                if case .rateLimited = error, model is PrivateCloudComputeLanguageModel { throw error }
                throw AnalyzerError.appleIntelligence(Self.describe(error))
            }
        }
        throw AnalyzerError.contextTooLarge
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
