# EncodeOptimizer — Design Specification

Date: 2026-09-13  
Status: Approved  
Target shell: PowerShell 7.5+  
Primary tools: FFmpeg, ffprobe

## Purpose

EncodeOptimizer is a source-relative video compression optimizer. It does not apply one universal CRF/CQ value. Each input is probed and characterized independently; representative and difficult segments are sampled, encoder candidates are tested, distortion is measured against the identically transformed source, and the tool recommends the smallest practical encode that satisfies a selected quality policy.

The default policy is conservative: preserve perceptual quality first, then minimize size. When no tested transcode provides worthwhile savings at the requested quality, the correct answer is `KEEP SOURCE`.

## Core goals

- Accept arbitrary common FFmpeg-decodable sources, including H.264, HEVC, AV1, VP9, MPEG-2, VC-1, and MPEG-4 Part 2.
- Handle varied containers, resolutions, frame rates, VFR/CFR, bit depths, chroma formats, SDR/HDR, progressive/interlaced content, and metadata.
- Support no-filter optimization and arbitrary user video transformations such as crop, scale, deinterlace, FPS conversion, and denoise.
- Prefer hardware encoding when it meets the quality target, while retaining software encoders as optional alternatives.
- Preserve auxiliary streams and metadata safely by default.
- Produce explainable recommendations: source summary, candidate table, measured quality, estimated size/savings, confidence, warnings, exact final FFmpeg command, safer/smaller alternatives, or `KEEP SOURCE`.
- Support one-file interactive analysis and unattended batch processing.

## Non-goals and safety rules

- No mathematical-lossless claim unless an explicit lossless mode is selected.
- No blind fixed CRF/CQ rule.
- No silent HDR-to-SDR conversion.
- No silent VFR-to-CFR or frame-rate normalization.
- No silent bit-depth/chroma reduction.
- No forced codec migration when compatibility or savings do not justify it.
- No destructive replacement or deletion of source files.

## Default UX

```powershell
./Optimize-Video.ps1 <input>
```

Default mode is **analyze then confirm**:

1. Probe source and local capabilities.
2. Select codec/encoder candidates conservatively.
3. Characterize the source and select representative/difficult samples.
4. Test candidate quality settings adaptively.
5. Measure quality and estimate full-file size.
6. Print recommendation, confidence, warnings, exact command, and alternatives.
7. Stop before the full encode.

`-AutoEncode` permits the recommended encode automatically when confidence meets policy.

Representative invocations:

```powershell
./Optimize-Video.ps1 input.mkv
./Optimize-Video.ps1 input.mp4 -Profile Conservative
./Optimize-Video.ps1 input.mp4 -Encoder hevc_nvenc
./Optimize-Video.ps1 input.mp4 -VideoFilter 'crop=404:720:438:0'
./Optimize-Video.ps1 input.mkv -Profile Balanced -AutoEncode
./Optimize-Video.ps1 *.mkv -Batch -AutoEncode
```

## Architecture

```text
EncodeOptimizer/
  Optimize-Video.ps1
  EncodeOptimizer.psd1
  lib/
    Capability.psm1
    Probe.psm1
    Sampling.psm1
    EncoderProfiles.psm1
    Metrics.psm1
    Search.psm1
    Streams.psm1
    Reporting.psm1
    Cache.psm1
  config/
    quality-profiles.psd1
    encoder-profiles.psd1
  tests/
```

The entry script remains thin. Each module owns one concern and exposes testable interfaces.

## Capability discovery

Inspect the actual installed runtime instead of assuming features:

- `ffmpeg -version`, `ffprobe -version`
- encoders, decoders, filters, hwaccels
- `ffmpeg -h encoder=<name>` for supported options
- NVIDIA GPU/driver/NVENC information when available

Cache capability results by FFmpeg version/binary identity plus GPU/driver signature. Options may only be emitted if detected in the current build. Missing libvmaf/XPSNR/NVENC/AV1 features degrade explicitly rather than silently.

## Source probe model

