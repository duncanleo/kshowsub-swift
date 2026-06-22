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
    try expect(actual == expected, "Expected \(actual) to equal \(expected)", file: file, line: line)
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
            ("IndexedTranslationBatchParser throws on invalid output", testParserThrowsOnInvalidOutput),
            ("TranslationMessageFormatting returns raw text without context", testMessageWithoutContext),
            ("TranslationMessageFormatting includes context markers", testMessageWithContext),
            ("TranslationMessageFormatting truncates long text", testMessageTruncatesLongText),
            ("SpeechCueMerger merges nearby words", testSpeechCueMergerMergesNearbyWords),
            ("SpeechCueMerger splits on pause", testSpeechCueMergerSplitsOnPause),
            ("SpeechCueMerger wraps long cues", testSpeechCueMergerWrapsLongCue),
            ("ASSMerger adds styles and renumbers cues", testASSMergerAddsStylesAndRenumbers),
            ("ASSMerger leaves OCR positioning disabled by default", testASSMergerLeavesOCRPositioningDisabledByDefault),
            ("ASSMerger applies OCR position overrides", testASSMergerAppliesOCRPositionOverrides),
            ("ASSMerger applies clamped OCR font overrides", testASSMergerAppliesClampedOCRFontOverrides),
            ("OCRCuePosition derives normalized center", testOCRCuePositionDerivesNormalizedCenter),
            ("OCRCuePosition does not match missing position to present position", testOCRCuePositionDoesNotMatchMissingPositionToPresentPosition),
            ("OCRProfile exposes named profiles", testOCRProfileNames),
            ("OCRProfile unfiltered disables filters", testOCRProfileUnfiltered),
            ("Media provider protocols accept stub implementations", testMediaProviderProtocolsAcceptStubs),
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
    try expect(message.contains("[Translate this line]\nTranslate me"), "Missing translation marker")
    try expect(message.contains("[Following lines"), "Missing following context marker")
    try expect(message.contains("After one"), "Missing following context")
}

func testMessageTruncatesLongText() throws {
    let longText = String(repeating: "a", count: TranslationMessageFormatting.maxCharsPerRequest + 20)
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

    let merged = SpeechCueMerger(locale: Locale(identifier: "en-US"), pauseThresholdMs: 600).merge(cues)

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

    try expectEqual(subtitle.cues[0].rawText, "{\\an5\\pos(320,180)}sign")
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

    try expectEqual(subtitle.cues[0].rawText, "{\\an5\\fs34\\pos(320,180)}small")
    try expectEqual(subtitle.cues[1].rawText, "{\\an5\\fs64\\pos(960,540)}large")
}

func testOCRCuePositionDerivesNormalizedCenter() throws {
    let observations = [
        ocrObservation(text: "Top", x: 0.20, y: 0.70, width: 0.20, height: 0.10),
        ocrObservation(text: "Bottom", x: 0.30, y: 0.50, width: 0.40, height: 0.10),
    ]

    let center = try require(OCRCuePosition.normalizedCenter(for: observations), "Missing OCR center")

    try expectEqual(String(format: "%.2f", center.x), "0.45")
    try expectEqual(String(format: "%.2f", center.y), "0.65")
}

func testOCRCuePositionDoesNotMatchMissingPositionToPresentPosition() throws {
    let positioned = OCRCuePosition.Normalized(x: 0.25, y: 0.75)

    try expect(OCRCuePosition.isNear(nil, nil), "Missing positions should match each other")
    try expect(!OCRCuePosition.isNear(nil, positioned), "Missing position should not match placed text")
    try expect(!OCRCuePosition.isNear(positioned, nil), "Placed text should not match missing position")
}

func testOCRProfileNames() throws {
    try expect(OCRProfile.named("default") != nil, "Missing default profile")
    try expect(OCRProfile.named("unfiltered") != nil, "Missing unfiltered profile")
    try expect(OCRProfile.named("missing") == nil, "Unexpected missing profile")
}

func testOCRProfileUnfiltered() throws {
    let profile = OCRProfile.unfiltered

    try expect(!profile.filterLogoRegions, "Unfiltered profile should disable logo filtering")
    try expect(!profile.skipSimilarFrames, "Unfiltered profile should disable similar-frame skipping")
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

    try await store.saveCues(cues, stage: .speech, key: key, artifactName: StageArtifacts.speechCues)

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
