# EncodeOptimizer

EncodeOptimizer is a source-relative FFmpeg quality optimizer for PowerShell 7.5+. It does **not** assume one universal CRF/CQ value. Instead, it probes each input, samples representative and difficult sections, tests encoder settings adaptively, measures the encoded result against the identically transformed source, and recommends the smallest practical encode that satisfies the selected quality policy.

The default behavior is conservative and analyze-only. If no tested transcode meets the quality target with worthwhile savings, `KEEP_SOURCE` is a valid result.

## Requirements

- Windows with PowerShell 7.5 or newer.
- `ffmpeg` and `ffprobe`, either available on `PATH` or supplied explicitly with `-FFmpegPath` and `-FFprobePath`.
- An FFmpeg build with the encoder(s) you want to use.
- `libvmaf` is preferred for SDR quality decisions when available. XPSNR, SSIM, and PSNR are used as secondary metrics and as the quality fallback when VMAF is unavailable or non-authoritative.

EncodeOptimizer discovers the capabilities of the installed FFmpeg build at runtime. Encoder options are emitted only when the current build reports that they exist.

## Quick start

Analyze a file without encoding it:

```powershell
.\Optimize-Video.ps1 'D:\Video\input.mkv'
```

Apply a transformation and optimize only the unavoidable re-encode loss:

```powershell
.\Optimize-Video.ps1 'D:\Video\input.mp4' `
    -VideoFilter 'crop=404:720:438:0'
```

Use a less strict quality policy:

```powershell
.\Optimize-Video.ps1 'D:\Video\input.mkv' -Profile Balanced
```

Force a particular encoder:

```powershell
.\Optimize-Video.ps1 'D:\Video\input.mkv' -Encoder hevc_nvenc
.\Optimize-Video.ps1 'D:\Video\input.mkv' -Encoder libx265
```

Automatically run the recommended final encode when the safety and confidence gates pass:

```powershell
.\Optimize-Video.ps1 'D:\Video\input.mkv' -Profile Balanced -AutoEncode
```

Use explicit FFmpeg binaries:

```powershell
.\Optimize-Video.ps1 'D:\Video\input.mkv' `
    -FFmpegPath 'C:\ffmpeg\bin\ffmpeg.exe' `
    -FFprobePath 'C:\ffmpeg\bin\ffprobe.exe'
```

## Live progress

Single-file analysis keeps the current unit on one updating status line, then prints durable phase summaries and quality results. The status shows the overall percentage, current phase, quality test, sample number and timestamp, measured metrics, pass/fail result, estimated size, and elapsed time. For example:

```text
[ 43.1%] SEARCH    -cq=18 sample 3/8 ready | VMAF=99.12 P05=97.84 bitrate 14989.9 kbps | 38/89 units | elapsed 00:04:24
[ 51.0%] SEARCH    -cq=18 result | PASS | VMAF=98.71 P05=95.72 | margin 0.33 | estimated 10.54 GB | elapsed 00:05:02
```

Reference creation, VMAF baseline calibration, search samples, independent verification samples, final reporting, and AutoEncode validation are each reported as separate phases; per-unit work updates in place to keep the console readable.

## How the quality comparison works

When no video filter is requested, the encoded candidate is compared with the decoded source. When `-VideoFilter` is supplied, the same requested transformation is applied to the reference exactly once:

```text
reference: source -> requested filter(s) -> canonical metric format
candidate: source -> requested filter(s) -> encode -> decode -> canonical metric format
```

That distinction matters for operations such as crop, scale, deinterlace, denoise, or frame-rate conversion: the intentional transformation itself is not counted as encoder damage.

EncodeOptimizer first performs a cheap content-characterization pass, then selects temporally distributed and difficult samples such as motion, high detail, noise/grain, dark material, gradients, and scene transitions. Adaptive search finds the quality boundary on one sample set and verifies the result on a disjoint set so the search cannot simply overfit its own clips.

## Quality profiles

The profiles are policy thresholds, not universal claims that a particular score is always visually transparent.

| Profile | Mean VMAF | Worst sample mean | VMAF P05 | Minimum savings |
| --- | ---: | ---: | ---: | ---: |
| Conservative | 98.0 | 97.0 | 95.0 | 12% |
| Balanced | 97.0 | 95.5 | 93.5 | 10% |
| Aggressive | 95.0 | 93.0 | 90.0 | 8% |

`Conservative` is the default. It also requires HIGH confidence for unattended batch AutoEncode. Balanced and Aggressive batch AutoEncode require MEDIUM confidence.

For sources where VMAF is not authoritative, the configured secondary-metric thresholds are used instead. Conservative currently requires at least two available secondary metrics, with XPSNR >= 45 dB, SSIM >= 0.990, and PSNR >= 45 dB where those metrics are available.

## Encoder policy

Without an explicit `-Encoder` or `-Codec`, EncodeOptimizer uses an auto-but-conservative policy based on the source and locally available encoders.

- HEVC generally stays HEVC; NVENC is preferred when available and safe.
- H.264 may migrate to HEVC when the measured result justifies the compatibility change.
- AV1 is not silently downgraded merely to avoid software encoding.
- Legacy codecs may be moved to a modern codec when it is beneficial.
- Already efficient sources can legitimately return `KEEP_SOURCE`.

Hardware encoding is useful for throughput and low CPU load; software encoders such as `libx265` and `libx264` can provide better compression efficiency at the cost of CPU time. EncodeOptimizer measures the actual result rather than declaring one class universally superior.

Supported configured encoder families currently include `hevc_nvenc`, `h264_nvenc`, `av1_nvenc`, `libx265`, `libx264`, and `libsvtav1` when the installed FFmpeg build exposes them.

## Single-file options

Common options include:

```text
-Profile Conservative|Balanced|Aggressive
-Encoder <ffmpeg encoder name>
-Codec h264|hevc|av1
-VideoFilter <ffmpeg video-filter chain>
-AutoEncode
-ForceEncode
-KeepSamples
-OutputPath <file>
-FFmpegPath <path>
-FFprobePath <path>
```

`-ForceEncode` bypasses the normal minimum-savings decision, but it does not disable quality verification or the source-safety rules. `-KeepSamples` retains temporary candidate samples that would otherwise be cleaned up.

## Batch mode

Batch processing is provided by `Optimize-Videos.ps1`. Every source is probed and optimized independently; another file's selected CRF/CQ is never reused as an answer without that file's own measured analysis.

Analyze a directory recursively:

```powershell
.\Optimize-Videos.ps1 'D:\Video' -Recurse
```

Filter by relative-path wildcards:

```powershell
.\Optimize-Videos.ps1 'D:\Video' -Recurse `
    -Include '*.mkv','*.mp4' `
    -Exclude 'samples\*','*trailer*'
