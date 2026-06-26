import Foundation
import SubtitleKit

@testable import KShowSubCore

struct TestFailure: Error, CustomStringConvertible {
    let message: String
    let file: StaticString
    let line: UInt

    var description: String {
        "\(file):\(line): \(message)"
    }
}

func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    guard condition() else {
        throw TestFailure(message: message, file: file, line: line)
    }
}

func expectEqual<T: Equatable>(
    _ actual: T,
    _ expected: T,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    try expect(
        actual == expected, "Expected \(actual) to equal \(expected)", file: file, line: line)
}

func require<T>(
    _ value: T?,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> T {
    guard let value else {
        throw TestFailure(message: message, file: file, line: line)
    }
    return value
}

@main
enum KShowSubCoreTestRunner {
    typealias Test = (name: String, run: () async throws -> Void)

    static func main() async {
        let tests: [Test] = [
            ("IndexedTranslationBatchParser parses item elements", testParsesItemElements),
            ("IndexedTranslationBatchParser parses CDATA", testParsesCDATA),
            ("IndexedTranslationBatchParser parses indexed fallback lines", testParsesIndexedLines),
            (
                "IndexedTranslationBatchParser throws on invalid output",
                testParserThrowsOnInvalidOutput
            ),
            (
                "TranslationMessageFormatting returns raw text without context",
                testMessageWithoutContext
            ),
            ("TranslationMessageFormatting includes context markers", testMessageWithContext),
            ("TranslationMessageFormatting truncates long text", testMessageTruncatesLongText),
            ("SpeechCueMerger merges nearby words", testSpeechCueMergerMergesNearbyWords),
            ("SpeechCueMerger splits on pause", testSpeechCueMergerSplitsOnPause),
            ("SpeechCueMerger wraps long cues", testSpeechCueMergerWrapsLongCue),
            ("ASSMerger adds styles and renumbers cues", testASSMergerAddsStylesAndRenumbers),
            (
                "ASSMerger leaves OCR positioning disabled by default",
                testASSMergerLeavesOCRPositioningDisabledByDefault
            ),
            ("ASSMerger applies OCR position overrides", testASSMergerAppliesOCRPositionOverrides),
            (
                "ASSMerger applies RTL OCR position overrides",
                testASSMergerAppliesRTLOCRPositionOverrides
            ),
            (
                "ASSMerger keeps positioned OCR above overlapping dialogue",
                testASSMergerKeepsPositionedOCRAboveOverlappingDialogue
            ),
            (
                "ASSMerger lanes positioned OCR above overlapping dialogue",
                testASSMergerLanesPositionedOCRAboveOverlappingDialogue
            ),
            (
                "ASSMerger applies clamped OCR font overrides",
                testASSMergerAppliesClampedOCRFontOverrides
            ),
            ("OCRCuePosition derives normalized center", testOCRCuePositionDerivesNormalizedCenter),
            (
                "OCRCuePosition derives directional anchors",
                testOCRCuePositionDerivesDirectionalAnchors
            ),
            (
                "OCRCuePosition does not match missing position to present position",
                testOCRCuePositionDoesNotMatchMissingPositionToPresentPosition
            ),
            (
                "PostProcessingPrompt includes Korean show subtitle guidance",
                testPostProcessingPromptIncludesKoreanShowGuidance
            ),
            (
                "PostProcessingResponseParser parses JSON object",
                testPostProcessingResponseParserParsesObject
            ),
            (
                "PostProcessingResponseParser extracts wrapped JSON",
                testPostProcessingResponseParserExtractsWrappedJSON
            ),
            (
                "PostProcessingResponseParser extracts fenced array",
                testPostProcessingResponseParserExtractsFencedArray
            ),
            (
                "PostProcessingResponseParser accepts alternate timing fields",
                testPostProcessingResponseParserAcceptsAlternateTimingFields
            ),
            (
                "PostProcessingResponseParser infers missing end times",
                testPostProcessingResponseParserInfersMissingEndTimes
            ),
            (
                "SubtitlePostProcessor returns bottom dialogue cues",
                testSubtitlePostProcessorReturnsBottomDialogueCues
            ),
            (
                "SubtitlePostProcessor passes cue role and overlap context",
                testSubtitlePostProcessorPassesCueRoleAndOverlapContext
            ),
            (
                "SubtitlePostProcessor chunks limited providers",
                testSubtitlePostProcessorChunksLimitedProviders
            ),
            (
                "SubtitlePostProcessor adaptively splits context errors",
                testSubtitlePostProcessorAdaptivelySplitsContextErrors
            ),
            (
                "SubtitlePostProcessor preserves single unsupported cues",
                testSubtitlePostProcessorPreservesSingleUnsupportedCues
            ),
            ("OCRProfile exposes named profiles", testOCRProfileNames),
            ("OCRProfile unfiltered disables filters", testOCRProfileUnfiltered),
            (
                "Media provider protocols accept stub implementations",
                testMediaProviderProtocolsAcceptStubs
            ),
            ("JobStore saves loads and reuses cues", testJobStoreSavesLoadsAndReusesCues),
            ("JobStore respects disabled resume", testJobStoreRespectsDisabledResume),
            ("JobStore loads contiguous OCR frame records", testJobStoreLoadsContiguousOCRFrames),
        ]

        var failures: [String] = []
        for test in tests {
            do {
                try await test.run()
                print("PASS \(test.name)")
            } catch {
                let failure = "FAIL \(test.name): \(error)"
                failures.append(failure)
                fputs("\(failure)\n", stderr)
            }
        }

        if failures.isEmpty {
            print("All \(tests.count) tests passed.")
        } else {
            fputs("\(failures.count) of \(tests.count) tests failed.\n", stderr)
            Foundation.exit(1)
        }
    }
}

func testParsesItemElements() throws {
    let output = """
        <translations>
          <item index="0">Hello &amp; welcome</item>
          <item index="2">&lt;quiet&gt;</item>
        </translations>
        """

    let parsed = try IndexedTranslationBatchParser.parse(xml: output)

    try expectEqual(parsed, [0: "Hello & welcome", 2: "<quiet>"])
}

func testParsesCDATA() throws {
    let output = #"<item index="4"><![CDATA[Line <one> & line two]]></item>"#

    let parsed = try IndexedTranslationBatchParser.parse(xml: output)

    try expectEqual(parsed[4], "Line <one> & line two")
}

func testParsesIndexedLines() throws {
    let output = """
        0: First line
        1 - Second line
        """

    let parsed = try IndexedTranslationBatchParser.parse(xml: output)

    try expectEqual(parsed, [0: "First line", 1: "Second line"])
}

func testParserThrowsOnInvalidOutput() throws {
    do {
        _ = try IndexedTranslationBatchParser.parse(xml: "nothing useful")
        throw TestFailure(message: "Expected parsing to throw", file: #filePath, line: #line)
    } catch is IndexedTranslationBatchParserError {
        return
    }
}

func testMessageWithoutContext() throws {
    let request = TranslationRequest(text: "Translate me")

    try expectEqual(TranslationMessageFormatting.userMessageText(for: request), "Translate me")
}

func testMessageWithContext() throws {
    let request = TranslationRequest(
        text: "Translate me",
        contextBefore: ["Before one", "Before two"],
        contextAfter: ["After one"]
    )

    let message = TranslationMessageFormatting.userMessageText(for: request)

    try expect(message.contains("[Previous lines"), "Missing previous context marker")
    try expect(message.contains("Before one\nBefore two"), "Missing previous context")
    try expect(
        message.contains("[Translate this line]\nTranslate me"), "Missing translation marker")
    try expect(message.contains("[Following lines"), "Missing following context marker")
    try expect(message.contains("After one"), "Missing following context")
}

func testMessageTruncatesLongText() throws {
    let longText = String(
        repeating: "a", count: TranslationMessageFormatting.maxCharsPerRequest + 20)
    let request = TranslationRequest(text: longText)

    let message = TranslationMessageFormatting.userMessageText(for: request)

    try expectEqual(message.count, TranslationMessageFormatting.maxCharsPerRequest)
}

func testSpeechCueMergerMergesNearbyWords() throws {
    let cues = [
        cue(id: 1, start: 0, end: 300, text: "hello"),
        cue(id: 2, start: 320, end: 620, text: "world"),
    ]

    let merged = SpeechCueMerger(locale: Locale(identifier: "en-US")).merge(cues)

    try expectEqual(merged.count, 1)
    try expectEqual(merged[0].plainText, "hello world")
    try expectEqual(merged[0].startTime, 0)
    try expectEqual(merged[0].endTime, 620)
}

func testSpeechCueMergerSplitsOnPause() throws {
    let cues = [
        cue(id: 1, start: 0, end: 300, text: "first"),
        cue(id: 2, start: 1000, end: 1300, text: "second"),
    ]

    let merged = SpeechCueMerger(locale: Locale(identifier: "en-US"), pauseThresholdMs: 600).merge(
        cues)

    try expectEqual(merged.map(\.plainText), ["first", "second"])
}

func testSpeechCueMergerWrapsLongCue() throws {
    let cues = [
        cue(id: 1, start: 0, end: 100, text: "alpha"),
        cue(id: 2, start: 120, end: 220, text: "beta"),
        cue(id: 3, start: 240, end: 340, text: "gamma"),
        cue(id: 4, start: 360, end: 460, text: "delta"),
    ]

    let merged = SpeechCueMerger(
        locale: Locale(identifier: "en-US"),
        maxCharactersPerCue: 80,
        maxCharactersPerLine: 12
    ).merge(cues)

    try expectEqual(merged.count, 1)
    try expect(merged[0].plainText.contains("\n"), "Expected wrapped plain text")
    try expect(merged[0].rawText.contains("\\N"), "Expected ASS line break in raw text")
}

func testASSMergerAddsStylesAndRenumbers() throws {
    let cues = [
        SubtitleCue(id: 9, startTime: 1000, endTime: 2000, rawText: "Later", plainText: "Later"),
        SubtitleCue(id: 4, startTime: 0, endTime: 500, rawText: "Earlier", plainText: "Earlier"),
    ]

    let subtitle = ASSMerger.merge(cues: cues.sorted { $0.startTime < $1.startTime })

    try expectEqual(subtitle.formatName, "ass")
    try expectEqual(subtitle.cues.map(\.id), [1, 2])
    try expectEqual(subtitle.cues.map(\.plainText), ["Earlier", "Later"])

    let styleNames = subtitle.entries.compactMap { entry -> String? in
        if case .style(let style) = entry {
            return style.name
        }
        return nil
    }
    try expectEqual(styleNames, ["TopOCR", "BottomDialogue"])
}

func testASSMergerLeavesOCRPositioningDisabledByDefault() throws {
    let cue = SubtitleCue(
        id: 1,
        startTime: 0,
        endTime: 500,
        rawText: "sign",
        plainText: "sign",
        attributes: [SubtitleAttribute(key: "Style", value: "TopOCR")]
            + OCRCuePosition.attributes(for: .init(x: 0.25, y: 0.75), fontHeight: 0.05)
    )

    let subtitle = ASSMerger.merge(cues: [cue], playResX: 1280, playResY: 720)

    try expectEqual(subtitle.cues[0].rawText, "sign")
}

func testASSMergerAppliesOCRPositionOverrides() throws {
    let cue = SubtitleCue(
        id: 1,
        startTime: 0,
        endTime: 500,
        rawText: "sign",
        plainText: "sign",
        attributes: [SubtitleAttribute(key: "Style", value: "TopOCR")]
            + OCRCuePosition.attributes(for: .init(x: 0.25, y: 0.75))
    )

    let subtitle = ASSMerger.merge(
        cues: [cue],
        playResX: 1280,
        playResY: 720,
        enableOCRPositioning: true
    )

    try expectEqual(subtitle.cues[0].rawText, "{\\an4\\pos(320,180)}sign")
}

func testASSMergerAppliesRTLOCRPositionOverrides() throws {
    let cue = SubtitleCue(
        id: 1,
        startTime: 0,
        endTime: 500,
        rawText: "sign",
        plainText: "sign",
        attributes: [SubtitleAttribute(key: "Style", value: "TopOCR")]
            + OCRCuePosition.attributes(for: .init(x: 0.75, y: 0.75))
    )

    let subtitle = ASSMerger.merge(
        cues: [cue],
        playResX: 1280,
        playResY: 720,
        enableOCRPositioning: true,
        ocrPositionTextDirection: .rtl
    )

    try expectEqual(subtitle.cues[0].rawText, "{\\an6\\pos(960,180)}sign")
}

func testASSMergerKeepsPositionedOCRAboveOverlappingDialogue() throws {
    let dialogue = SubtitleCue(
        id: 1,
        startTime: 100,
        endTime: 900,
        rawText: "dialogue",
        plainText: "dialogue",
        attributes: [SubtitleAttribute(key: "Style", value: "BottomDialogue")]
    )
    let lowOCR = SubtitleCue(
        id: 2,
        startTime: 0,
        endTime: 500,
        rawText: "lower sign",
        plainText: "lower sign",
        attributes: [SubtitleAttribute(key: "Style", value: "TopOCR")]
            + OCRCuePosition.attributes(for: .init(x: 0.25, y: 0.05))
    )

    let subtitle = ASSMerger.merge(
        cues: [lowOCR, dialogue],
        playResX: 1280,
        playResY: 720,
        enableOCRPositioning: true
    )

    try expectEqual(subtitle.cues[0].rawText, "{\\an4\\pos(320,605)}lower sign")
}

func testASSMergerLanesPositionedOCRAboveOverlappingDialogue() throws {
    let dialogue = SubtitleCue(
        id: 1,
        startTime: 100,
        endTime: 900,
        rawText: "dialogue",
        plainText: "dialogue",
        attributes: [SubtitleAttribute(key: "Style", value: "BottomDialogue")]
    )
    let lowerOCR = SubtitleCue(
        id: 2,
        startTime: 0,
        endTime: 500,
        rawText: "lower sign",
        plainText: "lower sign",
        attributes: [SubtitleAttribute(key: "Style", value: "TopOCR")]
            + OCRCuePosition.attributes(for: .init(x: 0.25, y: 0.05))
    )
    let upperOCR = SubtitleCue(
        id: 3,
        startTime: 0,
        endTime: 500,
        rawText: "upper sign",
        plainText: "upper sign",
        attributes: [SubtitleAttribute(key: "Style", value: "TopOCR")]
            + OCRCuePosition.attributes(for: .init(x: 0.25, y: 0.07))
    )

    let subtitle = ASSMerger.merge(
        cues: [lowerOCR, upperOCR, dialogue],
        playResX: 1280,
        playResY: 720,
        enableOCRPositioning: true
    )

    try expectEqual(subtitle.cues[0].rawText, "{\\an4\\pos(320,605)}lower sign")
    try expectEqual(subtitle.cues[1].rawText, "{\\an4\\pos(320,576)}upper sign")
}

func testASSMergerAppliesClampedOCRFontOverrides() throws {
    let small = SubtitleCue(
        id: 1,
        startTime: 0,
        endTime: 500,
        rawText: "small",
        plainText: "small",
        attributes: [SubtitleAttribute(key: "Style", value: "TopOCR")]
            + OCRCuePosition.attributes(for: .init(x: 0.25, y: 0.75), fontHeight: 0.01)
    )
    let large = SubtitleCue(
        id: 2,
        startTime: 0,
        endTime: 500,
        rawText: "large",
        plainText: "large",
        attributes: [SubtitleAttribute(key: "Style", value: "TopOCR")]
            + OCRCuePosition.attributes(for: .init(x: 0.75, y: 0.25), fontHeight: 0.20)
    )

    let subtitle = ASSMerger.merge(
        cues: [small, large],
        playResX: 1280,
        playResY: 720,
        enableOCRPositioning: true
    )

    try expectEqual(subtitle.cues[0].rawText, "{\\an4\\fs34\\pos(320,180)}small")
    try expectEqual(subtitle.cues[1].rawText, "{\\an4\\fs64\\pos(960,540)}large")
}

func testOCRCuePositionDerivesNormalizedCenter() throws {
    let observations = [
        ocrObservation(text: "Top", x: 0.20, y: 0.70, width: 0.20, height: 0.10),
        ocrObservation(text: "Bottom", x: 0.30, y: 0.50, width: 0.40, height: 0.10),
    ]

    let center = try require(
        OCRCuePosition.normalizedCenter(for: observations), "Missing OCR center")

    try expectEqual(String(format: "%.2f", center.x), "0.45")
    try expectEqual(String(format: "%.2f", center.y), "0.65")
}

func testOCRCuePositionDerivesDirectionalAnchors() throws {
    let observations = [
        ocrObservation(text: "Top", x: 0.20, y: 0.70, width: 0.20, height: 0.10),
        ocrObservation(text: "Bottom", x: 0.30, y: 0.50, width: 0.40, height: 0.10),
    ]

    let ltr = try require(
        OCRCuePosition.normalizedAnchor(for: observations, textDirection: .ltr),
        "Missing LTR OCR anchor"
    )
    let rtl = try require(
        OCRCuePosition.normalizedAnchor(for: observations, textDirection: .rtl),
        "Missing RTL OCR anchor"
    )

    try expectEqual(String(format: "%.2f", ltr.x), "0.20")
    try expectEqual(String(format: "%.2f", ltr.y), "0.65")
    try expectEqual(String(format: "%.2f", rtl.x), "0.70")
    try expectEqual(String(format: "%.2f", rtl.y), "0.65")
}

func testOCRCuePositionDoesNotMatchMissingPositionToPresentPosition() throws {
    let positioned = OCRCuePosition.Normalized(x: 0.25, y: 0.75)

    try expect(OCRCuePosition.isNear(nil, nil), "Missing positions should match each other")
    try expect(
        !OCRCuePosition.isNear(nil, positioned), "Missing position should not match placed text")
    try expect(
        !OCRCuePosition.isNear(positioned, nil), "Placed text should not match missing position")
}

func testPostProcessingPromptIncludesKoreanShowGuidance() throws {
    let prompt = PostProcessingPrompt.systemPrompt(
        locale: Locale(identifier: "ko-KR"), profile: .openAI)
    let applePrompt = PostProcessingPrompt.systemPrompt(
        locale: Locale(identifier: "ko-KR"), profile: .appleIntelligence)

    try expect(prompt.contains("Korean shows"), "Expected Korean show subtitle guidance")
    try expect(prompt.contains("never more than two visual lines"), "Expected line-count guidance")
    try expect(prompt.contains("parentheses"), "Expected parenthetical on-screen text guidance")
    try expect(prompt.contains("not scene summarization"), "Expected anti-summarization guidance")
    try expect(prompt.contains("discern what should become the final subtitles"), "Expected final-subtitle selection guidance")
    try expect(
        prompt.contains("two imperfect signals"),
        "Expected dialogue/OCR cross-source disambiguation guidance")
    try expect(
        prompt.contains("correct or disambiguate likely recognition errors"),
        "Expected recognition error repair guidance")
    try expect(
        prompt.contains("preserve the on-screen text, rewrite it for readability, or distill"),
        "Expected on-screen text preserve/rewrite/distill guidance")
    try expect(
        prompt.contains("decide whether it belongs in the final subtitle track"),
        "Expected dialogue selection guidance")
    try expect(
        prompt.contains("You may drop dialogue"),
        "Expected dialogue dropping guidance")
    try expect(
        prompt.contains("must be wrapped in parentheses"),
        "Expected parenthesized on-screen text contract")
    try expect(
        prompt.contains("Avoid overly sparse output"),
        "Expected density guardrail")
    try expect(
        applePrompt.count < prompt.count, "Expected Apple Intelligence prompt to be more compact")
}

func testPostProcessingResponseParserParsesObject() throws {
    let output = """
        ```json
        {"cues":[{"startTime":100,"endTime":900,"text":"Keep me"}]}
        ```
        """

    let parsed = try PostProcessingResponseParser.parse(output)

    try expectEqual(parsed, [PostProcessedCue(startTime: 100, endTime: 900, text: "Keep me")])
}

func testPostProcessingResponseParserExtractsWrappedJSON() throws {
    let output = """
        Here is the cleaned subtitle track:

        {"subtitles":[{"start_ms":1200,"end_ms":1800,"text":"Door code"}]}

        Done.
        """

    let parsed = try PostProcessingResponseParser.parse(output)

    try expectEqual(parsed, [PostProcessedCue(startTime: 1200, endTime: 1800, text: "Door code")])
}

func testPostProcessingResponseParserExtractsFencedArray() throws {
    let output = """
        ```json
        [{"startTime":8280,"endTime":8333,"text":"이렇게 스톱으로 갈 거야."}]
        ```
        """

    let parsed = try PostProcessingResponseParser.parse(output)

    try expectEqual(
        parsed,
        [PostProcessedCue(startTime: 8280, endTime: 8333, text: "이렇게 스톱으로 갈 거야.")]
    )
}

func testPostProcessingResponseParserAcceptsAlternateTimingFields() throws {
    let output = """
        {"cues":[
          {"start":"00:01.500","end":"00:02.750","line":"(caption: shocked)"},
          {"begin":3.0,"stop":4.25,"subtitle":"Let's go"}
        ]}
        """

    let parsed = try PostProcessingResponseParser.parse(output)

    try expectEqual(
        parsed,
        [
            PostProcessedCue(startTime: 1500, endTime: 2750, text: "(caption: shocked)"),
            PostProcessedCue(startTime: 3000, endTime: 4250, text: "Let's go"),
        ]
    )
}

func testPostProcessingResponseParserInfersMissingEndTimes() throws {
    let output = """
        [{"startTime":89333,"text":"시민과 함께, 자유로운 혁신"},{"startTime":90000,"text":"시민고 자유로"}]
        """

    let parsed = try PostProcessingResponseParser.parse(output)

    try expectEqual(
        parsed,
        [
            PostProcessedCue(startTime: 89333, endTime: 90000, text: "시민과 함께, 자유로운 혁신"),
            PostProcessedCue(startTime: 90000, endTime: 92000, text: "시민고 자유로"),
        ]
    )
}

func testSubtitlePostProcessorReturnsBottomDialogueCues() async throws {
    let cues = [
        SubtitleCue(
            id: 1,
            startTime: 0,
            endTime: 500,
            rawText: "Hello",
            plainText: "Hello",
            attributes: [SubtitleAttribute(key: "Style", value: "BottomDialogue")]
        ),
        SubtitleCue(
            id: 2,
            startTime: 100,
            endTime: 600,
            rawText: "Hello",
            plainText: "Hello",
            attributes: [SubtitleAttribute(key: "Style", value: "TopOCR")]
        ),
    ]
    let provider = StubPostProcessingProvider(
        outputs: [PostProcessedCue(startTime: 0, endTime: 600, text: "Hello")]
    )

    let processed = try await SubtitlePostProcessor(provider: provider).postProcess(cues)

    try expectEqual(processed.count, 1)
    try expectEqual(processed[0].plainText, "Hello")
    try expectEqual(processed[0].startTime, 0)
    try expectEqual(processed[0].endTime, 600)
    try expect(
        processed[0].attributes.contains { $0.key == "Style" && $0.value == "BottomDialogue" },
        "Expected post-processed cues to use bottom dialogue style"
    )
}

func testSubtitlePostProcessorPassesCueRoleAndOverlapContext() async throws {
    let cues = [
        SubtitleCue(
            id: 1,
            startTime: 0,
            endTime: 800,
            rawText: "Wait",
            plainText: "Wait",
            attributes: [SubtitleAttribute(key: "Style", value: "BottomDialogue")]
        ),
        SubtitleCue(
            id: 2,
            startTime: 250,
            endTime: 700,
            rawText: "Warning",
            plainText: "Warning",
            attributes: [SubtitleAttribute(key: "Style", value: "TopOCR")]
        ),
        SubtitleCue(
            id: 3,
            startTime: 900,
            endTime: 1200,
            rawText: "mystery",
            plainText: "mystery",
            attributes: []
        ),
    ]
    let recorder = PostProcessingBatchRecorder()
    let provider = ContextRecordingPostProcessingProvider(recorder: recorder)

    _ = try await SubtitlePostProcessor(provider: provider).postProcess(cues)
    let batches = await recorder.batches()

    try expectEqual(batches.count, 1)
    try expectEqual(batches[0].context.dialogueIndexes, [0])
    try expectEqual(batches[0].context.onScreenIndexes, [1])
    try expectEqual(batches[0].context.unknownIndexes, [2])
    try expectEqual(
        batches[0].context.overlaps,
        [
            PostProcessingCueOverlap(index: 0, overlaps: [1]),
            PostProcessingCueOverlap(index: 1, overlaps: [0]),
        ]
    )
    try expectEqual(batches[0].cues.map(\.kind), [.dialogue, .onScreen, .unknown])
}

func testSubtitlePostProcessorChunksLimitedProviders() async throws {
    let cues = (0..<6).map { index in
        SubtitleCue(
            id: index + 1,
            startTime: index * 1_000,
            endTime: index * 1_000 + 500,
            rawText: "Line \(index) \(String(repeating: "x", count: 40))",
            plainText: "Line \(index) \(String(repeating: "x", count: 40))",
            attributes: [SubtitleAttribute(key: "Style", value: "BottomDialogue")]
        )
    }
    let recorder = PostProcessingBatchRecorder()
    let provider = ChunkingStubPostProcessingProvider(maxPromptCharacters: 240, recorder: recorder)

    let processed = try await SubtitlePostProcessor(provider: provider).postProcess(cues)
    let batchSizes = await recorder.batchSizes()

    try expect(batchSizes.count > 1, "Expected provider calls to be split into multiple windows")
    try expectEqual(batchSizes.reduce(0, +), 6)
    try expectEqual(processed.count, 6)
}

func testSubtitlePostProcessorAdaptivelySplitsContextErrors() async throws {
    let cues = (0..<4).map { index in
        SubtitleCue(
            id: index + 1,
            startTime: index * 1_000,
            endTime: index * 1_000 + 500,
            rawText: "Line \(index)",
            plainText: "Line \(index)",
            attributes: [SubtitleAttribute(key: "Style", value: "BottomDialogue")]
        )
    }
    let recorder = PostProcessingBatchRecorder()
    let provider = ContextFailingPostProcessingProvider(recorder: recorder)

    let processed = try await SubtitlePostProcessor(provider: provider).postProcess(cues)
    let batchSizes = await recorder.batchSizes()

    try expectEqual(batchSizes, [4, 2, 2])
    try expectEqual(processed.map(\.plainText), ["Line 0", "Line 1", "Line 2", "Line 3"])
}

func testSubtitlePostProcessorPreservesSingleUnsupportedCues() async throws {
    let cues = [
        SubtitleCue(
            id: 1,
            startTime: 0,
            endTime: 500,
            rawText: "문",
            plainText: "문",
            attributes: [SubtitleAttribute(key: "Style", value: "TopOCR")]
        )
    ]
    let provider = UnsupportedLanguagePostProcessingProvider()

    let processed = try await SubtitlePostProcessor(provider: provider).postProcess(cues)

    try expectEqual(processed.count, 1)
    try expectEqual(processed[0].plainText, "문")
    try expectEqual(processed[0].startTime, 0)
    try expectEqual(processed[0].endTime, 500)
}

func testOCRProfileNames() throws {
    try expect(OCRProfile.named("default") != nil, "Missing default profile")
    try expect(OCRProfile.named("unfiltered") != nil, "Missing unfiltered profile")
    try expect(OCRProfile.named("missing") == nil, "Unexpected missing profile")
}

func testOCRProfileUnfiltered() throws {
    let profile = OCRProfile.unfiltered

    try expect(!profile.filterLogoRegions, "Unfiltered profile should disable logo filtering")
    try expect(
        !profile.skipSimilarFrames, "Unfiltered profile should disable similar-frame skipping")
}

func testMediaProviderProtocolsAcceptStubs() async throws {
    let expectedSpeech = [cue(id: 1, start: 0, end: 500, text: "hello")]
    let speech: any VideoSpeechTranscribing = StubSpeechTranscriber(cues: expectedSpeech)

    let speechCues = try await speech.transcribe(videoURL: URL(fileURLWithPath: "/tmp/input.mp4"))

    try expectEqual(speechCues, expectedSpeech)

    let expectedOCR = [cue(id: 2, start: 500, end: 1000, text: "sign")]
    let frameRecord = OCRFrameRecord(
        index: 0,
        sampleTimeSeconds: 0,
        recognizedText: "sign",
        observations: nil,
        reusedPreviousText: false,
        fingerprint: nil
    )
    let ocr: any VideoOCRProcessing = StubOCRProcessor(cues: expectedOCR, records: [frameRecord])
    let recorder = PersistedOCRFrameRecorder()

    let ocrCues = try await ocr.extractText(
        videoURL: URL(fileURLWithPath: "/tmp/input.mp4"),
        locale: Locale(identifier: "en-US"),
        fps: 3,
        profile: .default,
        existingFrameRecords: [],
        persistRecords: { records in
            await recorder.save(records)
        }
    )

    try expectEqual(ocrCues, expectedOCR)
    try await expectEqual(recorder.recognizedTexts(), ["sign"])
}

func testJobStoreSavesLoadsAndReusesCues() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let input = root.appendingPathComponent("input.mp4")
    try Data("video".utf8).write(to: input)

    let key = "speech-key"
    let store = try JobStore(inputURL: input, workDirOverride: root.path, resumeEnabled: true)
    try await store.prepareWorkspace()
    let cues = [
        SubtitleCue(id: 1, startTime: 0, endTime: 500, rawText: "Hello", plainText: "Hello")
    ]

    try await store.saveCues(
        cues, stage: .speech, key: key, artifactName: StageArtifacts.speechCues)

    let canReuse = await store.canReuse(stage: .speech, key: key)
    try expect(canReuse, "Expected saved cues to be reusable")
    let loaded = try await store.loadCues(stage: .speech)
    try expectEqual(loaded, cues)
}

func testJobStoreRespectsDisabledResume() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let input = root.appendingPathComponent("input.mp4")
    try Data("video".utf8).write(to: input)

    let key = "speech-key"
    let first = try JobStore(inputURL: input, workDirOverride: root.path, resumeEnabled: true)
    try await first.prepareWorkspace()
    try await first.saveCues(
        [SubtitleCue(id: 1, startTime: 0, endTime: 500, rawText: "Hello", plainText: "Hello")],
        stage: .speech,
        key: key,
        artifactName: StageArtifacts.speechCues
    )

    let second = try JobStore(inputURL: input, workDirOverride: root.path, resumeEnabled: false)
    try await second.prepareWorkspace()

    let canReuse = await second.canReuse(stage: .speech, key: key)
    try expect(!canReuse, "Expected disabled resume to prevent reuse")
}

