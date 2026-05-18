import CryptoKit
import Foundation
import SubtitleKit

public enum PipelineStage: String, Codable, CaseIterable {
    case speech
    case ocr
    case merge
    case postProcess = "post_process"
    case translation
}

enum StageStatus: String, Codable {
    case notStarted = "not_started"
    case running
    case completed
    case failed
}

struct PersistedCue: Codable {
    let id: Int
    let startTime: Int
    let endTime: Int
    let rawText: String
    let plainText: String
    let attributes: [PersistedSubtitleAttribute]

    init(_ cue: SubtitleCue) {
        id = cue.id
        startTime = cue.startTime
        endTime = cue.endTime
        rawText = cue.rawText
        plainText = cue.plainText
        attributes = cue.attributes.map(PersistedSubtitleAttribute.init)
    }

    func toSubtitleCue() -> SubtitleCue {
        SubtitleCue(
            id: id,
            startTime: startTime,
            endTime: endTime,
            rawText: rawText,
            plainText: plainText,
            attributes: attributes.map { $0.toSubtitleAttribute() }
        )
    }
}

struct PersistedSubtitleAttribute: Codable {
    let key: String
    let value: String

    init(_ attribute: SubtitleAttribute) {
        key = attribute.key
        value = attribute.value
    }

    func toSubtitleAttribute() -> SubtitleAttribute {
        SubtitleAttribute(key: key, value: value)
    }
}

public struct OCRTextObservation: Codable, Sendable {
    let text: String
    let boundingBoxX: Double
    let boundingBoxY: Double
    let boundingBoxWidth: Double
    let boundingBoxHeight: Double
    let topLeftX: Double?
    let topLeftY: Double?
    let topRightX: Double?
    let topRightY: Double?
    let bottomLeftX: Double?
    let bottomLeftY: Double?
    let bottomRightX: Double?
    let bottomRightY: Double?
}

public struct OCRFrameRecord: Codable, Sendable {
    let index: Int
    let sampleTimeSeconds: Double
    let recognizedText: String
    let observations: [OCRTextObservation]?
    let reusedPreviousText: Bool
    let fingerprint: [UInt8]?
}

struct StageRecord: Codable {
    var status: StageStatus
    var key: String?
    var artifactPath: String?
    var errorMessage: String?
    var metadata: [String: String]
    var updatedAt: Date

    init() {
        status = .notStarted
        key = nil
        artifactPath = nil
        errorMessage = nil
        metadata = [:]
        updatedAt = Date()
    }
}

struct JobManifest: Codable {
    let schemaVersion: Int
    let inputFingerprint: InputFingerprint
    var stages: [String: StageRecord]
    var updatedAt: Date

    init(inputFingerprint: InputFingerprint) {
        schemaVersion = 1
        self.inputFingerprint = inputFingerprint
        stages = Dictionary(
            uniqueKeysWithValues: PipelineStage.allCases.map { ($0.rawValue, StageRecord()) })
        updatedAt = Date()
    }
}

struct InputFingerprint: Codable {
    let path: String
    let fileSize: UInt64
    let modificationTimeIntervalSince1970: TimeInterval
}

public struct StageArtifacts {
    public static let speechCues = "speech-cues.json"
    public static let ocrFrames = "ocr-frames.jsonl"
    public static let ocrCues = "ocr-cues.json"
    public static let mergedCues = "merged-cues.json"
    public static let postProcessedCues = "post-processed-cues.json"
    public static let translatedCues = "translated-cues.json"
}

