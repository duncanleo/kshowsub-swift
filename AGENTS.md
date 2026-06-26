# KShowSub Agent Guide

This file is the entry point for agents working in this repository. Keep it short and point to deeper docs when details grow.

## Repository Map

- `Sources/KShowSub/`: CLI argument parsing and top-level pipeline orchestration.
- `Sources/KShowSubCore/Pipeline/`: speech, OCR, cue merging, ASS output, and provider interfaces.
- `Sources/KShowSubCore/Translation/`: translation orchestration and provider implementations.
- `Sources/KShowSubCore/JobStore/`: resumable workspace manifests and stage artifacts.
- `Tests/KShowSubCoreTestRunner/`: deterministic core test runner that does not require media, permissions, or network access.
- `docs/`: architecture, validation, product behavior, plans, and technical debt tracking.

## Commands

Run these from the repository root:

```bash
swift build
swift run KShowSubCoreTestRunner
swift run KShowSub --help
```

Use `swift build -c release --product KShowSub` before release changes. Full OCR/speech runs may require macOS permissions and real video fixtures; do not add those to default CI unless explicitly requested.

## Working Rules

- Prefer deterministic tests for parsing, cue merging, persistence, and provider boundary behavior.
- Keep API-key, network, Apple Intelligence, Speech, and Vision checks out of default tests.
- Treat generated `.ass` files and `.kshowsub/` workspaces as local artifacts.
- Update docs when changing CLI flags, stage artifacts, provider behavior, or pipeline architecture.
- Use Conventional Commits for all agent-created commits, for example `feat: add translation resume support`.
- Include a `Co-Authored-By` trailer on agent-created commits.
- If a repeated review comment becomes a rule, encode it in tests, scripts, or docs.

## Deeper Context

- Architecture: `docs/ARCHITECTURE.md`
- Validation: `docs/VALIDATION.md`
- Product behavior: `docs/PRODUCT.md`
- Larger plans: `docs/PLANS.md`
- Known cleanup: `docs/TECH_DEBT.md`
