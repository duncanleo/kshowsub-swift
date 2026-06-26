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
- Output format is Advanced SubStation Alpha (`.ass`).
- `PlayResX` and `PlayResY` are injected when absent so margins render predictably. Both default
  and positioned OCR modes keep the historical 1920x1080 script resolution so dialogue subtitle
  scale and margins stay consistent.

## Resume Behavior

Intermediate artifacts are stored in a per-input workspace. By default, reruns reuse completed compatible stages. `--no-resume` disables reuse, and `--work-dir` selects a custom workspace root.

## Translation Behavior

Translation is optional. Providers must preserve cue timing and metadata. Multi-line cues may be translated line-by-line and reassembled with ASS line breaks in raw text.

## Default Quality Bar

Changes should preserve deterministic output for pure transformations and should not require permissions, API keys, or network access unless the user explicitly requests integration behavior.
