Describe 'real FFmpeg integration' -Tag 'Integration' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        foreach ($moduleName in 'Capability','Probe','EncoderProfiles','Streams','Metrics') {
            Import-Module (Join-Path $repoRoot "lib\$moduleName.psm1") -Force
        }

        $script:ffmpeg = (Get-Command ffmpeg -CommandType Application -ErrorAction Stop).Source
        $script:ffprobe = (Get-Command ffprobe -CommandType Application -ErrorAction Stop).Source
        $script:capabilities = Get-EOCapabilities -FFmpegPath $script:ffmpeg

        if (@($script:capabilities.Encoders) -notcontains 'libx264') {
            throw 'Integration suite requires the software encoder libx264.'
        }

        $script:root = Join-Path ([IO.Path]::GetTempPath()) ('EncodeOptimizer-integration-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
        $script:source = Join-Path $script:root 'source.mp4'

        $fixtureArgs = @(
            '-hide_banner','-loglevel','error',
            '-f','lavfi','-i','testsrc2=size=320x180:rate=30:duration=12',
            '-f','lavfi','-i','sine=frequency=1000:sample_rate=48000:duration=12',
            '-c:v','libx264','-preset','veryfast','-crf','12','-pix_fmt','yuv420p',
            '-c:a','aac','-b:a','96k','-shortest',
            '-metadata','title=EncodeOptimizer Integration Fixture',
            $script:source
        )
        $fixtureOutput = & $script:ffmpeg @fixtureArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to generate integration fixture.`n$($fixtureOutput -join [Environment]::NewLine)"
        }

        $script:sourceProbe = Get-EOSourceProbe -Path $script:source -FFprobePath $script:ffprobe
    }

    AfterAll {
        if ($script:root -and (Test-Path -LiteralPath $script:root)) {
            Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'probes a deterministic source with real video and audio streams' {
        $script:sourceProbe.Video.CodecName | Should -Be 'h264'
        $script:sourceProbe.Video.Width | Should -Be 320
        $script:sourceProbe.Video.Height | Should -Be 180
        @($script:sourceProbe.Audio).Count | Should -Be 1
        ([math]::Abs([double]$script:sourceProbe.Video.FrameRate - 30.0) -lt 0.01) | Should -BeTrue
    }

    It 'executes a real crop encode while preserving copied audio and source safety' {
        $profile = Resolve-EOEncoderProfile -Name 'libx264' -Capabilities $script:capabilities -SourceProbe $script:sourceProbe
        $container = Get-EOContainerPlan -SourceProbe $script:sourceProbe -EncoderProfile $profile
        $streams = Get-EOStreamPlan -SourceProbe $script:sourceProbe -ContainerPlan $container
        $output = Join-Path $script:root ('cropped' + $container.Extension)

        $args = @(New-EOFinalEncodeArguments -InputPath $script:source -OutputPath $output -SourceProbe $script:sourceProbe -EncoderProfile $profile -ContainerPlan $container -StreamPlan $streams -Quality 14 -VideoFilter 'crop=160:180:80:0')
        $encodeOutput = & $script:ffmpeg @args 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Filtered integration encode failed.`n$($encodeOutput -join [Environment]::NewLine)"
        }

        Test-Path -LiteralPath $script:source | Should -BeTrue
        Test-Path -LiteralPath $output | Should -BeTrue
        $probe = Get-EOSourceProbe -Path $output -FFprobePath $script:ffprobe
        $probe.Video.Width | Should -Be 160
        $probe.Video.Height | Should -Be 180
        @($probe.Audio).Count | Should -Be @($script:sourceProbe.Audio).Count
        ([int]$probe.Video.BitDepth -ge [int]$script:sourceProbe.Video.BitDepth) | Should -BeTrue
        ([math]::Abs([double]$probe.Format.Duration - [double]$script:sourceProbe.Format.Duration) -le 0.5) | Should -BeTrue

        $script:croppedOutput = $output
    }

    It 'compares the cropped encode against the identically transformed source with real metrics' {
        if (-not $script:croppedOutput -or -not (Test-Path -LiteralPath $script:croppedOutput)) {
            throw 'The cropped integration output was not created by the previous test.'
        }

        $plan = Get-EOMetricPlan -SourceProbe $script:sourceProbe -Capabilities $script:capabilities -VideoFilter 'crop=160:180:80:0'
        $metrics = Invoke-EOMetrics -ReferencePath $script:source -CandidatePath $script:croppedOutput -MetricPlan $plan -ReferenceStart 0 -Duration 4 -SampleName 'integration-crop' -FFmpegPath $script:ffmpeg -WorkDirectory (Join-Path $script:root 'metric-work')
        $aggregate = Measure-EOMetricAggregate -Samples @($metrics) -VmafRole $plan.VmafRole

        $aggregate.FrameCount | Should -BeGreaterThan 0
        $available = @($aggregate.MeanVmaf,$aggregate.MeanXpsnr,$aggregate.MeanSsim,$aggregate.MeanPsnr | Where-Object { $null -ne $_ })
        $available.Count | Should -BeGreaterThan 0
        if ($null -ne $aggregate.MeanVmaf) { ($aggregate.MeanVmaf -gt 90.0) | Should -BeTrue }
        if ($null -ne $aggregate.MeanSsim) { ($aggregate.MeanSsim -gt 0.95) | Should -BeTrue }
    }

    It 'runs the public analyze path and persists a machine-readable report' {
        $oldLocalAppData = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = Join-Path $script:root 'localappdata'
        try {
            $optimizer = Join-Path $repoRoot 'Optimize-Video.ps1'
            $report = & $optimizer -Path $script:source -Profile Aggressive -Encoder libx264 -FFmpegPath $script:ffmpeg -FFprobePath $script:ffprobe

            $report | Should -Not -BeNullOrEmpty
            $report.SchemaVersion | Should -Be 1
            $report.Source.Path | Should -Be ([IO.Path]::GetFullPath($script:source))
            $report.Decision | Should -BeIn @('ENCODE','KEEP_SOURCE')
            @($report.Candidates).Count | Should -BeGreaterThan 0

            $jsonReports = @(Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'EncodeOptimizer\work') -Filter report.json -Recurse -File -ErrorAction Stop)
            $jsonReports.Count | Should -BeGreaterThan 0
            $persisted = Get-Content -LiteralPath ($jsonReports | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).FullName -Raw | ConvertFrom-Json -Depth 100
            $persisted.SchemaVersion | Should -Be 1
            $persisted.Source.Path | Should -Be ([IO.Path]::GetFullPath($script:source))
            $persisted.Decision | Should -Be $report.Decision
        } finally {
            $env:LOCALAPPDATA = $oldLocalAppData
        }
    }
}
