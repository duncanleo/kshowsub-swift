import AVFoundation
import ArgumentParser
import Foundation
import KShowSubCore
import SubtitleKit

@main
struct KShowSubCLI: AsyncParsableCommand {
    enum OCRPositionDirection: String, ExpressibleByArgument {
        case ltr
        case rtl

        var coreDirection: OCRCuePosition.TextDirection {
            switch self {
            case .ltr: return .ltr
            case .rtl: return .rtl
            }
        }
    }

    static let configuration = CommandConfiguration(
        commandName: ProcessInfo.processInfo.processName,
        abstract:
            "Generate ASS subtitles from video using Speech (dialogue) and Vision OCR (on-screen text).",
        discussion:
            "Runs speech recognition and OCR in parallel, then merges both into a single ASS file. Optional LLM post-processing can reduce OCR/speech overlap into one bottom subtitle track before translation.",
        version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    )

    @Option(name: .shortAndLong, help: "Input video file path")
    var input: String

    @Option(name: .shortAndLong, help: "Output ASS file path")
    var output: String

    @Option(name: .shortAndLong, help: "Locale for speech recognition (e.g. en-US, ko-KR, ja-JP)")
    var locale: String

    @Option(
        name: .long,
        help:
            "OCR sampling rate: frames per second to sample from the video for on-screen text (1–120)."
    )
    var ocrFPS: Int = 3

    @Option(
        name: .long,
        help:
            "OCR tuning preset: \(OCRProfile.allNamed.map(\.name).joined(separator: ", ")). Controls region filtering, similarity thresholds, and text-size limits."
    )
    var ocrProfile: String = "default"

    @Flag(
        name: .long,
        help:
            "Experimentally place OCR subtitles near their detected screen positions with limited dynamic font sizing."
    )
    var positionOCR: Bool = false

    @Option(
        name: .long,
        help:
            "Text direction for positioned OCR boundary alignment: ltr anchors the left edge, rtl anchors the right edge."
    )
    var ocrPositionDirection: OCRPositionDirection = .ltr

    @Option(
        name: .long,
        help: "Directory for resumable intermediate artifacts. Defaults to Application Support."
    )
    var workDir: String?

    @Flag(
        name: .long,
        inversion: .prefixedNo,
        help: "Reuse resumable intermediate artifacts when available."
    )
    var resume: Bool = true

    @Flag(name: .shortAndLong, help: "Translate subtitles to target locale")
    var translate: Bool = false

    @Option(name: .long, help: "Target locale for translation (e.g. en-US)")
    var targetLocale: String = "en-US"

    @Option(
        name: .long,
        help:
            "Translation provider: \(TranslationProviderRegistry.availableIDs.joined(separator: ", "))"
    )
    var translateProvider: String = "apple-intelligence"

    @Flag(name: .long, help: "Use an LLM to reduce OCR and speech cues into one bottom subtitle track before translation.")
    var postProcess: Bool = false

    @Option(
        name: .long,
        help:
            "Post-processing provider: \(SubtitlePostProcessingProviderRegistry.availableIDs.joined(separator: ", "))"
    )
    var postProcessProvider: String = "apple-intelligence"

    @Option(
        name: [.customLong("openai-model")],
        help:
            "Model for OpenAI-compatible translation/post-processing providers (default: gpt-5.4-nano, overrides OPENAI_MODEL). Uses direct chat completions requests."
    )
    var openAIModel: String?

    @Option(
        name: [.customLong("openai-base-url")],
        help:
            "Base URL for OpenAI-compatible translation/post-processing providers (overrides OPENAI_BASE_URL). For gateways (e.g. Gemini’s /v1beta/openai), set this to that root; /v1/chat/completions is appended."
    )
    var openAIBaseURL: String?

    @Option(
        name: [.customLong("openai-auth")],
        help:
            "How to send the API key: bearer (Authorization: Bearer, default) or x-api-key (x-api-key header). Overrides OPENAI_AUTH."
    )
    var openAIAuth: String?

    mutating func validate() throws {
        try TranslationProviderRegistry.validateProviderID(translateProvider)
        try SubtitlePostProcessingProviderRegistry.validateProviderID(postProcessProvider)
        var providerOptions: [String: String] = [:]
        if let m = openAIModel { providerOptions["openai-model"] = m }
        if let u = openAIBaseURL { providerOptions["openai-base-url"] = u }
        if let a = openAIAuth { providerOptions["openai-auth"] = a }
        if translate {
            try TranslationProviderRegistry.validateProviderConfiguration(
                id: translateProvider, options: providerOptions)
        }
        if postProcess {
            try SubtitlePostProcessingProviderRegistry.validateProviderConfiguration(
                id: postProcessProvider,
                options: providerOptions
            )
        }
    }

