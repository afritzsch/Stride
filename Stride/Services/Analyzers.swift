import Foundation
import FoundationModels

nonisolated enum AnalyzerError: LocalizedError {
    case missingAPIKey
    case api(status: Int, message: String)
    case refused
    case truncated
    case malformedResponse
    case onDeviceUnavailable(String)
    case contextTooLarge

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Add your Anthropic API key in Settings."
        case .api(let status, let message): "Claude API error \(status): \(message)"
        case .refused: "Claude declined to analyze this request."
        case .truncated: "The analysis was cut off. Please try again."
        case .malformedResponse: "Couldn't read the analysis. Please try again."
        case .onDeviceUnavailable(let reason): reason
        case .contextTooLarge: "Too much data for the on-device model. Try Claude instead."
        }
    }
}

// MARK: - Claude

/// Calls the Claude Messages API directly with the user's own API key and decodes the structured JSON output.
nonisolated struct ClaudeAnalyzer {
    var apiKey: String
    var model = "claude-opus-5-5"

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    func analyze(instructions: String, prompt: String) async throws -> AnalysisReport {
        guard !apiKey.isEmpty else { throw AnalyzerError.missingAPIKey }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        // Lets the API retry on a fallback model server-side if a safety classifier declines.
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "fallbacks": "default",
            "system": instructions,
            "messages": [["role": "user", "content": prompt]],
            "output_config": [
                "effort": "high",
                "format": ["type": "json_schema", "schema": AnalysisReport.jsonSchema],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = (try? JSONDecoder().decode(APIErrorEnvelope.self, from: data))?.error.message
            throw AnalyzerError.api(status: status, message: message ?? HTTPURLResponse.localizedString(forStatusCode: status))
        }

        let message = try JSONDecoder().decode(MessageResponse.self, from: data)
        switch message.stopReason {
        case "refusal": throw AnalyzerError.refused
        case "max_tokens": throw AnalyzerError.truncated
        default: break
        }
        let text = message.content.filter { $0.type == "text" }.compactMap(\.text).joined()
        do {
            return try JSONDecoder().decode(AnalysisReport.self, from: Data(text.utf8))
        } catch {
            throw AnalyzerError.malformedResponse
        }
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

// MARK: - On-device (Apple Foundation Models)

nonisolated struct OnDeviceAnalyzer {
    /// nil when the model is ready, otherwise a user-facing reason.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            nil
        case .unavailable(.deviceNotEligible):
            "This device doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            "Turn on Apple Intelligence in the Settings app to use the on-device model."
        case .unavailable(.modelNotReady):
            "The on-device model is still downloading. Try again later."
        case .unavailable:
            "The on-device model is unavailable."
        }
    }

    func analyze(instructions: String, prompt: String) async throws -> AnalysisReport {
        if let reason = Self.unavailableReason { throw AnalyzerError.onDeviceUnavailable(reason) }
        let session = LanguageModelSession(instructions: instructions)
        do {
            return try await session.respond(to: prompt, generating: AnalysisReport.self).content
        } catch LanguageModelError.contextSizeExceeded {
            throw AnalyzerError.contextTooLarge
        }
    }
}