public actor JobStore {
    private let fileManager = FileManager.default
    private let workspaceURL: URL
    private let manifestURL: URL
    private let encoder: JSONEncoder
    private let jsonlEncoder: JSONEncoder  // compact encoder for JSONL frame records
    private let decoder: JSONDecoder
    private var manifest: JobManifest
    private let resumeEnabled: Bool

    public init(inputURL: URL, workDirOverride: String?, resumeEnabled: Bool) throws {
        self.resumeEnabled = resumeEnabled
        let fingerprint = try Self.makeInputFingerprint(for: inputURL)
        let inputKey = Self.hashString(
            "\(fingerprint.path)|\(fingerprint.fileSize)|\(fingerprint.modificationTimeIntervalSince1970)"
        )
        let rootURL: URL
        if let workDirOverride, !workDirOverride.isEmpty {
            rootURL = URL(fileURLWithPath: workDirOverride, isDirectory: true)
        } else {
            let appSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            rootURL =
                appSupport
                .appendingPathComponent("KShowSub", isDirectory: true)
                .appendingPathComponent("jobs", isDirectory: true)
        }
        workspaceURL = rootURL.appendingPathComponent(inputKey, isDirectory: true)
        manifestURL = workspaceURL.appendingPathComponent("manifest.json", isDirectory: false)

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        jsonlEncoder = JSONEncoder()  // no prettyPrinted — each record must be a single line
        jsonlEncoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if resumeEnabled,
            let data = try? Data(contentsOf: manifestURL),
            let loaded = try? decoder.decode(JobManifest.self, from: data),
            loaded.inputFingerprint.path == fingerprint.path,
            loaded.inputFingerprint.fileSize == fingerprint.fileSize,
            loaded.inputFingerprint.modificationTimeIntervalSince1970
                == fingerprint.modificationTimeIntervalSince1970
        {
            manifest = loaded
        } else {
            manifest = JobManifest(inputFingerprint: fingerprint)
        }
    }

    public func prepareWorkspace() throws {
        try fileManager.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try saveManifest()
    }

    public func workspacePath() -> String {
        workspaceURL.path
    }

    public func canReuse(stage: PipelineStage, key: String) -> Bool {
        guard resumeEnabled, let record = manifest.stages[stage.rawValue] else { return false }
        return record.status == .completed && record.key == key && artifactExists(for: record)
    }

    public func loadCues(stage: PipelineStage) throws -> [SubtitleCue]? {
        guard let record = manifest.stages[stage.rawValue],
            let relativePath = record.artifactPath
        else { return nil }
        let url = workspaceURL.appendingPathComponent(relativePath, isDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let persisted = try decoder.decode([PersistedCue].self, from: data)
        return persisted.map { $0.toSubtitleCue() }
    }

    public func saveCues(
        _ cues: [SubtitleCue], stage: PipelineStage, key: String, artifactName: String
    ) throws {
        let relativePath = artifactName
        let url = workspaceURL.appendingPathComponent(relativePath, isDirectory: false)
        let payload = cues.map(PersistedCue.init)
        let data = try encoder.encode(payload)
        try atomicWrite(data: data, to: url)

        var record = manifest.stages[stage.rawValue] ?? StageRecord()
        record.status = .completed
        record.key = key
        record.artifactPath = relativePath
        record.errorMessage = nil
        record.updatedAt = Date()
        manifest.stages[stage.rawValue] = record
        manifest.updatedAt = Date()
        try saveManifest()
    }

    public func markStageRunning(
        _ stage: PipelineStage,
        key: String,
        metadata: [String: String] = [:],
        resetArtifacts: [String] = []
    ) throws {
        for artifact in resetArtifacts {
            let url = workspaceURL.appendingPathComponent(artifact, isDirectory: false)
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
        }
        var record = manifest.stages[stage.rawValue] ?? StageRecord()
        record.status = .running
        record.key = key
        record.errorMessage = nil
        record.metadata = metadata
        record.updatedAt = Date()
        manifest.stages[stage.rawValue] = record
        manifest.updatedAt = Date()
        try saveManifest()
    }

    public func markStageFailed(_ stage: PipelineStage, key: String, error: Error) throws {
        var record = manifest.stages[stage.rawValue] ?? StageRecord()
        record.status = .failed
        record.key = key
        record.errorMessage = error.localizedDescription
        record.updatedAt = Date()
        manifest.stages[stage.rawValue] = record
        manifest.updatedAt = Date()
        try saveManifest()
    }

    public func loadOCRFrameRecords(framesKey: String) throws -> [OCRFrameRecord] {
        guard resumeEnabled,
            let record = manifest.stages[PipelineStage.ocr.rawValue],
            record.metadata["framesKey"] == framesKey
        else { return [] }
        let url = workspaceURL.appendingPathComponent(StageArtifacts.ocrFrames, isDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else { return [] }

        let data = try Data(contentsOf: url)
        guard let content = String(data: data, encoding: .utf8), !content.isEmpty else { return [] }

        var recordsByIndex: [Int: OCRFrameRecord] = [:]
        for line in content.split(whereSeparator: \.isNewline) {
            guard let lineData = String(line).data(using: .utf8),
                let record = try? decoder.decode(OCRFrameRecord.self, from: lineData)
            else { continue }
            recordsByIndex[record.index] = record
        }

        var contiguous: [OCRFrameRecord] = []
        var index = 0
        while let record = recordsByIndex[index] {
            contiguous.append(record)
            index += 1
        }
        return contiguous
    }

    public func appendOCRFrameRecords(
        _ records: [OCRFrameRecord], stageKey: String, framesKey: String, totalFrameCount: Int
    ) throws {
        guard !records.isEmpty else { return }
        let url = workspaceURL.appendingPathComponent(StageArtifacts.ocrFrames, isDirectory: false)
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()

        for record in records {
            let lineData = try jsonlEncoder.encode(record)
            try handle.write(contentsOf: lineData)
            try handle.write(contentsOf: Data([0x0A]))
        }

        var stage = manifest.stages[PipelineStage.ocr.rawValue] ?? StageRecord()
        stage.status = .running
        stage.key = stageKey
        stage.metadata["framesKey"] = framesKey
        stage.metadata["frameCount"] = String(totalFrameCount)
        stage.metadata["completedFrameCount"] = String((records.last?.index ?? -1) + 1)
        stage.updatedAt = Date()
        manifest.stages[PipelineStage.ocr.rawValue] = stage
        manifest.updatedAt = Date()
        try saveManifest()
    }

    private func artifactExists(for record: StageRecord) -> Bool {
        guard let relativePath = record.artifactPath else { return false }
        return fileManager.fileExists(
            atPath: workspaceURL.appendingPathComponent(relativePath, isDirectory: false).path)
    }

    private func saveManifest() throws {
        let data = try encoder.encode(manifest)
        try atomicWrite(data: data, to: manifestURL)
    }

    private func atomicWrite(data: Data, to url: URL) throws {
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: tempURL, options: .atomic)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try fileManager.moveItem(at: tempURL, to: url)
    }

    private static func makeInputFingerprint(for url: URL) throws -> InputFingerprint {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let fileSize = UInt64(values.fileSize ?? 0)
        let modificationDate = values.contentModificationDate ?? .distantPast
        return InputFingerprint(
            path: url.standardizedFileURL.path,
            fileSize: fileSize,
            modificationTimeIntervalSince1970: modificationDate.timeIntervalSince1970
        )
    }

    public static func hashString(_ raw: String) -> String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
