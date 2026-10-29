import Foundation
import TabulaDrivers
import TabulaFoundation
import TabulaSQL
import TabulaUpdates
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device model (macOS 26 with Apple Intelligence turned on). Nothing leaves the Mac.
public struct AppleIntelligenceProvider: AIProvider {
    public init() {}

    /// Why the model can't be used right now, or nil when it can.
    public static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(.deviceNotEligible):
                return "This Mac doesn't support Apple Intelligence."
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Turn on Apple Intelligence in System Settings › Apple Intelligence & Siri."
            case .unavailable(.modelNotReady):
                return "Apple Intelligence is still downloading its model. Try again later."
            case .unavailable:
                return "Apple Intelligence isn't available right now."
            }
        }
        #endif
        return "Apple Intelligence needs macOS 26 or later."
    }

    public func complete(_ request: AIRequest) async throws -> String {
        if let reason = Self.unavailableReason { throw AIError.unavailable(reason) }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = LanguageModelSession(instructions: request.instructions)
            let options = GenerationOptions(maximumResponseTokens: request.maxTokens)
            return try await session.respond(to: request.prompt, options: options).content
        }
        #endif
        throw AIError.unavailable("Apple Intelligence needs macOS 26 or later.")
    }

    public func stream(_ request: AIRequest) -> AIStream {
        AIStream.run { continuation in
            if let reason = Self.unavailableReason { throw AIError.unavailable(reason) }
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                let session = LanguageModelSession(instructions: request.instructions)
                let options = GenerationOptions(maximumResponseTokens: request.maxTokens)
                // Each snapshot is the answer so far; send what is new.
                var sent = ""
                for try await snapshot in session.streamResponse(to: request.prompt, options: options) {
                    let text = snapshot.content
                    // A snapshot that rewrites earlier text can't be taken back; send only what goes past it.
                    if text.count > sent.count { continuation.yield(.text(String(text.dropFirst(sent.count)))) }
                    if text.count >= sent.count { sent = text }
                }
                return
            }
            #endif
            throw AIError.unavailable("Apple Intelligence needs macOS 26 or later.")
        }
    }
}
