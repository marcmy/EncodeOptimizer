Set-StrictMode -Version Latest

function Get-EOReportProperty {
    param($Object,[string]$Name,$Default=$null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [Collections.IDictionary] -and $Object.Contains($Name)) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function ConvertTo-EOCommandToken {
    param([AllowEmptyString()][string]$Value)
    if ($Value -eq '') { return "''" }
    if ($Value -match '^[A-Za-z0-9_./:\\-]+$') { return $Value }
    return "'" + $Value.Replace("'", "''") + "'"
}

function Join-EOCommandLine {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)
    return (@($Arguments | ForEach-Object { ConvertTo-EOCommandToken ([string]$_) }) -join ' ')
}

function New-EOReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$SourceProbe,
        [Parameter(Mandatory)][string]$ProfileName,
        [string]$EncoderName,
        [string[]]$EncoderRationale=@(),
        [Parameter(Mandatory)]$SamplePlan,
        [Parameter(Mandatory)]$SearchResult,
        $SizeEstimate,
        [Parameter(Mandatory)]$Confidence,
        [string[]]$Warnings=@(),
        [string[]]$FinalCommand=@(),
        $Alternatives
    )

    $video = $SourceProbe.Video
    $format = $SourceProbe.Format
    $duration = [double](Get-EOReportProperty $format 'Duration' (Get-EOReportProperty $video 'Duration' 0.0))
    $size = [long](Get-EOReportProperty $format 'Size' 0)
    $selectedEval = Get-EOReportProperty $SearchResult 'FinalEvaluation'
    $selectedQuality = Get-EOReportProperty $SearchResult 'SelectedQuality'
    $savings = Get-EOReportProperty $SearchResult 'SavingsRatio'
    $estimatedBytes = Get-EOReportProperty $SearchResult 'EstimatedBytes'
    if ($null -ne $SizeEstimate) { $estimatedBytes = Get-EOReportProperty $SizeEstimate 'EstimatedBytes' $estimatedBytes }

    $candidateRows = @((Get-EOReportProperty $SearchResult 'AllEvaluations' @()) | ForEach-Object {
        $aggregate = Get-EOReportProperty $_ 'Aggregate'
        $sampleRows = @((Get-EOReportProperty $aggregate 'Samples' @()) | ForEach-Object {
            [pscustomobject]@{
                Name=[string](Get-EOReportProperty $_ 'Name' ''); Start=Get-EOReportProperty $_ 'Start'; Duration=Get-EOReportProperty $_ 'Duration'
                FrameCount=[int](Get-EOReportProperty $_ 'FrameCount' 0); MeanVmaf=Get-EOReportProperty $_ 'MeanVmaf'; P05Vmaf=Get-EOReportProperty $_ 'P05Vmaf'
                BaselineMeanVmaf=Get-EOReportProperty $_ 'BaselineMeanVmaf'; RelativeMeanVmaf=Get-EOReportProperty $_ 'RelativeMeanVmaf'; RelativeP05Vmaf=Get-EOReportProperty $_ 'RelativeP05Vmaf'
                MinimumVmaf=Get-EOReportProperty $_ 'MinimumVmaf'; MeanXpsnr=Get-EOReportProperty $_ 'MeanXpsnr'; MeanSsim=Get-EOReportProperty $_ 'MeanSsim'; MeanPsnr=Get-EOReportProperty $_ 'MeanPsnr'
                CandidateBytes=Get-EOReportProperty $_ 'CandidateBytes'; CandidateKbps=Get-EOReportProperty $_ 'CandidateKbps'
            }
        })
        [pscustomobject]@{
            Phase=Get-EOReportProperty $_ 'Phase'; Quality=Get-EOReportProperty $_ 'Quality'; Passed=[bool](Get-EOReportProperty $_ 'Passed' $false)
            MeanVmaf=Get-EOReportProperty $_ 'MeanVmaf'; WorstSampleVmaf=Get-EOReportProperty $_ 'WorstSampleVmaf'; P05Vmaf=Get-EOReportProperty $_ 'P05Vmaf'
            RelativeMeanVmaf=Get-EOReportProperty $_ 'RelativeMeanVmaf'; RelativeWorstSampleVmaf=Get-EOReportProperty $_ 'RelativeWorstSampleVmaf'; RelativeP05Vmaf=Get-EOReportProperty $_ 'RelativeP05Vmaf'
            MinimumMargin=Get-EOReportProperty $_ 'MinimumMargin'; EstimatedBytes=Get-EOReportProperty $_ 'EstimatedBytes'; Samples=$sampleRows
        }
    })

    $selected = if ($null -ne $selectedQuality) { [pscustomobject]@{ Quality=[int]$selectedQuality; Metrics=$selectedEval } } else { $null }
    $commandArguments = @($FinalCommand)
    [pscustomobject]@{
        SchemaVersion=2; GeneratedAt=[DateTimeOffset]::UtcNow.ToString('o'); Decision=[string](Get-EOReportProperty $SearchResult 'Decision' 'UNKNOWN'); Profile=$ProfileName
        Source=[pscustomobject]@{
            Path=[string](Get-EOReportProperty $SourceProbe 'Path' ''); SizeBytes=$size; Duration=$duration
            Video=[pscustomobject]@{
                Codec=[string](Get-EOReportProperty $video 'CodecName' ''); Profile=[string](Get-EOReportProperty $video 'Profile' '')
                Resolution="$(Get-EOReportProperty $video 'Width' 0)x$(Get-EOReportProperty $video 'Height' 0)"; Width=[int](Get-EOReportProperty $video 'Width' 0); Height=[int](Get-EOReportProperty $video 'Height' 0); Duration=[double](Get-EOReportProperty $video 'Duration' 0.0)
                Fps=[double](Get-EOReportProperty $video 'FrameRate' 0.0); BitDepth=[int](Get-EOReportProperty $video 'BitDepth' 0); PixelFormat=[string](Get-EOReportProperty $video 'PixelFormat' '')
                HdrKind=[string](Get-EOReportProperty $video 'HdrKind' 'SDR'); IsVfr=[bool](Get-EOReportProperty $video 'IsVfr' $false)
            }
            AudioStreams=@($SourceProbe.Audio).Count; SubtitleStreams=@($SourceProbe.Subtitles).Count; Attachments=@($SourceProbe.Attachments).Count; Chapters=@($SourceProbe.Chapters).Count
        }
        Encoder=[pscustomobject]@{ Name=$EncoderName; Rationale=@($EncoderRationale) }
        Samples=[pscustomobject]@{ Search=@((Get-EOReportProperty $SamplePlan 'SearchSamples' @())); Verification=@((Get-EOReportProperty $SamplePlan 'VerificationSamples' @())) }
        Candidates=$candidateRows; Selected=$selected
        EstimatedSavings=[pscustomobject]@{ Ratio=$savings; EstimatedBytes=$estimatedBytes; LowerBytes=Get-EOReportProperty $SizeEstimate 'LowerBytes'; UpperBytes=Get-EOReportProperty $SizeEstimate 'UpperBytes'; VideoKbps=Get-EOReportProperty $SizeEstimate 'VideoKbps' }
        Confidence=$Confidence; Warnings=@($Warnings); Rationale=@((Get-EOReportProperty $SearchResult 'Rationale' @()))
        FinalCommand=[pscustomobject]@{ Arguments=$commandArguments; Text=if ($commandArguments.Count) { Join-EOCommandLine $commandArguments } else { '' } }
        Alternatives=$Alternatives
    }
}