```

Write outputs and per-file reports to a separate tree while preserving relative subdirectories:

```powershell
.\Optimize-Videos.ps1 'D:\Video' -Recurse `
    -OutputDirectory 'E:\Optimized'
```

Resume completed work:

```powershell
.\Optimize-Videos.ps1 'D:\Video' -Recurse `
    -OutputDirectory 'E:\Optimized' `
    -Resume
```

Batch resume is intentionally strict. A previous result is reused only when its signature exactly matches the source fingerprint and effective settings, including encoder/profile information, quality policy, requested transform, FFmpeg version, output root, AutoEncode mode, and safety overrides. A changed source or setting causes fresh analysis.

For analyze-only batches, an exact matching completed report can be reused. For `-AutoEncode -Resume`, the previous result is reusable only if its output was marked validated **and the output file still exists**.

CPU and GPU work have independent throttles:

```powershell
.\Optimize-Videos.ps1 'D:\Video' -Recurse `
    -GpuConcurrency 2 `
    -CpuConcurrency 1
```

This prevents a software-transcode workload from multiplying simply because several GPU slots are available.

## Reports and cache

Single-file analysis writes a machine-readable report under the local EncodeOptimizer work cache. On Windows the default root is:

```text
%LOCALAPPDATA%\EncodeOptimizer\work\<cache-key>\report.json
```

Batch mode additionally writes a per-file sidecar JSON under the selected output tree using a name such as:

```text
season1\episode.encodeoptimizer.json
```

Reports include the source summary, selected samples, candidate evaluations, quality metrics, estimated size/savings, confidence, warnings, rationale, alternatives, and the exact final FFmpeg command when an encode is recommended. When search and verification produce materially different size estimates at the selected quality, the larger estimate is used for the savings decision and the disagreement is reported as a warning.

Local history may seed a future adaptive search for closely matching content classes, but history never bypasses measured verification.

## Stream, timing, and container safety

EncodeOptimizer is intentionally conservative about things that are easy to damage accidentally:

- Source files are never overwritten by default.
- Final AutoEncode output is written to a temporary file, probed and validated, then renamed into place.
- VFR is preserved; no unconditional `-r` or CFR conversion is inserted.
- Interlaced input is not automatically deinterlaced.
- Bit depth is not silently reduced.
- HDR is not silently tone-mapped to SDR.
- Audio is copied when container-compatible.
- Subtitles, metadata, chapters, dispositions, data streams, and Matroska attachments are preserved when feasible.
- If an MP4 output cannot safely retain an auxiliary stream, the automatic policy prefers Matroska rather than silently dropping it.
- Compatible HEVC-in-MP4 output uses `hvc1` tagging.

## HDR, Dolby Vision, and other edge cases

HDR quality evaluation is deliberately more cautious than ordinary SDR evaluation. Native high-bit-depth secondary metrics remain authoritative; SDR-model VMAF may be used only as advisory when the required deterministic tone-map path is available.

Automatic HDR encoding requires the explicit `-AllowHdrAutoEncode` override and receives a confidence penalty. Interlaced AutoEncode similarly requires `-AllowInterlacedAutoEncode`.

Dolby Vision automatic transcoding is blocked in the current release because preservation behavior is not treated as proven. AutoEncode based only on secondary metrics requires the explicit `-AllowSecondaryMetricsAutoEncode` override.

These overrides permit the corresponding guarded path; they do not disable quality measurement or output validation.

## CI and tests

The Windows GitHub Actions workflow runs unit and real FFmpeg integration jobs separately. The integration job installs `ffmpeg-full` 9.0.1 and currently exercises:

- real ffprobe normalization of generated H.264/AAC media;
- a real crop encode with copied audio and source-safety checks;
- source-relative metric execution through the installed FFmpeg filters;
- the public single-file analyze/report path;
- recursive batch filtering, per-file output reports, and a real second-run exact resume.

At the current branch revision the suite contains **82 passing unit tests and 6 passing real FFmpeg integration tests**. NVENC execution is not assumed on the hosted runner because it has no NVIDIA GPU; GPU-specific behavior is capability-gated and unit-tested through the discovered encoder policy.

## Design documents

The approved design and implementation plan are kept in the repository:

- `docs/superpowers/specs/2026-09-13-encode-optimizer-design.md`
- `docs/superpowers/plans/2026-09-13-encode-optimizer-implementation.md`

The implementation remains deliberately fail-safe: uncertainty should produce a warning, a lower-confidence recommendation, or `KEEP_SOURCE` rather than an undocumented conversion.
