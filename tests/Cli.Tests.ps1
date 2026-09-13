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