func testJobStoreLoadsContiguousOCRFrames() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let input = root.appendingPathComponent("input.mp4")
    try Data("video".utf8).write(to: input)

    let store = try JobStore(inputURL: input, workDirOverride: root.path, resumeEnabled: true)
    try await store.prepareWorkspace()
    try await store.appendOCRFrameRecords(
        [
            OCRFrameRecord(
                index: 0,
                sampleTimeSeconds: 0,
                recognizedText: "zero",
                observations: nil,
                reusedPreviousText: false,
                fingerprint: nil
            ),
            OCRFrameRecord(
                index: 2,
                sampleTimeSeconds: 2,
                recognizedText: "two",
                observations: nil,
                reusedPreviousText: false,
                fingerprint: nil
            ),
        ],
        stageKey: "ocr-key",
        framesKey: "frames-key",
        totalFrameCount: 3
    )

    let records = try await store.loadOCRFrameRecords(framesKey: "frames-key")

    try expectEqual(records.map(\.index), [0])
}

func cue(id: Int, start: Int, end: Int, text: String) -> SubtitleCue {
    SubtitleCue(id: id, startTime: start, endTime: end, rawText: text, plainText: text)
}

func ocrObservation(
    text: String,
    x: Double,
    y: Double,
    width: Double,
    height: Double
) -> OCRTextObservation {
    OCRTextObservation(
        text: text,
        boundingBoxX: x,
        boundingBoxY: y,
        boundingBoxWidth: width,
        boundingBoxHeight: height,
        topLeftX: nil,
        topLeftY: nil,
        topRightX: nil,
        topRightY: nil,
        bottomLeftX: nil,
        bottomLeftY: nil,
        bottomRightX: nil,
        bottomRightY: nil
    )
}

