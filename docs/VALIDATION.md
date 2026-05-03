# Validation

Default validation must be deterministic and safe to run in CI.

## Required Commands

```bash
swift build
swift run KShowSubCoreTestRunner
```

For release work:

```bash
swift build -c release
```

For CLI smoke checks:

```bash
swift run KShowSub --help
```

## CI Scope

The `Validate` workflow runs on pull requests and pushes to `main`. It currently builds and runs the framework-free core test runner on `macos-26` with Swift 6.2.

## Out Of Scope For Default CI

- Speech recognition permission prompts
- Vision OCR over real media
- Apple Intelligence availability
- Translation framework model availability
- Network calls to OpenAI-compatible APIs

These should be covered by opt-in local scripts or explicit integration jobs when fixtures and secrets are available.

## Current Warning Policy

Warnings are visible but not yet build-blocking. Before enabling warning-as-error enforcement, clean up the Swift 6 Sendable warning in `OCRProcessor`.
