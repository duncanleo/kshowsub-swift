# Architecture

KShowSub is a macOS Swift Package that builds a command-line tool and a reusable core library.

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

Translation providers implement `TranslationProvider`. Provider configuration validation belongs at the registry/provider boundary; pipeline code should not guess environment variables or network behavior beyond that interface.

## Agent Notes

Most high-value tests are pure Swift tests around parsing, merging, persistence, and provider selection. Full media processing depends on platform frameworks and permissions, so it belongs in opt-in fixture scripts rather than default CI.