private struct StubSpeechTranscriber: VideoSpeechTranscribing {
    let cues: [SubtitleCue]

    func transcribe(videoURL: URL) async throws -> [SubtitleCue] {
        cues
    }
}

private struct StubOCRProcessor: VideoOCRProcessing {
    let cues: [SubtitleCue]
    let records: [OCRFrameRecord]

    func extractText(
        videoURL: URL,
        locale: Locale,
        fps: Int,
        profile: OCRProfile,
        existingFrameRecords: [OCRFrameRecord],
        persistRecords: OCRFrameRecordPersistence?
    ) async throws -> [SubtitleCue] {
        if let persistRecords {
            try await persistRecords(records)
        }
        return cues
    }
}

private struct StubPostProcessingProvider: SubtitlePostProcessingProvider {
    static let id = "stub"
    static let displayName = "Stub"

    let outputs: [PostProcessedCue]

    func estimateCost(for batch: PostProcessingInputBatch) -> TranslationCostEstimate {
        TranslationCostEstimate(estimatedUSD: 0, lines: [])
    }

    func postProcess(_ batch: PostProcessingInputBatch) async throws -> [PostProcessedCue] {
        outputs
    }
}

private struct ContextRecordingPostProcessingProvider: SubtitlePostProcessingProvider {
    static let id = "context-recording-stub"
    static let displayName = "Context Recording Stub"

