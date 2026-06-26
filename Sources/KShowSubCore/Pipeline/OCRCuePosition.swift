import Foundation
import SubtitleKit

public enum OCRCuePosition {
    static let xAttribute = "KShowSubOCRPositionX"
    static let yAttribute = "KShowSubOCRPositionY"
    static let fontHeightAttribute = "KShowSubOCRFontHeight"

    public static let defaultPlayResX = 1920
    public static let defaultPlayResY = 1080
    static let minimumFontSize = 34
    static let maximumFontSize = 64
    static let fontHeightScale = 0.85
    static let dialogueAvoidanceMinimumY = 0.16
    static let dialogueAvoidanceLaneSpacing = 0.04

    public enum TextDirection: String, Sendable {
        case ltr
        case rtl
    }

    struct Normalized: Equatable {
        let x: Double
        let y: Double
    }

    static func normalizedCenter(for observations: [OCRTextObservation]) -> Normalized? {
        guard !observations.isEmpty else { return nil }

        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude

        for observation in observations {
            minX = min(minX, observation.boundingBoxX)
            minY = min(minY, observation.boundingBoxY)
            maxX = max(maxX, observation.boundingBoxX + observation.boundingBoxWidth)
            maxY = max(maxY, observation.boundingBoxY + observation.boundingBoxHeight)
        }

        return Normalized(
            x: clamp((minX + maxX) / 2),
            y: clamp((minY + maxY) / 2)
        )
    }

    static func normalizedAnchor(
        for observations: [OCRTextObservation],
        textDirection: TextDirection = .ltr
    ) -> Normalized? {
        guard !observations.isEmpty else { return nil }

        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude

        for observation in observations {
            minX = min(minX, observation.boundingBoxX)
            minY = min(minY, observation.boundingBoxY)
            maxX = max(maxX, observation.boundingBoxX + observation.boundingBoxWidth)
            maxY = max(maxY, observation.boundingBoxY + observation.boundingBoxHeight)
        }

        return Normalized(
            x: clamp(textDirection == .rtl ? maxX : minX),
            y: clamp((minY + maxY) / 2)
        )
    }

    static func normalizedFontHeight(for observation: OCRTextObservation) -> Double {
        clamp(observation.boundingBoxHeight)
    }

    static func attributes(for position: Normalized?, fontHeight: Double? = nil) -> [SubtitleAttribute] {
        var attributes: [SubtitleAttribute] = []
        if let position {
            attributes.append(contentsOf: [
                SubtitleAttribute(key: xAttribute, value: format(position.x)),
                SubtitleAttribute(key: yAttribute, value: format(position.y)),
            ])
        }
        if let fontHeight {
            attributes.append(SubtitleAttribute(key: fontHeightAttribute, value: format(fontHeight)))
        }
        return attributes
    }

    static func assOverridePrefix(
        from attributes: [SubtitleAttribute],
        playResX: Int = defaultPlayResX,
        playResY: Int = defaultPlayResY,
        textDirection: TextDirection = .ltr,
        minimumNormalizedY: Double? = nil
    ) -> String? {
        guard
            let normalizedX = value(for: xAttribute, in: attributes),
            let normalizedY = value(for: yAttribute, in: attributes)
        else {
            return nil
        }

        var overrides = [textDirection == .rtl ? "\\an6" : "\\an4"]
        if let fontSize = fontSize(from: attributes, playResY: playResY) {
            overrides.append("\\fs\(fontSize)")
        }

        let x = Int((clamp(normalizedX) * Double(max(1, playResX))).rounded())
        let yPosition = minimumNormalizedY
            .map { max(clamp(normalizedY), clamp($0)) } ?? clamp(normalizedY)
        let y = Int(((1 - yPosition) * Double(max(1, playResY))).rounded())
        overrides.append("\\pos(\(x),\(y))")
        return "{\(overrides.joined())}"
    }

    static func normalizedY(from attributes: [SubtitleAttribute]) -> Double? {
        value(for: yAttribute, in: attributes).map(clamp)
    }

    static func dialogueAvoidanceMinimumY(forLane lane: Int) -> Double {
        clamp(dialogueAvoidanceMinimumY + Double(max(0, lane)) * dialogueAvoidanceLaneSpacing)
    }

    static func isNear(_ lhs: Normalized?, _ rhs: Normalized?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (_?, nil), (nil, _?):
            return false
        case (let lhs?, let rhs?):
            return distance(lhs, rhs) <= 0.05
        }
    }

    static func distance(_ lhs: Normalized?, _ rhs: Normalized?) -> Double {
        switch (lhs, rhs) {
        case (nil, nil):
            return 0
        case (_?, nil), (nil, _?):
            return Double.greatestFiniteMagnitude
        case (let lhs?, let rhs?):
            let dx = lhs.x - rhs.x
            let dy = lhs.y - rhs.y
            return sqrt(dx * dx + dy * dy)
        }
    }

    private static func value(for key: String, in attributes: [SubtitleAttribute]) -> Double? {
        guard let raw = attributes.first(where: { $0.key == key })?.value else { return nil }
        return Double(raw)
    }

    private static func fontSize(from attributes: [SubtitleAttribute], playResY: Int) -> Int? {
        guard let normalizedHeight = value(for: fontHeightAttribute, in: attributes) else {
            return nil
        }

        let rawSize = Int(
            (clamp(normalizedHeight) * Double(max(1, playResY)) * fontHeightScale).rounded())
        return min(max(rawSize, minimumFontSize), maximumFontSize)
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.6f", clamp(value))
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