    func run() async throws {
        let inputURL = URL(fileURLWithPath: input)
        let outputURL = URL(fileURLWithPath: output)

        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw ValidationError("Input file does not exist: \(input)")
        }
        guard (1...120).contains(ocrFPS) else {
            throw ValidationError("--ocr-fps must be between 1 and 120, got \(ocrFPS)")
        }

        let resolvedLocale = Locale(identifier: locale)
        let transcriber = VideoSpeechTranscriber(locale: resolvedLocale)
        let ocrProcessor = OCRProcessor(
            positionedOverlays: positionOCR,
            positionedTextDirection: ocrPositionDirection.coreDirection
        )
        let playRes = (x: OCRCuePosition.defaultPlayResX, y: OCRCuePosition.defaultPlayResY)
        let store = try JobStore(
            inputURL: inputURL, workDirOverride: workDir, resumeEnabled: resume)
        try await store.prepareWorkspace()
        print("Workspace: \(await store.workspacePath())")

        let resolvedProfile = OCRProfile.named(ocrProfile)!
        let speechKey = Self.stageKey(parts: ["speech", resolvedLocale.identifier])
        let ocrFramesKey = Self.stageKey(parts: ["ocr", resolvedLocale.identifier, String(ocrFPS)])
        let ocrLayoutKey = positionOCR ? "positioned-\(ocrPositionDirection.rawValue)" : "top"
        let ocrKey = Self.stageKey(parts: [
            "ocr", resolvedLocale.identifier, String(ocrFPS), ocrProfile, ocrLayoutKey,
        ])

        async let dialogueCues: [SubtitleCue] = loadOrCreateSpeechCues(
            store: store,
            key: speechKey,
            inputURL: inputURL,
            transcriber: transcriber
        )
        async let ocrCues: [SubtitleCue] = loadOrCreateOCRCues(
            store: store,
            key: ocrKey,
            framesKey: ocrFramesKey,
            inputURL: inputURL,
            locale: resolvedLocale,
            fps: ocrFPS,
            profile: resolvedProfile,
            processor: ocrProcessor
        )

        let (dialogue, ocr) = try await (dialogueCues, ocrCues)
        let mergedDialogue = SpeechCueMerger(locale: resolvedLocale).merge(dialogue)
        let mergeKey = Self.stageKey(parts: ["merge", speechKey, ocrKey, resolvedLocale.identifier])
        var allCues = try await loadOrCreateMergedCues(
            store: store,
            key: mergeKey,
            dialogue: mergedDialogue,
            ocr: ocr
        )

        if postProcess {
            var providerOptions: [String: String] = [:]
            if let m = openAIModel { providerOptions["openai-model"] = m }
            if let u = openAIBaseURL { providerOptions["openai-base-url"] = u }
            if let a = openAIAuth { providerOptions["openai-auth"] = a }
            let provider = try SubtitlePostProcessingProviderRegistry.resolveOrThrow(
                id: postProcessProvider,
                locale: resolvedLocale,
                options: providerOptions
            )
            let postProcessor = SubtitlePostProcessor(provider: provider)
            let postProcessKey = Self.stageKey(parts: [
                "post-process",
                mergeKey,
                resolvedLocale.identifier,
                provider.id,
                openAIModel ?? ProcessInfo.processInfo.environment["OPENAI_MODEL"] ?? "",
                openAIBaseURL ?? ProcessInfo.processInfo.environment["OPENAI_BASE_URL"] ?? "",
                openAIAuth ?? ProcessInfo.processInfo.environment["OPENAI_AUTH"] ?? "",
            ])
            allCues = try await loadOrCreatePostProcessedCues(
                store: store,
                key: postProcessKey,
                cues: allCues,
                processor: postProcessor
            )
        }

        if translate {
            let target = Locale(identifier: targetLocale)
            var providerOptions: [String: String] = [:]
            if let m = openAIModel { providerOptions["openai-model"] = m }
            if let u = openAIBaseURL { providerOptions["openai-base-url"] = u }
            if let a = openAIAuth { providerOptions["openai-auth"] = a }
            let provider = try TranslationProviderRegistry.resolveOrThrow(
                id: translateProvider,
                sourceLocale: resolvedLocale,
                targetLocale: target,
                options: providerOptions
            )
            let translator = SubtitleTranslator(provider: provider)
            print("Translating \(allCues.count) cues to \(targetLocale) (\(provider.id))...")
            allCues = try await translator.translate(allCues)
        }

        let subtitle = ASSMerger.merge(
            cues: allCues,
            playResX: playRes.x,
            playResY: playRes.y,
            enableOCRPositioning: positionOCR,
            ocrPositionTextDirection: ocrPositionDirection.coreDirection
        )