    let recorder: PostProcessingBatchRecorder

    func estimateCost(for batch: PostProcessingInputBatch) -> TranslationCostEstimate {
        TranslationCostEstimate(estimatedUSD: 0, lines: [])
    }

    func postProcess(_ batch: PostProcessingInputBatch) async throws -> [PostProcessedCue] {
        await recorder.record(batch)
        return batch.cues.map { cue in
            PostProcessedCue(startTime: cue.startTime, endTime: cue.endTime, text: cue.text)
        }
    }
}

private struct ChunkingStubPostProcessingProvider: SubtitlePostProcessingProvider {
    static let id = "chunking-stub"
    static let displayName = "Chunking Stub"

    let maxPromptCharacters: Int?
    let recorder: PostProcessingBatchRecorder

    func estimateCost(for batch: PostProcessingInputBatch) -> TranslationCostEstimate {
        TranslationCostEstimate(estimatedUSD: 0, lines: [])
    }

    func postProcess(_ batch: PostProcessingInputBatch) async throws -> [PostProcessedCue] {
        await recorder.record(batch.cues.count)
        return batch.cues.map { cue in
            PostProcessedCue(startTime: cue.startTime, endTime: cue.endTime, text: cue.text)
        }
    }
}

private struct ContextFailingPostProcessingProvider: SubtitlePostProcessingProvider {
    static let id = "context-failing-stub"
    static let displayName = "Context Failing Stub"