Normalize ffprobe JSON into container duration, codec/tag/profile/level, coded/display dimensions, SAR/DAR, nominal/average frame rates, timebase, CFR/VFR indicators, pixel format/bit depth/chroma, field order, rotation/display matrix, color range/primaries/transfer/matrix, HDR mastering metadata, MaxCLL/MaxFALL, detectable Dolby Vision characteristics, stream/container bitrate, stream tags/dispositions, audio/subtitle/data/attachment streams, and chapters.

Conflicting or unknown metadata becomes a warning, not a guessed conversion.

## Auto-but-conservative codec policy

- HEVC source: prefer HEVC hardware encoding when available and measured quality/savings justify it.
- H.264 source: HEVC may be recommended when savings justify compatibility change.
- AV1 source: prefer keeping AV1; never automatically downgrade merely to avoid software encoding.
- VP9: test HEVC/AV1 only when supported and beneficial.
- Legacy codecs: modern HEVC is normally a reasonable candidate.
- Efficient/small sources: return `KEEP SOURCE` when no candidate passes both quality and savings requirements.
- Explicit `-Encoder`/`-Codec` overrides win.

Initial encoder profiles: `hevc_nvenc`, `h264_nvenc`, `av1_nvenc` when available, `libx265`, `libx264`, and optional `libsvtav1`. Profiles define quality-control type/range/direction, preset/tuning preferences, pixel-format/bit-depth support, HDR capability, and container constraints.

## Source-relative reference pipeline

Metrics compare the intended transformed source, not necessarily the untouched input:

```text
reference: source -> requested filters -> canonical metric format
candidate: source -> requested filters -> encode -> decode -> canonical metric format
```

This isolates encoder loss from deliberate transformations such as crop or scale.

## Content characterization and sampling

Perform a cheap analysis pass and choose approximately 6–10 search clips, normally 8–12 seconds each, adjusted for duration. Sampling should cover temporal distribution plus high motion, high spatial detail, noise/grain, dark/gradient material, scene transitions, and difficult texture such as foliage/water/smoke/confetti when detectable.

Black/frozen/credits/static material is de-weighted unless it genuinely dominates the source. Reserve a separate independent verification set so adaptive search cannot overfit its own samples.

Complexity features may include scene-change density, luma/chroma variance, edge/detail proxy, temporal-difference/motion proxy, noise/grain proxy, dark-scene percentage, gradient/banding-risk proxy, keyframe spacing, and bitrate-per-pixel-per-frame as context only.

## Metrics

For SDR, VMAF is primary when available. Prefer current VMAF v1 models appropriate to resolution class and frame-rate class. Use controlled 10-bit metric representation when supported. Secondary metrics: XPSNR, SSIM, PSNR.

Inputs must be aligned in dimensions, timing/frame count, range, colorspace, and pixel semantics.

For HDR/PQ/HLG, preserve HDR natively. Native high-bit-depth XPSNR/SSIM/PSNR are authoritative diagnostics. VMAF on an identical deterministic tone-mapped representation may be computed only as advisory. Dolby Vision receives an explicit safety block unless preservation behavior is proven.

Capture per-frame data when possible and aggregate mean, P01/P05/P10, per-sample means, worst-sample mean, and minimum as diagnostic only. One pathological frame must not dominate a decision; sustained poor sequences must.

## Quality profiles

### Conservative — default

- VMAF mean >= 98.0
- worst sample mean >= 97.0
- VMAF P05 >= 95.0
- no serious secondary-metric anomaly
- independent verification must pass

### Balanced

- VMAF mean >= 97.0
- worst sample mean >= 95.5
- VMAF P05 >= 93.5

### Aggressive

- VMAF mean >= 95.0
- worst sample mean >= 93.0
- VMAF P05 >= 90.0

These are policy thresholds, not universal claims of transparency.

## Adaptive search

Use hybrid bracket/refine search rather than brute-forcing every integer setting:

1. Seed quality from history/source complexity or profile midpoint.
2. Encode search samples.
3. Measure quality.
4. If comfortably passing, test a worse/smaller setting.
5. If failing, test a safer/larger setting.
6. Bracket pass/fail and refine the boundary.
7. Select the smallest candidate passing with safety margin.
8. Verify on independent clips.
9. If verification fails, move one step safer and verify again.
10. Stop early when the result is clear.

## Confidence and size estimation

Recommendation confidence derives from sample coverage/diversity, threshold margin, metric agreement, source edge cases, and search-vs-verification stability. Labels: HIGH, MEDIUM, LOW. `-AutoEncode` requires at least MEDIUM by default; Conservative batch mode may require HIGH.

Estimate final video bitrate/size from weighted sample outputs and add copied auxiliary streams plus container overhead. Always show a range. When no filter forces re-encoding, default to `KEEP SOURCE` if quality cannot be met, expected savings are below roughly 10–15%, output is likely larger, or codec migration cost is disproportionate.

## Timing, color, and streams

- Preserve source timestamps and VFR by default.
- Do not auto-deinterlace or normalize FPS.
- Never reduce bit depth or chroma fidelity automatically.
- Preserve full/limited range, primaries, transfer, matrix, and HDR mastering metadata when supported.
- Copy audio losslessly by default when container-compatible.
- Copy subtitles, chapters, metadata, language/default/forced dispositions, and MKV attachments when feasible.
- Never discard an auxiliary stream silently because of container incompatibility.
- Prefer source container when safe; otherwise MKV for flexibility or MP4 for compatible common workflows. Support HEVC `hvc1` tagging in MP4 where appropriate.

## Batch, cache, and learning

Batch mode analyzes every file independently and supports recursion, include/exclude filters, output directory, per-file JSON/logs, resume by source fingerprint + settings signature, and separate conservative CPU/GPU concurrency limits.

Persist local history keyed by encoder/settings, GPU generation, codec family, resolution/FPS class, bit-depth/HDR class, and content features. History may seed initial CRF/CQ guesses but can never bypass measured verification.

Use deterministic work/cache directories keyed by source fingerprint + transform + encoder profile. Cache probe, analysis, samples, candidate outputs, and metric JSON. Compact analysis history is retained; temporary sample video is cleaned after success unless requested.

## Reporting

Human-readable and JSON reports include source summary, warnings, encoder rationale, sample timestamps/reasons, candidate table, VMAF/percentiles/worst sample, secondary metrics, estimated size/savings range, confidence, exact final command, safer alternative, smaller alternative, and `KEEP SOURCE` rationale.

## Final encode safety

- Never overwrite input by default.
- Encode to a temporary output name and atomically rename after success.
- Probe output and validate duration/timing, expected streams/dispositions, and video characteristics.
- Optional post-encode sample verification under `-AutoEncode`.
- Source deletion is out of scope.

## Error classes

Distinguish unsupported source, unsupported hardware format, unavailable metric/filter, sample decode failure, candidate encode failure, metric alignment failure, HDR/Dolby Vision safety block, output-container incompatibility, and low-confidence recommendation. Fallback behavior must always be explicit.

## Testing

Pester unit tests cover probe parsing, codec policy, VFR/CFR classification, HDR/color metadata, quality gates, adaptive search, size estimation, stream mapping, and cache keys. Integration fixtures cover 720p/1080p/4K; 23.976/29.97/50/59.94/60; VFR; H.264/HEVC/AV1/VP9/legacy; 8/10-bit; SDR/HDR10; interlace; multiple auxiliary streams; filters; no-VMAF; and no-NVENC environments where capabilities permit.

Golden tests prove the optimizer selects the smallest tested setting satisfying policy and returns `KEEP SOURCE` when savings are not worthwhile.

## Acceptance criteria

The production-ready tool can analyze arbitrary SDR H.264/HEVC without hard-coded bitrate/resolution assumptions, test HEVC NVENC and/or x265 using short samples, find and independently verify a passing quality boundary, report measured quality and estimated savings, preserve timing/color/auxiliary streams by default, refuse unsafe edge cases rather than guessing, recommend `KEEP SOURCE`, produce an exact FFmpeg command, and safely execute it under `-AutoEncode`.