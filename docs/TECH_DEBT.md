# Technical Debt

Track cleanup candidates here when they are not fixed immediately. Prefer converting repeated items into tests or mechanical checks.

## Current Items

- `OCRProcessor` emits a Swift 6 Sendable warning around `AVAssetImageGenerator` captured in an asynchronous callback.
- Add opt-in media fixtures or scripts for full OCR/speech smoke tests.
- Consider file-size or complexity checks if provider implementations continue to grow.
