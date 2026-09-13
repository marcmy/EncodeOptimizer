[CmdletBinding()]
param(
    [Parameter(Mandatory,Position=0)][string]$Path,
    [switch]$Recurse,
    [string[]]$Include,
    [string[]]$Exclude,
    [string]$OutputDirectory,
    [switch]$Resume,
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

foreach($moduleName in 'Batch','Capability','Probe','EncoderProfiles','Metrics','Safety','Cache','Streams') {
    Import-Module (Join-Path $PSScriptRoot "lib\$moduleName.psm1") -Force
}

$singleScript=Join-Path $PSScriptRoot 'Optimize-Video.ps1'
$inputItem=Get-Item -LiteralPath $Path -ErrorAction Stop
$inputRoot=if($inputItem.PSIsContainer){ $inputItem.FullName }else{ $inputItem.Directory.FullName }
$files=@(Get-EOMediaFiles -Path $Path -Recurse:$Recurse -Include $Include -Exclude $Exclude)
if ($files.Count -eq 0) { throw "No supported media files found under '$Path' after include/exclude filtering." }

$outputRoot=if([string]::IsNullOrWhiteSpace($OutputDirectory)){ $inputRoot }else{ [IO.Path]::GetFullPath($OutputDirectory) }
if(-not [string]::IsNullOrWhiteSpace($OutputDirectory)){ New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null }

# If an explicit output directory lives under the scanned input root, never feed
# previously generated media back into the same recursive batch.
if($inputItem.PSIsContainer -and -not [string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $relativeOutput=[IO.Path]::GetRelativePath($inputRoot,$outputRoot)
    if($relativeOutput -ne '.' -and -not $relativeOutput.StartsWith('..')) {
        $outputPrefix=$outputRoot.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
        $files=@($files | Where-Object { -not $_.FullName.StartsWith($outputPrefix,[StringComparison]::OrdinalIgnoreCase) })
        if($files.Count -eq 0){ throw "No supported source media files remain after excluding OutputDirectory '$outputRoot'." }
    }
}

$qualityProfiles=Import-PowerShellDataFile (Join-Path $PSScriptRoot 'config\quality-profiles.psd1')
$policy=$qualityProfiles[$Profile]
if($null -eq $policy){ throw "Unknown quality profile '$Profile'." }
$policySignature=([ordered]@{
    MeanVmaf=$policy.MeanVmaf; WorstSampleVmaf=$policy.WorstSampleVmaf; P05Vmaf=$policy.P05Vmaf
    MinimumXpsnr=$policy.MinimumXpsnr; MinimumSsim=$policy.MinimumSsim; MinimumPsnr=$policy.MinimumPsnr
    MinimumSecondaryMetrics=$policy.MinimumSecondaryMetrics; MinimumConfidence=$policy.MinimumConfidence
    BatchAutoConfidence=$policy.BatchAutoConfidence; MinimumSavingsRatio=$policy.MinimumSavingsRatio
    ComfortableMargin=$policy.ComfortableMargin; VerificationMargin=$policy.VerificationMargin
} | ConvertTo-Json -Compress -Depth 8)

$resolvedFFmpeg=Get-EOExecutable -Name 'ffmpeg' -ExplicitPath $FFmpegPath
$resolvedFFprobe=Get-EOExecutable -Name 'ffprobe' -ExplicitPath $FFprobePath
$capabilities=Get-EOCapabilities -FFmpegPath $resolvedFFmpeg
$items=[System.Collections.Generic.List[object]]::new()
$resumedResults=[System.Collections.Generic.List[object]]::new()
$reservedOutputs=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$reservedReports=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

Write-Host "Classifying $($files.Count) file(s)..."
foreach($file in $files) {
    try {
        $probe=Get-EOSourceProbe -Path $file.FullName -FFprobePath $resolvedFFprobe
        $candidates=@(Get-EOEncoderCandidates -SourceProbe $probe -Capabilities $capabilities -Encoder $Encoder -Codec $Codec)
        $encoderName=if($candidates.Count){ [string]$candidates[0] }else{'KEEP_SOURCE'}
        $hardware=$false
        $resolvedProfile=$null
        $containerPlan=$null
        $encoderSignature='KEEP_SOURCE'
        $outputPath=$null

        if($encoderName -ne 'KEEP_SOURCE') {
            $resolvedProfile=Resolve-EOEncoderProfile -Name $encoderName -Capabilities $capabilities -SourceProbe $probe
            $hardware=[bool]$resolvedProfile.Hardware
            $containerPlan=Get-EOContainerPlan -SourceProbe $probe -EncoderProfile $resolvedProfile
            $encoderSignature=([ordered]@{
                Name=[string]$resolvedProfile.Name; Codec=[string]$resolvedProfile.Codec; QualityControl=[string]$resolvedProfile.QualityControl
                QualityOption=[string]$resolvedProfile.QualityOption; SearchMinimum=[int]$resolvedProfile.SearchMinimum; SearchMaximum=[int]$resolvedProfile.SearchMaximum
                DefaultStart=[int]$resolvedProfile.DefaultStart; BetterDirection=[string]$resolvedProfile.BetterDirection; Hardware=[bool]$resolvedProfile.Hardware
                Arguments=@($resolvedProfile.Arguments); PixelFormats=@($resolvedProfile.PixelFormats)
            } | ConvertTo-Json -Compress -Depth 8)

            $outputPath=Get-EOBatchOutputPath -InputPath $file.FullName -InputRoot $inputRoot -OutputDirectory $outputRoot -Extension $containerPlan.Extension
            if($reservedOutputs.Contains([IO.Path]::GetFullPath($outputPath))) {
                $targetDirectory=Split-Path -Parent $outputPath
                $stem=[IO.Path]::GetFileNameWithoutExtension($file.FullName)
                $extension=[string]$containerPlan.Extension
                $suffix=2
                do {
                    $outputPath=Join-Path $targetDirectory ($stem+".optimized.$suffix"+$extension)
                    $suffix++
                } while((Test-Path -LiteralPath $outputPath) -or $reservedOutputs.Contains([IO.Path]::GetFullPath($outputPath)))
            }
            [void]$reservedOutputs.Add([IO.Path]::GetFullPath($outputPath))
        }

        $metricPlan=Get-EOMetricPlan -SourceProbe $probe -Capabilities $capabilities -VideoFilter $VideoFilter
        $gate=Get-EOSafetyGate -SourceProbe $probe -MetricPlan $metricPlan -AllowHdrAutoEncode:$AllowHdrAutoEncode -AllowInterlacedAutoEncode:$AllowInterlacedAutoEncode -AllowSecondaryMetricsAutoEncode:$AllowSecondaryMetricsAutoEncode
        $blocked=[bool]($AutoEncode -and -not $gate.AutoEncodeAllowed)
        $reason=if($blocked){ @($gate.Reasons) -join '; ' }else{''}

        $sourceFingerprint=Get-EOSourceFingerprint -Path $file.FullName
        $resumeSignature=Get-EOBatchResumeSignature -SourceFingerprint $sourceFingerprint -Profile $Profile -EncoderName $encoderName -EncoderSignature $encoderSignature -PolicySignature $policySignature -VideoFilter $VideoFilter -FFmpegVersion ([string]$capabilities.Version) -OutputRoot $outputRoot -AutoEncode ([bool]$AutoEncode) -AllowHdr ([bool]$AllowHdrAutoEncode) -AllowInterlaced ([bool]$AllowInterlacedAutoEncode) -AllowSecondary ([bool]$AllowSecondaryMetricsAutoEncode)

        $reportPath=Get-EOBatchReportPath -InputPath $file.FullName -InputRoot $inputRoot -OutputDirectory $outputRoot
        if($reservedReports.Contains([IO.Path]::GetFullPath($reportPath))) {
            $directory=Split-Path -Parent $reportPath
            $base=[IO.Path]::GetFileNameWithoutExtension($reportPath)
            $shortHash=([string]$sourceFingerprint.Hash).Substring(0,[math]::Min(12,([string]$sourceFingerprint.Hash).Length))
            $reportPath=Join-Path $directory ($base+'.'+$shortHash+'.json')
        }
        [void]$reservedReports.Add([IO.Path]::GetFullPath($reportPath))

        if($Resume -and -not $blocked) {
            $resumeRecord=Get-EOBatchResumeRecord -ReportPath $reportPath -Signature $resumeSignature -RequireValidatedOutput:$AutoEncode
            if($null -ne $resumeRecord) {
                $resumeRecord.BatchResume | Add-Member -NotePropertyName Resumed -NotePropertyValue $true -Force
                $resumedResults.Add($resumeRecord)
                Write-Host "RESUME: $($file.FullName)"
                continue
            }
        }

        $items.Add([pscustomobject]@{
            Path=$file.FullName; Encoder=$encoderName; Hardware=$hardware; Blocked=$blocked; Reason=$reason; Safety=$gate
            OutputPath=$outputPath; ReportPath=$reportPath; ResumeSignature=$resumeSignature; SourceFingerprint=$sourceFingerprint
        })
    } catch {
        $items.Add([pscustomobject]@{ Path=$file.FullName; Encoder=''; Hardware=$false; Blocked=$true; Reason=$_.Exception.Message; Safety=$null; OutputPath=$null; ReportPath=$null; ResumeSignature=$null; SourceFingerprint=$null })
    }
}

$plan=New-EOBatchPlan -Items @($items) -GpuConcurrency $GpuConcurrency -CpuConcurrency $CpuConcurrency
Write-Host "Batch plan: $($plan.GPU.Count) GPU, $($plan.CPU.Count) CPU, $($plan.Blocked.Count) blocked, $($resumedResults.Count) resumed; GPU concurrency $($plan.GpuConcurrency), CPU concurrency $($plan.CpuConcurrency)."
foreach($blocked in $plan.Blocked) { Write-Warning "BLOCKED: $($blocked.Path) — $($blocked.Reason)" }

$shared=@{
    Script=$singleScript; Profile=$Profile; Codec=$Codec; VideoFilter=$VideoFilter
    AutoEncode=[bool]$AutoEncode; AllowHdr=[bool]$AllowHdrAutoEncode; AllowInterlaced=[bool]$AllowInterlacedAutoEncode
    AllowSecondary=[bool]$AllowSecondaryMetricsAutoEncode; FFmpeg=$resolvedFFmpeg; FFprobe=$resolvedFFprobe
}

function Invoke-EOBatchGroup {
    param([object[]]$Group,[int]$Throttle,[hashtable]$Shared)
    if($Group.Count -eq 0){ return @() }
    $scriptPath=$Shared.Script; $profileName=$Shared.Profile; $codecOverride=$Shared.Codec; $filter=$Shared.VideoFilter
    $doAuto=$Shared.AutoEncode; $allowHdr=$Shared.AllowHdr; $allowInterlaced=$Shared.AllowInterlaced; $allowSecondary=$Shared.AllowSecondary
    $ffmpeg=$Shared.FFmpeg; $ffprobe=$Shared.FFprobe

    return @($Group | ForEach-Object -Parallel {
        $item=$_
        $arguments=@{
            Path=$item.Path; Profile=$using:profileName; BatchMode=$true; FFmpegPath=$using:ffmpeg; FFprobePath=$using:ffprobe
            AutoEncode=$using:doAuto; AllowHdrAutoEncode=$using:allowHdr; AllowInterlacedAutoEncode=$using:allowInterlaced
            AllowSecondaryMetricsAutoEncode=$using:allowSecondary
        }
        if(-not [string]::IsNullOrWhiteSpace([string]$item.Encoder) -and [string]$item.Encoder -ne 'KEEP_SOURCE'){ $arguments.Encoder=[string]$item.Encoder }
        elseif(-not [string]::IsNullOrWhiteSpace($using:codecOverride)){ $arguments.Codec=$using:codecOverride }
        if(-not [string]::IsNullOrWhiteSpace($using:filter)){ $arguments.VideoFilter=$using:filter }
        if(-not [string]::IsNullOrWhiteSpace([string]$item.OutputPath)){ $arguments.OutputPath=[string]$item.OutputPath }

        try {
            $result=& $using:scriptPath @arguments
            $outputValidated=$false
            if($using:doAuto -and [string]$result.Decision -eq 'ENCODE' -and -not [string]::IsNullOrWhiteSpace([string]$item.OutputPath)) {
                $outputValidated=Test-Path -LiteralPath ([string]$item.OutputPath) -PathType Leaf
            }
            $batchResume=[pscustomobject]@{
                Signature=[string]$item.ResumeSignature
                SourceHash=[string]$item.SourceFingerprint.Hash
                SourceSize=[long]$item.SourceFingerprint.Size
                OutputPath=[string]$item.OutputPath
                OutputValidated=[bool]$outputValidated
                ReportPath=[string]$item.ReportPath
                RecordedAt=[DateTimeOffset]::UtcNow.ToString('o')
                Resumed=$false
            }
            $result | Add-Member -NotePropertyName BatchResume -NotePropertyValue $batchResume -Force

            if(-not [string]::IsNullOrWhiteSpace([string]$item.ReportPath)) {
                $directory=Split-Path -Parent ([string]$item.ReportPath)
                if($directory){ New-Item -ItemType Directory -Path $directory -Force | Out-Null }
                $temporary=([string]$item.ReportPath)+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
                try {
                    [IO.File]::WriteAllText($temporary,($result | ConvertTo-Json -Depth 100),[Text.UTF8Encoding]::new($false))
                    Move-Item -LiteralPath $temporary -Destination ([string]$item.ReportPath) -Force
                } finally {
                    if(Test-Path -LiteralPath $temporary){ Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
                }
            }
            return $result
        } catch {
            return [pscustomobject]@{ Decision='ERROR'; Source=[pscustomobject]@{ Path=$item.Path }; Error=$_.Exception.Message }
        }
    } -ThrottleLimit $Throttle)
}

# Hardware and software workloads deliberately have independent limits. They are
# processed as separate queues so a CPU-heavy software transcode cannot multiply
# itself merely because several GPU slots are available.
$results=[System.Collections.Generic.List[object]]::new()
foreach($resumed in $resumedResults){ $results.Add($resumed) }
foreach($result in @(Invoke-EOBatchGroup -Group @($plan.GPU) -Throttle $plan.GpuConcurrency -Shared $shared)){ $results.Add($result) }
foreach($result in @(Invoke-EOBatchGroup -Group @($plan.CPU) -Throttle $plan.CpuConcurrency -Shared $shared)){ $results.Add($result) }
foreach($blocked in $plan.Blocked){ $results.Add([pscustomobject]@{ Decision='BLOCKED'; Source=[pscustomobject]@{ Path=$blocked.Path }; Error=$blocked.Reason }) }

Write-Host "`nBatch complete: $($results.Count) result(s)."
$results | Group-Object Decision | ForEach-Object { Write-Host ("  {0,-12} {1,4}" -f $_.Name,$_.Count) }
return @($results)