    let recorder: PostProcessingBatchRecorder

    func estimateCost(for batch: PostProcessingInputBatch) -> TranslationCostEstimate {
        TranslationCostEstimate(estimatedUSD: 0, lines: [])
    }

    func postProcess(_ batch: PostProcessingInputBatch) async throws -> [PostProcessedCue] {
        await recorder.record(batch.cues.count)
        if batch.cues.count > 2 {
            throw PostProcessingError.contextWindowExceeded
        }
        return batch.cues.map { cue in
            PostProcessedCue(startTime: cue.startTime, endTime: cue.endTime, text: cue.text)
        }
    }
}

private struct UnsupportedLanguagePostProcessingProvider: SubtitlePostProcessingProvider {
    static let id = "unsupported-language-stub"
    static let displayName = "Unsupported Language Stub"

    func estimateCost(for batch: PostProcessingInputBatch) -> TranslationCostEstimate {
        TranslationCostEstimate(estimatedUSD: 0, lines: [])
    }

    func postProcess(_ batch: PostProcessingInputBatch) async throws -> [PostProcessedCue] {
        throw PostProcessingError.unsupportedLanguageOrLocale
    }
}

private actor PostProcessingBatchRecorder {
    private var sizes: [Int] = []
    private var recordedBatches: [PostProcessingInputBatch] = []

    func record(_ size: Int) {
        sizes.append(size)
    }

    func record(_ batch: PostProcessingInputBatch) {
        recordedBatches.append(batch)
    }

    func batchSizes() -> [Int] {
        sizes
    }

    func batches() -> [PostProcessingInputBatch] {
        recordedBatches
    }
}

private actor PersistedOCRFrameRecorder {
    private var records: [OCRFrameRecord] = []

    func save(_ records: [OCRFrameRecord]) {
        self.records = records
    }

    func recognizedTexts() -> [String] {
        records.map(\.recognizedText)
    }
}

func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("KShowSubCoreTestRunner-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