        try await subtitle.save(to: outputURL, format: .ass, lineEnding: .lf)
        try Self.injectPlayRes(into: outputURL, playResX: playRes.x, playResY: playRes.y)
        print("Wrote \(subtitle.cues.count) cues to \(outputURL.path)")
    }

    private func loadOrCreateSpeechCues(
        store: JobStore,
        key: String,
        inputURL: URL,
        transcriber: any VideoSpeechTranscribing
    ) async throws -> [SubtitleCue] {
        if await store.canReuse(stage: .speech, key: key),
            let cached = try await store.loadCues(stage: .speech)
        {
            print("Speech: reusing cached cues.")
            return cached
        }

        try await store.markStageRunning(.speech, key: key)
        do {
            let cues = try await transcriber.transcribe(videoURL: inputURL)
            try await store.saveCues(
                cues, stage: .speech, key: key, artifactName: StageArtifacts.speechCues)
            return cues
        } catch {
            try? await store.markStageFailed(.speech, key: key, error: error)
            throw error
        }
    }

    private func loadOrCreateOCRCues(
        store: JobStore,
        key: String,
        framesKey: String,
        inputURL: URL,
        locale: Locale,
        fps: Int,
        profile: OCRProfile,
        processor: any VideoOCRProcessing
    ) async throws -> [SubtitleCue] {
        let existingRecords = try await store.loadOCRFrameRecords(framesKey: framesKey)
        let totalFrameCount = try await Self.ocrFrameCount(videoURL: inputURL, fps: fps)
        let resetArtifacts =
            existingRecords.isEmpty ? [StageArtifacts.ocrFrames, StageArtifacts.ocrCues] : []
        try await store.markStageRunning(
            .ocr,
            key: key,
            metadata: [
                "framesKey": framesKey,
                "frameCount": String(totalFrameCount),
                "completedFrameCount": String(existingRecords.count),
            ],
            resetArtifacts: resetArtifacts
        )

        do {
            let cues = try await processor.extractText(
                videoURL: inputURL,
                locale: locale,
                fps: fps,
                profile: profile,
                existingFrameRecords: existingRecords,
                persistRecords: { records in
                    try await store.appendOCRFrameRecords(
                        records, stageKey: key, framesKey: framesKey,
                        totalFrameCount: totalFrameCount)
                }
            )
            try await store.saveCues(
                cues, stage: .ocr, key: key, artifactName: StageArtifacts.ocrCues)
            return cues
        } catch {
            try? await store.markStageFailed(.ocr, key: key, error: error)
            throw error
        }
    }

    private func loadOrCreateMergedCues(
        store: JobStore,
        key: String,
        dialogue: [SubtitleCue],
        ocr: [SubtitleCue]
    ) async throws -> [SubtitleCue] {
        try await store.markStageRunning(.merge, key: key)
        let merged = (dialogue + ocr).sorted { $0.startTime < $1.startTime }
        try await store.saveCues(
            merged, stage: .merge, key: key, artifactName: StageArtifacts.mergedCues)
        return merged
    }

    private func loadOrCreatePostProcessedCues(
        store: JobStore,
        key: String,
        cues: [SubtitleCue],
        processor: SubtitlePostProcessor
    ) async throws -> [SubtitleCue] {
        if await store.canReuse(stage: .postProcess, key: key),
            let cached = try await store.loadCues(stage: .postProcess)
        {
            print("Post-process: reusing cached cues.")
            return cached
        }

        try await store.markStageRunning(.postProcess, key: key)
        do {
            let postProcessed = try await processor.postProcess(cues)
            try await store.saveCues(
                postProcessed,
                stage: .postProcess,
                key: key,
                artifactName: StageArtifacts.postProcessedCues
            )
            return postProcessed
        } catch {
            try? await store.markStageFailed(.postProcess, key: key, error: error)
            throw error
        }
    }

    private static func ocrFrameCount(videoURL: URL, fps: Int) async throws -> Int {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let totalSeconds = CMTimeGetSeconds(duration)
        return max(1, Int(ceil(totalSeconds * Double(fps))))
    }

    private static func stageKey(parts: [String]) -> String {
        JobStore.hashString(parts.joined(separator: "|"))
    }

    /// Injects PlayResX/PlayResY into [Script Info] so alignment and MarginV render correctly.
    /// Without these, players default to 384x288 which breaks top/bottom positioning.
    private static func injectPlayRes(into url: URL, playResX: Int, playResY: Int) throws {
        var content = try String(contentsOf: url, encoding: .utf8)
        guard !content.contains("PlayResX:") else { return }
        let playResHeaders = "\nPlayResX: \(playResX)\nPlayResY: \(playResY)\n"
        if let scriptTypeRange = content.range(of: "ScriptType: v4.00+") {
            content.insert(contentsOf: playResHeaders, at: scriptTypeRange.upperBound)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
