import Speech
import AVFoundation
import ServiceManagement
import ApplicationServices

// These immutable references are handed off after preparation completes. Audio
// format is never mutated; SpeechAnalyzer/SpeechTranscriber support async use.
struct PreparedSpeech: @unchecked Sendable {
    let module: SpeechTranscriber
    let analyzer: SpeechAnalyzer
    let format: AVAudioFormat
}
enum SpeechPreparation {
    @concurrent static func prepare(language: String, terms: [String] = []) async throws -> PreparedSpeech {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
            throw NSError(domain: "MyWispr", code: 1, userInfo: [NSLocalizedDescriptionKey: "Lingua non supportata dal motore locale."])
        }
        let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        try await AssetInventory.reserve(locale: locale)
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [module]) { try await installation.downloadAndInstall() }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw NSError(domain: "MyWispr", code: 2, userInfo: [NSLocalizedDescriptionKey: "Formato audio non disponibile."])
        }
        let analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        if !terms.isEmpty {
            // Biases recognition toward the user's brand names and jargon.
            let context = AnalysisContext()
            context.contextualStrings[.general] = terms
            try await analyzer.setContext(context)
        }
        try await analyzer.prepareToAnalyze(in: format)
        try Task.checkCancellation()
        return PreparedSpeech(module: module, analyzer: analyzer, format: format)
    }
}
struct PermissionSnapshot: Sendable {
    let microphone: Bool
    let accessibility: Bool
    let launchAtLogin: Bool
    let loginNeedsApproval: Bool
    @concurrent static func read() async -> PermissionSnapshot {
        let status = SMAppService.mainApp.status
        return PermissionSnapshot(microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, accessibility: AXIsProcessTrusted(), launchAtLogin: status == .enabled || status == .requiresApproval, loginNeedsApproval: status == .requiresApproval)
    }
}
