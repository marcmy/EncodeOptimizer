BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\lib\Batch.psm1'
    if (Test-Path $modulePath) { Import-Module $modulePath -Force }
}

Describe 'batch optimizer planning' {
    It 'provides media discovery and batch planning commands' {
        Test-Path $modulePath | Should -BeTrue
        foreach ($name in 'Get-EOMediaFiles','New-EOBatchPlan','Get-EOBatchOutputPath','Get-EOBatchReportPath','Get-EOBatchResumeSignature','Get-EOBatchResumeRecord') {
            Get-Command $name -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }

    It 'discovers supported video extensions and ignores optimizer outputs by default' {
        $root=Join-Path ([IO.Path]::GetTempPath()) ('eo-batch-'+[guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root | Out-Null
        try {
            foreach($name in 'a.mp4','b.mkv','c.webm','note.txt','a.optimized.mp4','clip.partial.abc.mkv') { [IO.File]::WriteAllText((Join-Path $root $name),'x') }
            $files=@(Get-EOMediaFiles -Path $root)
            $files.Name | Should -Contain 'a.mp4'
            $files.Name | Should -Contain 'b.mkv'
            $files.Name | Should -Contain 'c.webm'
            $files.Name | Should -Not -Contain 'note.txt'
            $files.Name | Should -Not -Contain 'a.optimized.mp4'
            $files.Name | Should -Not -Contain 'clip.partial.abc.mkv'
        } finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'applies include and exclude wildcard filters to relative media paths' {
        $root=Join-Path ([IO.Path]::GetTempPath()) ('eo-filter-'+[guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $root 'keep') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'skip') -Force | Out-Null
        try {
            [IO.File]::WriteAllText((Join-Path $root 'keep\movie.mp4'),'x')
            [IO.File]::WriteAllText((Join-Path $root 'keep\trailer.mkv'),'x')
            [IO.File]::WriteAllText((Join-Path $root 'skip\movie.mp4'),'x')
            [IO.File]::WriteAllText((Join-Path $root 'keep\sample.mp4'),'x')

            $files=@(Get-EOMediaFiles -Path $root -Recurse -Include @('*.mp4','*.mkv') -Exclude @('skip\*','*sample*'))
            $relative=@($files | ForEach-Object { [IO.Path]::GetRelativePath($root,$_.FullName) })
            $relative | Should -Contain 'keep\movie.mp4'
            $relative | Should -Contain 'keep\trailer.mkv'
            $relative | Should -Not -Contain 'skip\movie.mp4'
            $relative | Should -Not -Contain 'keep\sample.mp4'
        } finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'preserves relative subdirectories under an output root and never reuses an existing output name' {
        $root=Join-Path ([IO.Path]::GetTempPath()) ('eo-output-'+[guid]::NewGuid().ToString('N'))
        $sourceRoot=Join-Path $root 'input'
        $outputRoot=Join-Path $root 'output'
        New-Item -ItemType Directory -Path (Join-Path $sourceRoot 'season1') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $outputRoot 'season1') -Force | Out-Null
        $input=Join-Path $sourceRoot 'season1\episode.mp4'
        [IO.File]::WriteAllText($input,'x')
        try {
            $first=Get-EOBatchOutputPath -InputPath $input -InputRoot $sourceRoot -OutputDirectory $outputRoot -Extension '.mkv'
            $first | Should -Be (Join-Path $outputRoot 'season1\episode.optimized.mkv')
            [IO.File]::WriteAllText($first,'existing')
            $second=Get-EOBatchOutputPath -InputPath $input -InputRoot $sourceRoot -OutputDirectory $outputRoot -Extension '.mkv'
            $second | Should -Be (Join-Path $outputRoot 'season1\episode.optimized.2.mkv')
        } finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'builds a deterministic resume signature and changes it when source or settings change' {
        $fingerprint=[pscustomobject]@{ Hash='abc'; Size=12345 }
        $base=@{
            SourceFingerprint=$fingerprint; Profile='Conservative'; EncoderName='libx265'; EncoderSignature='p7|crf';
            PolicySignature='98|97|95'; VideoFilter='crop=100:100:0:0'; FFmpegVersion='9.0.1'; OutputRoot='C:\out';
            AutoEncode=$false; AllowHdr=$false; AllowInterlaced=$false; AllowSecondary=$false
        }
        $one=Get-EOBatchResumeSignature @base
        $two=Get-EOBatchResumeSignature @base
        $two | Should -BeExactly $one

        $changed=@{} + $base
        $changed.VideoFilter='crop=90:90:0:0'
        (Get-EOBatchResumeSignature @changed) | Should -Not -Be $one

        $changedSource=@{} + $base
        $changedSource.SourceFingerprint=[pscustomobject]@{ Hash='def'; Size=12345 }
        (Get-EOBatchResumeSignature @changedSource) | Should -Not -Be $one
    }

    It 'resumes analyze-only from an exact signature but requires validated existing output for auto-encode' {
        $root=Join-Path ([IO.Path]::GetTempPath()) ('eo-resume-'+[guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root | Out-Null
        $reportPath=Join-Path $root 'movie.json'
        $outputPath=Join-Path $root 'movie.optimized.mkv'
        $report=[pscustomobject]@{
            SchemaVersion=1; Decision='ENCODE'; Source=[pscustomobject]@{ Path='movie.mkv' }
            BatchResume=[pscustomobject]@{ Signature='sig-1'; OutputPath=$outputPath; OutputValidated=$true }
        }
        $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportPath
        try {
            (Get-EOBatchResumeRecord -ReportPath $reportPath -Signature 'sig-1') | Should -Not -BeNullOrEmpty
            (Get-EOBatchResumeRecord -ReportPath $reportPath -Signature 'wrong') | Should -BeNullOrEmpty
            (Get-EOBatchResumeRecord -ReportPath $reportPath -Signature 'sig-1' -RequireValidatedOutput) | Should -BeNullOrEmpty

            [IO.File]::WriteAllText($outputPath,'encoded')
            $resumed=Get-EOBatchResumeRecord -ReportPath $reportPath -Signature 'sig-1' -RequireValidatedOutput
            $resumed | Should -Not -BeNullOrEmpty
            $resumed.BatchResume.OutputValidated | Should -BeTrue
        } finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'separates hardware and software work and honors independent concurrency limits' {
        $items=@(
            [pscustomobject]@{ Path='gpu1.mp4'; Encoder='hevc_nvenc'; Hardware=$true; Blocked=$false },
            [pscustomobject]@{ Path='gpu2.mp4'; Encoder='hevc_nvenc'; Hardware=$true; Blocked=$false },
            [pscustomobject]@{ Path='cpu1.mkv'; Encoder='libx265'; Hardware=$false; Blocked=$false },
            [pscustomobject]@{ Path='blocked.mkv'; Encoder=''; Hardware=$false; Blocked=$true; Reason='Dolby Vision' }
        )
        $plan=New-EOBatchPlan -Items $items -GpuConcurrency 2 -CpuConcurrency 1
        $plan.GPU.Count | Should -Be 2
        $plan.CPU.Count | Should -Be 1
        $plan.Blocked.Count | Should -Be 1
        $plan.GpuConcurrency | Should -Be 2
        $plan.CpuConcurrency | Should -Be 1
    }

    It 'clamps invalid concurrency values to safe minimums' {
        $plan=New-EOBatchPlan -Items @() -GpuConcurrency 0 -CpuConcurrency -2
        $plan.GpuConcurrency | Should -Be 1
        $plan.CpuConcurrency | Should -Be 1
    }
}

Describe 'Optimize-Videos public CLI' {
    It 'exposes batch filtering output resume safety and concurrency controls' {
        $script=Join-Path $PSScriptRoot '..\Optimize-Videos.ps1'
        Test-Path $script | Should -BeTrue
        $command=Get-Command $script
        foreach($name in 'Path','Recurse','Include','Exclude','OutputDirectory','Resume','Profile','Encoder','Codec','VideoFilter','AutoEncode','GpuConcurrency','CpuConcurrency','AllowHdrAutoEncode','AllowInterlacedAutoEncode','AllowSecondaryMetricsAutoEncode') {
            $command.Parameters.Keys | Should -Contain $name
        }
        $text=Get-Content -LiteralPath $script -Raw
        $text | Should -Match 'Optimize-Video\.ps1'
        $text | Should -Match 'GpuConcurrency'
        $text | Should -Match 'CpuConcurrency'
        $text | Should -Match 'BatchMode'
        $text | Should -Match 'BatchResume'
    }
}
