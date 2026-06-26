import CoreGraphics
import Foundation

/// A named collection of tuning parameters that controls how OCR frames are sampled,
/// filtered, and deduplicated.  Pass a profile to `OCRProcessor.extractText` to switch
/// between presets without touching the source.
public struct OCRProfile: Sendable {

    // MARK: - Filtering switches

    /// When `true`, observations whose centre falls inside a logo/watermark exclusion
    /// zone, whose text is too small, or whose baseline is too skewed are dropped.
    /// Set to `false` to keep every observation Vision returns.
    public var filterLogoRegions: Bool

    /// When `true`, consecutive frames that look nearly identical (per
    /// `frameSimilaritySkipThreshold`) skip Vision OCR and reuse the previous result.
    /// Set to `false` to run OCR on every sampled frame.
    public var skipSimilarFrames: Bool

    /// When `true`, OCR observations are kept only when similar text appears in a
    /// nearby sampled frame at roughly the same position. This reduces one-off OCR
    /// hits from shirts, signs, and background texture.
    public var filterTransientObservations: Bool

    // MARK: - Frame sampling

    /// Max Vision OCR requests to run concurrently.
    public var maxConcurrentOCRFrames: Int

    // MARK: - Frame similarity / deduplication

    /// Side length of the grayscale thumbnail used to compare consecutive frames.
    /// Larger → more sensitive to small motion.
    public var frameSimilarityFingerprintSize: Int

    /// Mean absolute pixel difference (0…1) below which OCR is skipped for a frame
    /// and the previous result is reused instead.  Only used when `skipSimilarFrames`
    /// is `true`.
    public var frameSimilaritySkipThreshold: Float

    /// Normalized Levenshtein distance (0…1) below which a new OCR result is
    /// replaced with the previous one (minor OCR noise / punctuation drift).
    public var textSimilarityReuseThreshold: Float

    /// Bounding-box intersection-over-union threshold for temporal observation matching.
    public var transientObservationIOUThreshold: Float

    /// Maximum normalized center-point distance for temporal observation matching.
    public var transientObservationCenterDistanceThreshold: Float

    /// Number of neighboring-frame matches required to keep an OCR observation.
    public var transientObservationMinNeighborMatches: Int

    /// Number of sampled frames before/after the current frame to search for matches.
    public var transientObservationNeighborWindow: Int

    // MARK: - Text height / size

    /// Minimum text height as a fraction of the image height.  Shorter observations
    /// are dropped (catches tiny watermarks).  Only used when `filterLogoRegions`
    /// is `true`.
    public var minimumRecognizedTextHeight: Float

    /// Bounding-box area (width × height, both normalized) below which recognized text
    /// is wrapped in parentheses rather than displayed as a top-level subtitle line.
    public var parenthesesAreaThreshold: CGFloat

    // MARK: - Skew filtering

    /// Maximum allowed baseline angle from horizontal (degrees).  Observations beyond
    /// this are dropped (rotated watermarks, vertical labels, etc.).  Only used when
    /// `filterLogoRegions` is `true`.
    public var maximumSkewDegrees: Double

    // MARK: - Logo / UI region filtering

    /// Top band depth as a fraction of frame height (0…1).  Used for the horizontal
    /// strip spanning between the top corner rectangles.
    public var topBandFraction: CGFloat

    /// Full-width bottom band depth as a fraction of frame height.  Covers tickers,
    /// lower-thirds, etc.
    public var bottomBandFraction: CGFloat

    /// Width of the top-left and top-right corner exclusion rectangles as a fraction
    /// of frame width.  Also sets the horizontal inset for the top centre strip.
    public var topCornerWidthFraction: CGFloat

    /// Height of the top-left and top-right corner exclusion rectangles as a fraction
    /// of frame height.
    public var topCornerHeightFraction: CGFloat

    /// Width of the bottom-left and bottom-right corner exclusion strips as a fraction
    /// of frame width.
    public var bottomCornerWidthFraction: CGFloat

    /// Height of the bottom corner exclusion strips as a fraction of frame height.
    public var bottomHeightFraction: CGFloat

    // MARK: - Derived helpers

