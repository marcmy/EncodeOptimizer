BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\lib\Batch.psm1'
    if (Test-Path $modulePath) { Import-Module $modulePath -Force }
}

Describe 'batch optimizer planning' {
    It 'provides media discovery and batch planning commands' {
        Test-Path $modulePath | Should -BeTrue
        foreach ($name in 'Get-EOMediaFiles','New-EOBatchPlan') {
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
    It 'exposes batch-specific safety and concurrency controls' {
        $script=Join-Path $PSScriptRoot '..\Optimize-Videos.ps1'
        Test-Path $script | Should -BeTrue
        $command=Get-Command $script
        foreach($name in 'Path','Recurse','Profile','Encoder','Codec','VideoFilter','AutoEncode','GpuConcurrency','CpuConcurrency','AllowHdrAutoEncode','AllowInterlacedAutoEncode','AllowSecondaryMetricsAutoEncode') {
            $command.Parameters.Keys | Should -Contain $name
        }
        $text=Get-Content -LiteralPath $script -Raw
        $text | Should -Match 'Optimize-Video\.ps1'
        $text | Should -Match 'GpuConcurrency'
        $text | Should -Match 'CpuConcurrency'
        $text | Should -Match 'BatchMode'
    }
}
