Set-StrictMode -Version Latest

function Get-EOExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [string] $ExplicitPath
    )

    if ($ExplicitPath) {
        if (Test-Path -LiteralPath $ExplicitPath -PathType Leaf) {
            return (Resolve-Path -LiteralPath $ExplicitPath).Path
        }

        $explicitCommands = @(Get-Command $ExplicitPath -CommandType Application -ErrorAction SilentlyContinue)
        if ($explicitCommands.Count -gt 0) {
            return [string]$explicitCommands[0].Source
        }

        throw "Unable to find executable '$ExplicitPath'."
    }

    $commands = @(Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue)
    if ($commands.Count -eq 0) {
        throw "Unable to find '$Name' on PATH. Install FFmpeg or provide an explicit path."
    }

    return [string]$commands[0].Source
}

function Invoke-EOTool {
    param(
        [Parameter(Mandatory)] [string] $Executable,
        [Parameter(Mandatory)] [string[]] $Arguments,
        [scriptblock] $CommandRunner
    )

    if ($CommandRunner) {
        $result = & $CommandRunner $Executable $Arguments
        if ($null -eq $result) { return '' }
        if ($result -is [array]) { return ($result -join [Environment]::NewLine) }
        return [string] $result
    }

    $output = & $Executable @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | ForEach-Object { [string] $_ }) -join [Environment]::NewLine
    if ($exitCode -ne 0) {
        throw "Command failed ($exitCode): $Executable $($Arguments -join ' ')`n$text"
    }

    return $text
}

function Get-EOFFmpegListNames {
    param(
        [Parameter(Mandatory)] [string] $Text
    )

    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*[A-Z\.]{2,8}\s+([A-Za-z0-9_]+)\s+') {
            $name = $Matches[1]
            if (-not $names.Contains($name)) {
                $names.Add($name)
            }
        }
    }
    return @($names)
}

function Get-EOHwAccelNames {
    param([Parameter(Mandatory)] [string] $Text)

    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($Text -split "`r?`n")) {
        $value = $line.Trim()
        if (-not $value -or $value -match '^Hardware acceleration methods') { continue }
        if ($value -match '^[A-Za-z0-9_]+$') { $names.Add($value) }
    }
    return @($names)
}

function Get-EOEncoderOptionNames {
    param([Parameter(Mandatory)] [string] $Text)

    $options = [System.Collections.Generic.List[string]]::new()
    foreach ($match in [regex]::Matches($Text, '(?m)^\s+-([A-Za-z0-9_-]+)\s+')) {
        $name = $match.Groups[1].Value
        if (-not $options.Contains($name)) { $options.Add($name) }
    }
    return @($options)
}

function Get-EOCapabilities {
    [CmdletBinding()]
    param(
        [string] $FFmpegPath,
        [string[]] $EncoderNames = @('hevc_nvenc','h264_nvenc','av1_nvenc','libx265','libx264','libsvtav1'),
        [scriptblock] $CommandRunner
    )

    $resolved = if ($CommandRunner -and $FFmpegPath) {
        $FFmpegPath
    } else {
        Get-EOExecutable -Name 'ffmpeg' -ExplicitPath $FFmpegPath
    }

    $versionText = Invoke-EOTool -Executable $resolved -Arguments @('-version') -CommandRunner $CommandRunner
    $version = if ($versionText -match 'ffmpeg version\s+([^\s]+)') { $Matches[1] } else { 'unknown' }

    $encoders = Get-EOFFmpegListNames (Invoke-EOTool -Executable $resolved -Arguments @('-hide_banner','-encoders') -CommandRunner $CommandRunner)
    $decoders = Get-EOFFmpegListNames (Invoke-EOTool -Executable $resolved -Arguments @('-hide_banner','-decoders') -CommandRunner $CommandRunner)
    $filters = Get-EOFFmpegListNames (Invoke-EOTool -Executable $resolved -Arguments @('-hide_banner','-filters') -CommandRunner $CommandRunner)
    $hwaccels = Get-EOHwAccelNames (Invoke-EOTool -Executable $resolved -Arguments @('-hide_banner','-hwaccels') -CommandRunner $CommandRunner)

    $encoderOptions = [ordered]@{}
    foreach ($encoder in $EncoderNames) {
        if ($encoders -notcontains $encoder) { continue }
        $help = Invoke-EOTool -Executable $resolved -Arguments @('-hide_banner','-h',"encoder=$encoder") -CommandRunner $CommandRunner
        $encoderOptions[$encoder] = @(Get-EOEncoderOptionNames $help)
    }

    [pscustomobject]@{
        FFmpegPath    = $resolved
        Version       = $version
        Encoders      = @($encoders)
        Decoders      = @($decoders)
        Filters       = @($filters)
        HwAccels      = @($hwaccels)
        EncoderOptions = $encoderOptions
        HasVmaf       = $filters -contains 'libvmaf'
        HasXpsnr      = $filters -contains 'xpsnr'
        HasSsim       = $filters -contains 'ssim'
        HasPsnr       = $filters -contains 'psnr'
        HasCuda       = $hwaccels -contains 'cuda'
    }
}

Export-ModuleMember -Function Get-EOExecutable, Get-EOCapabilities