    /// Axis-aligned exclusion rectangles in normalized Vision space (origin at
    /// bottom-left, y increases upward).
    var exclusionRects: [CGRect] {
        [
            // Top centre strip (between the corner columns)
            CGRect(
                x: topCornerWidthFraction, y: 1 - topBandFraction,
                width: 1 - 2 * topCornerWidthFraction, height: topBandFraction),
            // Top-left corner
            CGRect(
                x: 0, y: 1 - topCornerHeightFraction,
                width: topCornerWidthFraction, height: topCornerHeightFraction),
            // Top-right corner
            CGRect(
                x: 1 - topCornerWidthFraction, y: 1 - topCornerHeightFraction,
                width: topCornerWidthFraction, height: topCornerHeightFraction),
            // Full bottom band
            CGRect(x: 0, y: 0, width: 1, height: bottomBandFraction),
            // Bottom-left corner
            CGRect(x: 0, y: 0, width: bottomCornerWidthFraction, height: bottomHeightFraction),
            // Bottom-right corner
            CGRect(
                x: 1 - bottomCornerWidthFraction, y: 0,
                width: bottomCornerWidthFraction, height: bottomHeightFraction),
        ]
    }

    func shouldExclude(boundingBox: CGRect) -> Bool {
        let center = CGPoint(x: boundingBox.midX, y: boundingBox.midY)
        return exclusionRects.contains { $0.contains(center) }
    }

    // MARK: - Designated init

    public init(
        filterLogoRegions: Bool = true,
        skipSimilarFrames: Bool = true,
        filterTransientObservations: Bool = true,
        maxConcurrentOCRFrames: Int = 4,
        frameSimilarityFingerprintSize: Int = 32,
        frameSimilaritySkipThreshold: Float = 0.03,
        textSimilarityReuseThreshold: Float = 0.2,
        transientObservationIOUThreshold: Float = 0.2,
        transientObservationCenterDistanceThreshold: Float = 0.12,
        transientObservationMinNeighborMatches: Int = 1,
        transientObservationNeighborWindow: Int = 2,
        minimumRecognizedTextHeight: Float = 0.02,
        parenthesesAreaThreshold: CGFloat = 0.0055,
        maximumSkewDegrees: Double = 5,
        topBandFraction: CGFloat = 0.15,
        bottomBandFraction: CGFloat = 0.10,
        topCornerWidthFraction: CGFloat = 0.2,
        topCornerHeightFraction: CGFloat = 0.35,
        bottomCornerWidthFraction: CGFloat = 0.2,
        bottomHeightFraction: CGFloat = 0.15
    ) {
        self.filterLogoRegions = filterLogoRegions
        self.skipSimilarFrames = skipSimilarFrames
        self.filterTransientObservations = filterTransientObservations
        self.maxConcurrentOCRFrames = maxConcurrentOCRFrames
        self.frameSimilarityFingerprintSize = frameSimilarityFingerprintSize
        self.frameSimilaritySkipThreshold = frameSimilaritySkipThreshold
        self.textSimilarityReuseThreshold = textSimilarityReuseThreshold
        self.transientObservationIOUThreshold = transientObservationIOUThreshold
        self.transientObservationCenterDistanceThreshold = transientObservationCenterDistanceThreshold
        self.transientObservationMinNeighborMatches = transientObservationMinNeighborMatches
        self.transientObservationNeighborWindow = transientObservationNeighborWindow
        self.minimumRecognizedTextHeight = minimumRecognizedTextHeight
        self.parenthesesAreaThreshold = parenthesesAreaThreshold
        self.maximumSkewDegrees = maximumSkewDegrees
        self.topBandFraction = topBandFraction
        self.bottomBandFraction = bottomBandFraction
        self.topCornerWidthFraction = topCornerWidthFraction
        self.topCornerHeightFraction = topCornerHeightFraction
        self.bottomCornerWidthFraction = bottomCornerWidthFraction
        self.bottomHeightFraction = bottomHeightFraction
    }

    // MARK: - Named presets

    /// Balanced preset for most content.  Excludes common logo/watermark zones,
    /// skips near-identical frames, and applies moderate similarity deduplication.
    public static let `default` = OCRProfile()

    /// No filtering at all: every Vision observation is kept and every sampled frame
    /// is OCR'd.  Useful for debugging or content where the defaults discard too much.
    public static let unfiltered = OCRProfile(
        filterLogoRegions: false,
        skipSimilarFrames: false,
        filterTransientObservations: false
    )

    // MARK: - Lookup by name

    public static let allNamed: [(name: String, profile: OCRProfile)] = [
        ("default", .default),
        ("unfiltered", .unfiltered),
    ]

    /// Returns the preset matching `name`, or `nil` if unknown.
    public static func named(_ name: String) -> OCRProfile? {
        allNamed.first { $0.name == name }?.profile
    }
}
