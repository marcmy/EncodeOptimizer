Describe 'Optimize-Video public CLI' {
    BeforeAll {
        $scriptPath = Join-Path $PSScriptRoot '..\Optimize-Video.ps1'
    }

    It 'exposes the approved single-file CLI parameters' {
        Test-Path $scriptPath | Should -BeTrue
        $command = Get-Command $scriptPath
        foreach ($name in 'Path','Profile','Encoder','Codec','VideoFilter','AutoEncode','ForceEncode','KeepSamples','OutputPath','FFmpegPath','FFprobePath') {
            $command.Parameters.Keys | Should -Contain $name
        }
    }

    It 'defaults to Conservative analyze-only behavior' {
        $text = Get-Content -LiteralPath $scriptPath -Raw
        $text | Should -Match ([regex]::Escape("[string] `$Profile = 'Conservative'"))
        $text | Should -Match '\[switch\]\s*\$AutoEncode'
        $text | Should -Not -Match '\$AutoEncode\s*=\s*\$true'
    }

    It 'contains explicit temporary-output validation before final replacement' {
        $text = Get-Content -LiteralPath $scriptPath -Raw
        $text | Should -Match 'temporary|\.partial|\.tmp'
        $text | Should -Match 'Get-EOSourceProbe'
        $text | Should -Match 'Move-Item'
        $text | Should -Not -Match 'Remove-Item\s+\$Path'
    }
}

Describe 'encodeoptimizer PATH wrapper' {
    It 'invokes its sibling Optimize-Video.ps1, forwards arguments, and propagates the exit code' {
        $sourceWrapper = Join-Path $PSScriptRoot '..\encodeoptimizer.cmd'
        $wrapperExists = Test-Path -LiteralPath $sourceWrapper -PathType Leaf
        $wrapperExists | Should -BeTrue
        if (-not $wrapperExists) { return }

        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('EncodeOptimizer-wrapper-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tempRoot | Out-Null
        try {
            $wrapper = Join-Path $tempRoot 'encodeoptimizer.cmd'
            Copy-Item -LiteralPath $sourceWrapper -Destination $wrapper

            @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Remaining)
$Remaining -join '|'
exit 37
'@ | Set-Content -LiteralPath (Join-Path $tempRoot 'Optimize-Video.ps1') -Encoding utf8

            $output = & $wrapper 'alpha beta' '-Profile' 'Balanced' 2>&1
            $exitCode = $LASTEXITCODE

            ($output -join "`n") | Should -Match ([regex]::Escape('alpha beta|-Profile|Balanced'))
            $exitCode | Should -Be 37
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
