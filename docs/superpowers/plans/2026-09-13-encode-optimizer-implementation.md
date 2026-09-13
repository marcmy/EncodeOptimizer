# EncodeOptimizer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a source-relative PowerShell video optimizer that probes arbitrary FFmpeg-decodable files, samples difficult/representative content, adaptively searches encoder quality settings, verifies candidates with perceptual metrics, and recommends or executes the smallest safe encode.

**Architecture:** `Optimize-Video.ps1` is a thin orchestration entry point over focused PowerShell modules for capability discovery, probing, sampling, encoder policy, metrics, adaptive search, stream/container handling, reporting, and cache/history. The optimizer compares each encoded candidate against the identically transformed source, uses independent verification samples, and refuses unsafe automatic decisions when confidence is insufficient.

**Tech Stack:** PowerShell 7.5+, FFmpeg/ffprobe, Pester 5, JSON/PSD1 configuration, GitHub Actions on Windows.

**Spec:** `docs/superpowers/specs/2026-09-13-encode-optimizer-design.md`

## Global Constraints

- Target PowerShell 7.5+.
- FFmpeg and ffprobe are external runtime dependencies and must be discovered from `PATH` or explicit parameters.
- Never overwrite or delete the source automatically.
- Preserve source timing, bit depth, chroma fidelity, color/HDR metadata, and auxiliary streams unless the user explicitly requests a transformation.
- Default mode is analyze-then-confirm; `-AutoEncode` is explicit.
- Default quality profile is `Conservative`.
- Default codec policy is Auto-but-conservative and may return `KEEP SOURCE`.
- Metrics compare `source -> requested filters` against `source -> requested filters -> encode -> decode`.
- HDR/Dolby Vision/VFR/interlace edge cases must fail safe rather than silently convert.
- Capability-dependent options may only be emitted when detected in the local FFmpeg build.

---

### Task 1: Project skeleton, configuration, and CI

**Files:** `EncodeOptimizer.psd1`, `config/quality-profiles.psd1`, `config/encoder-profiles.psd1`, `tests/Config.Tests.ps1`, `.github/workflows/test.yml`, `README.md`.

**Produces:** configuration contracts, module metadata, baseline Pester CI.

- [ ] Write failing configuration tests proving Conservative mean/worst/P05 thresholds are 98/97/95 and Balanced/Aggressive are progressively less strict.
- [ ] Add exact quality profiles and initial encoder profiles for `hevc_nvenc`, `libx265`, `h264_nvenc`, `libx264`, `av1_nvenc`, `libsvtav1` with quality-control type/range/direction and quality-first defaults.
- [ ] Add a Windows GitHub Actions unit-test job installing Pester 5 and running non-integration tests.
- [ ] Update README bootstrap/dependency information.
- [ ] Run Pester on PowerShell 7.5+ and commit `chore: bootstrap EncodeOptimizer project`.

### Task 2: Capability discovery and source probing

**Files:** `lib/Capability.psm1`, `lib/Probe.psm1`, probe/capability Pester tests, ffprobe JSON fixtures.

**Produces:** `Get-EOExecutable`, `Get-EOCapabilities`, `Get-EOSourceProbe`, `Get-EOVideoClassification`.

- [ ] Write fixture-driven tests for codec/profile/bit-depth/color parsing, rational FPS, dispositions, HDR10 metadata, and VFR classification.
- [ ] Implement executable discovery with `Get-Command` and capability parsing for `-encoders`, `-decoders`, `-filters`, `-hwaccels`, and per-encoder help.
- [ ] Implement normalized `ffprobe -show_format -show_streams -show_chapters -of json` parsing, including rotation, field order, pixel format, color/HDR data, stream tags/dispositions, bitrates, duration, and warnings for conflicting metadata.
- [ ] Run tests and commit `feat: add capability discovery and source probing`.

### Task 3: Encoder, stream, and container policy

**Files:** `lib/EncoderProfiles.psm1`, `lib/Streams.psm1`, corresponding tests.

**Produces:** `Get-EOEncoderCandidates`, `Resolve-EOEncoderProfile`, `Get-EOStreamPlan`, `Get-EOContainerPlan`, `New-EOFinalEncodeArguments`.

- [ ] Write tests for HEVC->HEVC NVENC preference, AV1 keep-source behavior, 10-bit/HDR refusal on unsafe 8-bit paths, H.264->HEVC migration policy, and explicit encoder override precedence.
- [ ] Resolve configured encoder arguments against detected local capabilities; NVENC quality options are emitted only when locally supported.
- [ ] Implement lossless auxiliary-stream copy policy, source-container preference, MKV/MP4 fallback, HEVC `hvc1` support, and explicit incompatibility warnings instead of silent stream loss.
- [ ] Run tests and commit `feat: add encoder and stream policy`.

### Task 4: Content characterization and independent sample selection

**Files:** `lib/Sampling.psm1`, `tests/Sampling.Tests.ps1`.

**Produces:** `Get-EOAnalysisWindows`, `Get-EOContentFeatures`, `Select-EOSamples` returning disjoint search/verification sample sets with start/duration/reasons/features.

- [ ] Write deterministic synthetic-window tests proving temporal coverage, high-motion/detail/noise/dark inclusion, black/static de-weighting, disjoint verification samples, and short-file adaptation.
- [ ] Implement inexpensive FFmpeg scene/motion/detail/noise/dark characterization with raw feature extraction isolated from ranking.
- [ ] Implement diversified category quotas and temporal-distance penalties; normally choose 6–10 search clips of 8–12 seconds plus independent verification clips.
- [ ] Run tests and commit `feat: add content-aware sampling`.

### Task 5: Metric pipeline and aggregation

