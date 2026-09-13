BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\lib\Cache.psm1'
    if (Test-Path $modulePath) { Import-Module $modulePath -Force }
}

Describe 'deterministic cache keys' {
    It 'provides cache and history commands' {
        Test-Path $modulePath | Should -BeTrue
        foreach ($name in 'Get-EOSourceFingerprint','Get-EOCacheKey','Read-EOCacheEntry','Write-EOCacheEntry','Add-EOHistoryEntry','Get-EOHistorySeed') {
            Get-Command $name -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }

    It 'changes the key when source filter encoder FFmpeg or policy inputs change' {
        $fingerprint = [pscustomobject]@{ Hash='abc123'; Size=1000 }
        $base = @{
            SourceFingerprint = $fingerprint
            VideoFilter = ''
            EncoderName = 'hevc_nvenc'
            EncoderSignature = 'p7-hq'
            FFmpegVersion = '8.0'
            PolicyName = 'Conservative'
            PolicySignature = '98-97-95'
        }
        $key = Get-EOCacheKey @base

        foreach ($mutation in @(
            @{ SourceFingerprint=[pscustomobject]@{ Hash='different'; Size=1000 } },
            @{ VideoFilter='crop=404:720:438:0' },
            @{ EncoderName='libx265' },
            @{ EncoderSignature='p7-hq-aq10' },
            @{ FFmpegVersion='8.1' },
            @{ PolicyName='Balanced' },
            @{ PolicySignature='97-95.5-93.5' }
        )) {
            $args = @{} + $base
            foreach ($pair in $mutation.GetEnumerator()) { $args[$pair.Key] = $pair.Value }
            (Get-EOCacheKey @args) | Should -Not -Be $key
        }
    }

    It 'fingerprints content deterministically without depending on the source pathname' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('eo-cache-test-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root | Out-Null
        try {
            $a = Join-Path $root 'a.bin'; $b = Join-Path $root 'renamed.bin'
            [IO.File]::WriteAllText($a, 'same video bytes')
            Copy-Item $a $b
            $fa = Get-EOSourceFingerprint -Path $a
            $fb = Get-EOSourceFingerprint -Path $b
            $fa.Hash | Should -Be $fb.Hash
            $fa.Size | Should -Be $fb.Size
        } finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'round-trips compact JSON cache entries' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('eo-cache-test-' + [guid]::NewGuid().ToString('N'))
        try {
            $entry = [pscustomobject]@{ Decision='ENCODE'; SelectedQuality=16; Confidence='HIGH' }
            Write-EOCacheEntry -CacheRoot $root -Key 'deadbeef' -Entry $entry
            $loaded = Read-EOCacheEntry -CacheRoot $root -Key 'deadbeef'
            $loaded.Decision | Should -Be 'ENCODE'
            $loaded.SelectedQuality | Should -Be 16
        } finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'uses history only as a seed for closely matching content classes' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('eo-history-test-' + [guid]::NewGuid().ToString('N'))
        try {
            Add-EOHistoryEntry -CacheRoot $root -Entry ([pscustomobject]@{ Encoder='hevc_nvenc'; Codec='hevc'; ResolutionClass='720p'; FpsClass='30'; BitDepth=8; HdrKind='SDR'; SelectedQuality=16; Verified=$true })
            Add-EOHistoryEntry -CacheRoot $root -Entry ([pscustomobject]@{ Encoder='hevc_nvenc'; Codec='hevc'; ResolutionClass='4K'; FpsClass='60'; BitDepth=10; HdrKind='HDR10'; SelectedQuality=11; Verified=$true })
            $seed = Get-EOHistorySeed -CacheRoot $root -Encoder 'hevc_nvenc' -Codec 'hevc' -ResolutionClass '720p' -FpsClass '30' -BitDepth 8 -HdrKind 'SDR'
            $seed | Should -Be 16
        } finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
