[CmdletBinding()]
param(
    [Parameter(Mandatory,Position=0)][string]$Path,
    [switch]$Recurse,
    [ValidateSet('Conservative','Balanced','Aggressive')][string]$Profile='Conservative',
    [string]$Encoder,
    [ValidateSet('h264','hevc','av1')][string]$Codec,
    [string]$VideoFilter,
    [switch]$AutoEncode,
    [int]$GpuConcurrency=2,
    [int]$CpuConcurrency=1,
    [switch]$AllowHdrAutoEncode,
    [switch]$AllowInterlacedAutoEncode,
    [switch]$AllowSecondaryMetricsAutoEncode,
    [string]$FFmpegPath,
    [string]$FFprobePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

foreach($moduleName in 'Batch','Capability','Probe','EncoderProfiles','Metrics','Safety') {
    Import-Module (Join-Path $PSScriptRoot "lib\$moduleName.psm1") -Force
}

$singleScript=Join-Path $PSScriptRoot 'Optimize-Video.ps1'
$files=@(Get-EOMediaFiles -Path $Path -Recurse:$Recurse)
if ($files.Count -eq 0) { throw "No supported media files found under '$Path'." }

$resolvedFFmpeg=Get-EOExecutable -Name 'ffmpeg' -ExplicitPath $FFmpegPath
$resolvedFFprobe=Get-EOExecutable -Name 'ffprobe' -ExplicitPath $FFprobePath
$capabilities=Get-EOCapabilities -FFmpegPath $resolvedFFmpeg
$items=[System.Collections.Generic.List[object]]::new()

Write-Host "Classifying $($files.Count) file(s)..."
foreach($file in $files) {
    try {
        $probe=Get-EOSourceProbe -Path $file.FullName -FFprobePath $resolvedFFprobe
        $candidates=@(Get-EOEncoderCandidates -SourceProbe $probe -Capabilities $capabilities -Encoder $Encoder -Codec $Codec)
        $encoderName=if($candidates.Count){ [string]$candidates[0] }else{'KEEP_SOURCE'}
        $hardware=$false
        if($encoderName -ne 'KEEP_SOURCE') {
            $resolvedProfile=Resolve-EOEncoderProfile -Name $encoderName -Capabilities $capabilities -SourceProbe $probe
            $hardware=[bool]$resolvedProfile.Hardware
        }
        $metricPlan=Get-EOMetricPlan -SourceProbe $probe -Capabilities $capabilities -VideoFilter $VideoFilter
        $gate=Get-EOSafetyGate -SourceProbe $probe -MetricPlan $metricPlan -AllowHdrAutoEncode:$AllowHdrAutoEncode -AllowInterlacedAutoEncode:$AllowInterlacedAutoEncode -AllowSecondaryMetricsAutoEncode:$AllowSecondaryMetricsAutoEncode
        $blocked=[bool]($AutoEncode -and -not $gate.AutoEncodeAllowed)
        $reason=if($blocked){ @($gate.Reasons) -join '; ' }else{''}
        $items.Add([pscustomobject]@{ Path=$file.FullName; Encoder=$encoderName; Hardware=$hardware; Blocked=$blocked; Reason=$reason; Safety=$gate })
    } catch {
        $items.Add([pscustomobject]@{ Path=$file.FullName; Encoder=''; Hardware=$false; Blocked=$true; Reason=$_.Exception.Message; Safety=$null })
    }
}

$plan=New-EOBatchPlan -Items @($items) -GpuConcurrency $GpuConcurrency -CpuConcurrency $CpuConcurrency
Write-Host "Batch plan: $($plan.GPU.Count) GPU, $($plan.CPU.Count) CPU, $($plan.Blocked.Count) blocked; GPU concurrency $($plan.GpuConcurrency), CPU concurrency $($plan.CpuConcurrency)."
foreach($blocked in $plan.Blocked) { Write-Warning "BLOCKED: $($blocked.Path) — $($blocked.Reason)" }

$shared=@{
    Script=$singleScript; Profile=$Profile; Encoder=$Encoder; Codec=$Codec; VideoFilter=$VideoFilter
    AutoEncode=[bool]$AutoEncode; AllowHdr=[bool]$AllowHdrAutoEncode; AllowInterlaced=[bool]$AllowInterlacedAutoEncode
    AllowSecondary=[bool]$AllowSecondaryMetricsAutoEncode; FFmpeg=$resolvedFFmpeg; FFprobe=$resolvedFFprobe
}

function Invoke-EOBatchGroup {
    param([object[]]$Group,[int]$Throttle,[hashtable]$Shared)
    if($Group.Count -eq 0){ return @() }
    $scriptPath=$Shared.Script; $profileName=$Shared.Profile; $encoderOverride=$Shared.Encoder; $codecOverride=$Shared.Codec; $filter=$Shared.VideoFilter
    $doAuto=$Shared.AutoEncode; $allowHdr=$Shared.AllowHdr; $allowInterlaced=$Shared.AllowInterlaced; $allowSecondary=$Shared.AllowSecondary
    $ffmpeg=$Shared.FFmpeg; $ffprobe=$Shared.FFprobe

    return @($Group | ForEach-Object -Parallel {
        $arguments=@{
            Path=$_.Path; Profile=$using:profileName; BatchMode=$true; FFmpegPath=$using:ffmpeg; FFprobePath=$using:ffprobe
            AutoEncode=$using:doAuto; AllowHdrAutoEncode=$using:allowHdr; AllowInterlacedAutoEncode=$using:allowInterlaced
            AllowSecondaryMetricsAutoEncode=$using:allowSecondary
        }
        if(-not [string]::IsNullOrWhiteSpace($using:encoderOverride)){ $arguments.Encoder=$using:encoderOverride }
        if(-not [string]::IsNullOrWhiteSpace($using:codecOverride)){ $arguments.Codec=$using:codecOverride }
        if(-not [string]::IsNullOrWhiteSpace($using:filter)){ $arguments.VideoFilter=$using:filter }
        try {
            & $using:scriptPath @arguments
        } catch {
            [pscustomobject]@{ Decision='ERROR'; Source=[pscustomobject]@{ Path=$_.Path }; Error=$_.Exception.Message }
        }
    } -ThrottleLimit $Throttle)
}

# Hardware and software workloads deliberately have independent limits. They are
# processed as separate queues so a CPU-heavy software transcode cannot multiply
# itself merely because several GPU slots are available.
$results=[System.Collections.Generic.List[object]]::new()
foreach($result in @(Invoke-EOBatchGroup -Group @($plan.GPU) -Throttle $plan.GpuConcurrency -Shared $shared)){ $results.Add($result) }
foreach($result in @(Invoke-EOBatchGroup -Group @($plan.CPU) -Throttle $plan.CpuConcurrency -Shared $shared)){ $results.Add($result) }
foreach($blocked in $plan.Blocked){ $results.Add([pscustomobject]@{ Decision='BLOCKED'; Source=[pscustomobject]@{ Path=$blocked.Path }; Error=$blocked.Reason }) }

Write-Host "`nBatch complete: $($results.Count) result(s)."
$results | Group-Object Decision | ForEach-Object { Write-Host ("  {0,-12} {1,4}" -f $_.Name,$_.Count) }
return @($results)
