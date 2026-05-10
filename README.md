# KShowSub

A macOS command-line tool that generates **ASS** subtitles from a video file by combining:

- **Speech recognition** — transcribes dialogue (placed at the bottom of the frame).
- **Vision OCR** — reads on-screen text such as logos and captions (placed at the top).

Both pipelines run in parallel. The result is a single merged subtitle file. You can optionally **translate** all cues to another locale using Apple Intelligence or the OpenAI-compatible (chat completions) provider.

## Requirements

- **macOS 26** or later (`platforms` in `Package.swift`).
- **Swift 6.2** or newer (see `swift-tools-version` in `Package.swift`).
- **Speech recognition** permission when the system prompts (used for transcribing audio from the video).

## Build

From the repository root:

```bash
swift build -c release --product KShowSub
```

The binary is at `.build/release/KShowSub`.

For development:

```bash
swift run KShowSub --help
```

## Usage

Minimal invocation:

```bash
KShowSub \
  --input /path/to/video.mp4 \
  --output /path/to/out.ass \
  --locale ko-KR
```

- `--locale` sets the BCP 47 locale for speech recognition (e.g. `en-US`, `ko-KR`, `ja-JP`).
- Output is **Advanced SubStation Alpha** (`.ass`). The tool injects `PlayResX` / `PlayResY` when missing so top/bottom positioning matches typical 1080p playback.
- Intermediate results are cached under `~/Library/Application Support/KShowSub/jobs/<job-id>/` by default so reruns can resume from completed stages.

### Resume / workspace

- `--resume` / `--no-resume` — enable or disable reuse of persisted intermediate artifacts (default `--resume`).
- `--work-dir` — store resumable artifacts in a specific directory instead of the default Application Support location.

### OCR

- `--ocr-fps` — how many frames per second to sample for on-screen text (default **3**, range `1`–`120`). Higher values catch fast text at the cost of runtime.
- `--ocr-profile` — OCR tuning preset: **`default`** or **`unfiltered`**. The default preset applies logo/watermark region filtering, frame similarity skipping, and text-size limits. **`unfiltered`** turns off region filtering and similar-frame skipping (useful when defaults drop too much text or for debugging).

### Translation

Add `--translate` and choose a provider:

```bash
KShowSub -i video.mp4 -o out.ass -l ko-KR \
  --translate \
  --target-locale en-US \
  --translate-provider apple-intelligence
```

| Provider | ID | Notes |
|----------|-----|--------|
| Apple Intelligence | `apple-intelligence` | Default. On-device; no API key. Requires an Apple Intelligence–capable Mac and OS. |
| Apple Translation | `apple-translation` | On-device; no API key. Uses the Translation framework (macOS 15+). Language models must be pre-installed via System Settings → Language & Region → Translation Languages. |
| OpenAI-compatible | `openai-batch` | Set `OPENAI_API_KEY`. Uses the **chat completions** API (`/v1/chat/completions`). Optional: `OPENAI_MODEL` (default `gpt-5-nano`), `OPENAI_BASE_URL` (defaults to `https://api.openai.com`), `OPENAI_AUTH` (`bearer` or `x-api-key`). CLI: `--openai-model`, `--openai-base-url`, `--openai-auth`. Point `--openai-base-url` at any OpenAI-compatible gateway root (e.g. Gemini’s OpenAI endpoint); the client appends `/v1/chat/completions`. |

Run `KShowSub --help` for the full option list and defaults.

## Dependencies

Resolved via Swift Package Manager (see `Package.swift`):

- [swift-argument-parser](https://github.com/apple/swift-argument-parser)
- [swift-subtitle-kit](https://github.com/dioKaratzas/swift-subtitle-kit)