**Files:** `lib/Metrics.psm1`, `tests/Metrics.Tests.ps1`.

**Produces:** `Get-EOMetricPlan`, `Invoke-EOMetrics`, `Measure-EOMetricAggregate`, `Test-EOQualityPolicy`.

- [ ] Write synthetic per-frame/per-sample tests for mean/P01/P05/P10, worst-sample mean, isolated pathological-frame tolerance, and sustained bad-sequence failure.
- [ ] Apply `-VideoFilter` identically in reference and candidate paths and normalize dimensions/timing/range/pixel format for comparison.
- [ ] Prefer 10-bit SDR VMAF metric representation where supported; use libvmaf JSON plus XPSNR/SSIM/PSNR when available.
- [ ] For HDR, preserve native data; treat deterministic tone-mapped VMAF as advisory and lower confidence rather than pretending SDR VMAF is absolute HDR quality.
- [ ] Run tests and commit `feat: add source-relative quality metrics`.

### Task 6: Adaptive quality search, size model, and confidence

**Files:** `lib/Search.psm1`, `tests/Search.Tests.ps1`.

**Produces:** `Find-EOOptimalQuality`, `Estimate-EOOutputSize`, `Get-EOConfidence`.

- [ ] Write fake-evaluator tests proving bracket/refine finds the smallest/worst passing quality, moves safer after independent verification failure, stops early, and returns `KEEP SOURCE` below the configured savings threshold.
- [ ] Implement source/history seeded bracket/refine search with every candidate retained for reporting.
- [ ] Weight sample bitrate by complexity to estimate final size plus copied auxiliary streams/container overhead; return a range rather than false precision.
- [ ] Grade confidence from coverage/diversity, threshold margin, metric agreement, edge-case flags, and search-vs-verification stability.
- [ ] Run tests and commit `feat: add adaptive quality search`.

### Task 7: Cache/history, reporting, and orchestration

**Files:** `lib/Cache.psm1`, `lib/Reporting.psm1`, `Optimize-Video.ps1`, cache/report tests.

**Produces:** deterministic cache/history, human and JSON reports, exact command generation, public CLI.

- [ ] Write tests proving cache keys change with source/filter/encoder/FFmpeg/policy inputs and reports contain source summary, sample map, candidates, metrics, estimated savings, confidence, warnings, exact command, alternatives, and keep-source rationale.
- [ ] Persist compact JSON cache/history keyed by source fingerprint + settings; history may seed but never bypass verification.
- [ ] Implement CLI parameters `-Path`, `-Profile`, `-Encoder`, `-Codec`, `-VideoFilter`, `-AutoEncode`, `-ForceEncode`, `-KeepSamples`, `-OutputPath`, `-FFmpegPath`, `-FFprobePath`.
- [ ] Final encoding uses a temporary output, ffprobe validation, stream/duration/timing checks, then atomic rename. Input overwrite is forbidden.
- [ ] Run tests and commit `feat: orchestrate optimization and safe encoding`.

### Task 8: Batch mode, concurrency controls, and edge-case gates

**Files:** modify orchestration/probe/search modules; create batch/edge-case tests.

**Adds:** `-Batch`, `-Recurse`, include/exclude patterns, output directory, resume, `-MaxCpuJobs`, `-MaxGpuJobs`, confidence overrides.

- [ ] Write tests for recursive discovery, resume by fingerprint, separate CPU/GPU limits, low-confidence AutoEncode refusal, HDR10 preservation, Dolby Vision block, VFR preservation, interlace warning/gate, and no-NVENC fallback.
- [ ] Analyze every batch input independently; never reuse another file's chosen CQ/CRF without fresh measured verification.
- [ ] Block automatic Dolby Vision transcodes unless preservation is proven, preserve VFR, do not auto-deinterlace, and lower confidence for ambiguous edge cases.
- [ ] Add conservative CPU/GPU throttles to avoid thermal saturation.
- [ ] Run tests and commit `feat: add safe batch optimization`.

### Task 9: Integration coverage, documentation, and release verification

**Files:** `tests/Integration.Tests.ps1`, `.github/workflows/test.yml`, `README.md`.

- [ ] Generate tiny deterministic FFmpeg fixtures in CI from lavfi when required encoders are available; test no-filter and crop-filter flows, stream copying, JSON report generation, and output validation.
- [ ] Add integration CI separate from unit tests; capability-gate optional/NVENC tests rather than failing on runners without NVIDIA hardware.
- [ ] Document installation, dependencies, quality profiles, codec policy, NVENC/software tradeoffs, arbitrary filters, analyze-then-confirm, batch/cache/reporting, and HDR/Dolby Vision limitations.
- [ ] Run the complete Pester suite. Integration cases may skip only for explicitly unavailable optional capabilities.
- [ ] Static-check generated commands: no input overwrite, no silent bit-depth/chroma/HDR downgrade, confidence-gated AutoEncode.
- [ ] Commit `test: add end-to-end optimizer coverage`.

## Final verification

- [ ] All Pester tests pass on PowerShell 7.5+.
- [ ] Windows GitHub Actions unit job passes.
- [ ] HEVC NVENC command generation uses only options detected in the current build.
- [ ] Source files cannot be overwritten by default.
- [ ] Reference path applies exactly the requested transformation before quality comparison.
- [ ] Search and verification clips are disjoint.
- [ ] Conservative defaults are VMAF mean >= 98, worst sample >= 97, P05 >= 95.
- [ ] `KEEP SOURCE` appears when savings are not worthwhile.
- [ ] HDR/Dolby Vision/VFR/interlace conditions produce explicit safe behavior.
- [ ] Reports contain the exact final FFmpeg command plus machine-readable JSON.