function Format-EOByteSize {
    param($Value)
    if ($null -eq $Value) { return 'n/a' }
    $bytes=[double]$Value
    if ($bytes -ge 1GB) { return ('{0:N2} GiB' -f ($bytes/1GB)) }
    if ($bytes -ge 1MB) { return ('{0:N1} MiB' -f ($bytes/1MB)) }
    if ($bytes -ge 1KB) { return ('{0:N1} KiB' -f ($bytes/1KB)) }
    return ('{0:N0} B' -f $bytes)
}

function Format-EOHumanReport {
    [CmdletBinding()] param([Parameter(Mandatory)]$Report)
    $lines=[System.Collections.Generic.List[string]]::new()
    $lines.Add('EncodeOptimizer'); $lines.Add(('='*72)); $lines.Add("Decision : $($Report.Decision)"); $lines.Add("Source   : $($Report.Source.Path)")
    $lines.Add("Video    : $($Report.Source.Video.Codec) $($Report.Source.Video.Resolution) $([math]::Round([double]$Report.Source.Video.Fps,3)) fps, $($Report.Source.Video.BitDepth)-bit, $($Report.Source.Video.HdrKind)")
    $lines.Add("Profile  : $($Report.Profile)"); if ($Report.Encoder -and $Report.Encoder.Name) { $lines.Add("Encoder  : $($Report.Encoder.Name)") }
    if ($null -ne $Report.Selected) {
        $lines.Add("Quality  : $($Report.Selected.Quality)"); $m=$Report.Selected.Metrics
        if ($m) {
            if ($null -ne (Get-EOReportProperty $m 'MeanVmaf')) { $lines.Add("VMAF     : mean $([math]::Round([double]$m.MeanVmaf,3)), worst sample $([math]::Round([double]$m.WorstSampleVmaf,3)), P05 $([math]::Round([double]$m.P05Vmaf,3))") }
            if ($null -ne (Get-EOReportProperty $m 'RelativeMeanVmaf')) { $lines.Add("VMAF rel : mean $([math]::Round([double]$m.RelativeMeanVmaf,3)), worst sample $([math]::Round([double]$m.RelativeWorstSampleVmaf,3)), P05 $([math]::Round([double]$m.RelativeP05Vmaf,3))") }
            if ($null -ne (Get-EOReportProperty $m 'MeanXpsnr')) { $lines.Add("XPSNR    : $([math]::Round([double]$m.MeanXpsnr,3)) dB") }
            if ($null -ne (Get-EOReportProperty $m 'MeanSsim')) { $lines.Add("SSIM     : $([math]::Round([double]$m.MeanSsim,6))") }
            if ($null -ne (Get-EOReportProperty $m 'MeanPsnr')) { $lines.Add("PSNR     : $([math]::Round([double]$m.MeanPsnr,3)) dB") }
        }
    }
    if ($Report.EstimatedSavings) {
        $ratio=Get-EOReportProperty $Report.EstimatedSavings 'Ratio'; if ($null -ne $ratio) { $lines.Add("Savings  : ~$([math]::Round([double]$ratio*100,1))%") }
        $estimated=Get-EOReportProperty $Report.EstimatedSavings 'EstimatedBytes'
        if ($null -ne $estimated) { $low=Get-EOReportProperty $Report.EstimatedSavings 'LowerBytes'; $high=Get-EOReportProperty $Report.EstimatedSavings 'UpperBytes'; $sizeText=Format-EOByteSize $estimated; if ($null -ne $low -and $null -ne $high) { $sizeText += " ($(Format-EOByteSize $low) - $(Format-EOByteSize $high))" }; $lines.Add("Est size : $sizeText") }
    }
    if ($Report.Confidence) { $lines.Add("Confidence: $($Report.Confidence.Label) ($([math]::Round([double]$Report.Confidence.Score*100,0))%)") }
    if (@($Report.Rationale).Count) { $lines.Add(''); $lines.Add('Rationale:'); foreach ($reason in @($Report.Rationale)) { $lines.Add("  - $reason") } }
    if (@($Report.Warnings).Count) { $lines.Add(''); $lines.Add('Warnings:'); foreach ($warning in @($Report.Warnings)) { $lines.Add("  - $warning") } }
    if ($Report.FinalCommand -and $Report.FinalCommand.Text) { $lines.Add(''); $lines.Add('Final command:'); $lines.Add("  $($Report.FinalCommand.Text)") }
    return ($lines -join [Environment]::NewLine)
}

function Write-EOReport {
    [CmdletBinding()] param([Parameter(Mandatory)]$Report,[Parameter(Mandatory)][string]$Path)
    $directory=Split-Path -Parent $Path; if ($directory) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $temporary=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try { [IO.File]::WriteAllText($temporary,($Report|ConvertTo-Json -Depth 100),[Text.UTF8Encoding]::new($false)); Move-Item -LiteralPath $temporary -Destination $Path -Force }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue } }
    return $Path
}

Export-ModuleMember -Function New-EOReport,Format-EOHumanReport,Write-EOReport,Join-EOCommandLine
