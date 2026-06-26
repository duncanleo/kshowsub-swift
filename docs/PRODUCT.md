# Product Behavior

KShowSub generates ASS subtitles from a video by combining speech transcription and on-screen OCR.

## Expected Output

- Dialogue from speech recognition appears as bottom-centered subtitle cues.
- OCR text appears as top-centered subtitle cues by default.
- `--position-ocr` experimentally places OCR text near its detected on-screen location when
  Vision bounding boxes are available. Positioned OCR defaults to left-edge anchoring for
  left-to-right text; pass `--ocr-position-direction rtl` to anchor the detected right edge for
  right-to-left text.
- With `--position-ocr`, positioned OCR text uses limited dynamic font sizing from detected text height, clamped to
  avoid extreme tiny or oversized overlays. Older cached OCR text without bounding boxes falls
  back to the TopOCR style.
- Positioned OCR is kept above the bottom dialogue region when it overlaps a dialogue cue in
  time, and simultaneous bottom-region OCR cues are assigned vertical lanes to reduce collisions
  with each other and with speech subtitles.
- When `--post-process` is enabled, an LLM provider receives batched dialogue and on-screen text cues with overlap context, then decides what should become the final bottom-centered subtitle track. Dialogue and OCR are treated as imperfect signals that can disambiguate each other. Dialogue may be preserved, lightly rewritten, merged, or dropped; on-screen text may be preserved, rewritten, or distilled, and is rendered in parentheses.
- Post-processed subtitles should stay concise in a broadcast/Netflix-style presentation. Non-dialogue parenthetical text must be on its own line, and likely speaker or turn changes should be split across lines instead of embedded in one sentence.
- Output format is Advanced SubStation Alpha (`.ass`).
- `PlayResX` and `PlayResY` are injected when absent so margins render predictably. Both default
  and positioned OCR modes keep the historical 1920x1080 script resolution so dialogue subtitle
  scale and margins stay consistent.

## Resume Behavior

Intermediate artifacts are stored in a per-input workspace. By default, reruns reuse completed compatible stages. `--no-resume` disables reuse, and `--work-dir` selects a custom workspace root.

## Translation Behavior

Translation is optional. Providers must preserve cue timing and metadata. Multi-line cues may be translated line-by-line and reassembled with ASS line breaks in raw text.

## Post-Processing Behavior

Post-processing is optional and runs before translation. Providers receive ordered batches of timestamped cues plus context that identifies dialogue, on-screen text, unknown cues, and temporal overlaps. They distill those inputs into a single readable subtitle track with bottom-dialogue styling for TV, variety, and reality shows, including but not limited to Korean broadcasts. Dialogue is plain subtitle text. On-screen text is included only when useful and must be parenthesized, whether preserved verbatim, rewritten, or distilled from multiple cues. Providers should use overlapping dialogue and on-screen text to repair or disambiguate likely speech transcription and OCR errors instead of blindly trusting either source. Outputs should avoid wordy paragraph subtitles, keep non-dialogue parentheticals on separate lines, and split inferred speaker or turn changes across lines. The same presentation normalization is applied after translation so translated subtitles cannot re-expand into dense paragraph cues. Apple Intelligence uses small ordered cue windows to stay within its 4k context limit. The built-in providers are Apple Intelligence (`apple-intelligence`) and OpenAI-compatible chat completions (`openai`), using the existing `--openai-model`, `--openai-base-url`, and `--openai-auth` options for OpenAI-compatible configuration.

## Default Quality Bar

Changes should preserve deterministic output for pure transformations and should not require permissions, API keys, or network access unless the user explicitly requests integration behavior.
