# Architecture

KShowSub is currently a macOS Swift Package that builds a command-line tool and a reusable core library. The active media providers use Apple Speech, Vision, and AVFoundation, but the orchestration code should stay behind provider protocols so other backends or platforms can be introduced without rewriting the pipeline.

## Targets

- `KShowSub`: executable target. Owns CLI flags, input/output paths, pipeline orchestration, progress messages, and final ASS file writing.
- `KShowSubCore`: library target. Owns speech/OCR processing, cue merging, translation, resumable job state, and provider interfaces.

## Pipeline

1. `KShowSubCLI` validates CLI input and creates a `JobStore`.
2. Speech transcription and OCR extraction run concurrently.
3. `SpeechCueMerger` combines word-level speech cues into readable dialogue cues.
4. OCR cues and dialogue cues are sorted into a merged timeline.
5. Optional translation rewrites cue text while preserving timing and metadata.
6. `ASSMerger` writes styled ASS output with top OCR and bottom dialogue styles.

## Persistence

`JobStore` creates one workspace per input fingerprint. It stores a manifest plus stage artifacts for speech cues, OCR frame records, OCR cues, merged cues, and translated cues. Tests should use explicit temporary work directories.

## Provider Boundaries

Speech providers implement `VideoSpeechTranscribing`. The current `VideoSpeechTranscriber` is the Apple Speech-backed implementation.

OCR providers implement `VideoOCRProcessing`. The current `OCRProcessor` is the Apple Vision-backed implementation and owns frame sampling, filtering, resumable OCR frame records, and conversion into top-aligned subtitle cues.

Translation providers implement `TranslationProvider`. Provider configuration validation belongs at the registry/provider boundary; pipeline code should not guess environment variables or network behavior beyond that interface.

Pipeline orchestration should accept protocol existentials or a registry-resolved provider, not concrete framework implementations. If provider selection becomes user-configurable for speech or OCR, mirror the translation registry pattern: validate provider IDs and configuration at the boundary, then pass only the protocol instance into the pipeline.

## Platform Boundary

The package is still declared as macOS-only because the default media providers and executable link Apple-only frameworks. The path to Linux or Windows support is to split platform-specific media work from portable core behavior:

- Keep cue merging, ASS output, translation orchestration, job-store persistence, and provider protocols in portable Swift modules.
- Move Apple Speech, Vision, AVFoundation frame extraction, and Info.plist permission linkage into an Apple-specific adapter target.
- Add non-Apple adapter targets that conform to `VideoSpeechTranscribing` and `VideoOCRProcessing` using platform-appropriate engines such as local binaries, cross-platform libraries, or remote services.
- Keep CLI provider selection at the registry/factory boundary so platform-specific availability errors are reported before the pipeline starts.
- Keep default tests focused on portable behavior and protocol-contract stubs. Put real media, permissions, model downloads, and service calls behind opt-in validation scripts.

## Agent Notes

Most high-value tests are pure Swift tests around parsing, merging, persistence, and provider selection. Full media processing depends on platform frameworks and permissions, so it belongs in opt-in fixture scripts rather than default CI.
