Set-StrictMode -Version Latest

function Get-EOHashHex {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([Convert]::ToHexString($sha.ComputeHash($Bytes))).ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-EOStringHash {
    param([Parameter(Mandatory)][string]$Text)
    return Get-EOHashHex ([Text.Encoding]::UTF8.GetBytes($Text))
}

function Get-EOSourceFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$ChunkBytes = 1048576
    )

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.PSIsContainer) { throw "Source '$Path' is not a file." }
    $size = [long]$item.Length
    $chunk = [math]::Max(65536, $ChunkBytes)

    if ($size -le (3L * $chunk)) {
        $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        return [pscustomobject]@{ Hash=$hash; Size=$size; Sampled=$false; Algorithm='SHA256-full-v1' }
    }

    $stream = [IO.File]::Open($item.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $memory = [IO.MemoryStream]::new()
        try {
            $sizeBytes = [BitConverter]::GetBytes($size)
            $memory.Write($sizeBytes, 0, $sizeBytes.Length)
            $positions = @(
                0L,
                [math]::Max(0L, [long](($size - $chunk) / 2)),
                [math]::Max(0L, $size - $chunk)
            ) | Select-Object -Unique
            foreach ($position in $positions) {
                $stream.Position = [long]$position
                $buffer = [byte[]]::new([int][math]::Min([long]$chunk, $size - [long]$position))
                $read = $stream.Read($buffer, 0, $buffer.Length)
                $positionBytes = [BitConverter]::GetBytes([long]$position)
                $memory.Write($positionBytes, 0, $positionBytes.Length)
                $memory.Write($buffer, 0, $read)
            }
            $hash = Get-EOHashHex $memory.ToArray()
            return [pscustomobject]@{ Hash=$hash; Size=$size; Sampled=$true; Algorithm='SHA256-sampled-v1' }
        } finally { $memory.Dispose() }
    } finally { $stream.Dispose() }
}

function Get-EOCacheKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$SourceFingerprint,
        [string]$VideoFilter = '',
        [Parameter(Mandatory)][string]$EncoderName,
        [string]$EncoderSignature = '',
        [Parameter(Mandatory)][string]$FFmpegVersion,
        [Parameter(Mandatory)][string]$PolicyName,
        [string]$PolicySignature = ''
    )

    $canonical = [ordered]@{
        Version          = 1
        SourceHash       = [string]$SourceFingerprint.Hash
        SourceSize       = [long]$SourceFingerprint.Size
        VideoFilter      = [string]$VideoFilter
        EncoderName      = [string]$EncoderName
        EncoderSignature = [string]$EncoderSignature
        FFmpegVersion    = [string]$FFmpegVersion
        PolicyName       = [string]$PolicyName
        PolicySignature  = [string]$PolicySignature
    }
    return Get-EOStringHash ($canonical | ConvertTo-Json -Compress -Depth 8)
}

function Get-EOEntryPath {
    param([string]$CacheRoot,[string]$Key)
    Join-Path (Join-Path $CacheRoot 'entries') ($Key + '.json')
}

function Read-EOCacheEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CacheRoot,[Parameter(Mandatory)][string]$Key)
    $path = Get-EOEntryPath $CacheRoot $Key
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 100) }
    catch { throw "Cache entry '$path' is invalid JSON: $($_.Exception.Message)" }
}

function Write-EOJsonAtomically {
    param([string]$Path,$Value)
    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $temporary = Join-Path $directory ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $json = $Value | ConvertTo-Json -Depth 100 -Compress
        [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Write-EOCacheEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CacheRoot,[Parameter(Mandatory)][string]$Key,[Parameter(Mandatory)]$Entry)
    $path = Get-EOEntryPath $CacheRoot $Key
    Write-EOJsonAtomically -Path $path -Value $Entry
    return $path
}

function Get-EOHistoryPath { param([string]$CacheRoot) Join-Path $CacheRoot 'history.json' }

function Read-EOHistory {
    param([string]$CacheRoot)
    $path = Get-EOHistoryPath $CacheRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    try { return @((Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 100)) }
    catch { return @() }
}

function Get-EOHistoryMutexName {
    param([Parameter(Mandatory)][string]$CacheRoot)
    $canonical = [IO.Path]::GetFullPath($CacheRoot).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    if ([OperatingSystem]::IsWindows()) { $canonical = $canonical.ToUpperInvariant() }
    return 'EncodeOptimizer.History.' + (Get-EOStringHash $canonical).Substring(0,32)
}

function Invoke-EOHistoryCriticalSection {
    param(
        [Parameter(Mandatory)][string]$CacheRoot,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [int]$TimeoutSeconds=30
    )

    $mutex = [Threading.Mutex]::new($false,(Get-EOHistoryMutexName $CacheRoot))
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds([math]::Max(1,$TimeoutSeconds)))
        } catch [Threading.AbandonedMutexException] {
            # The previous owner exited while holding the mutex. Ownership transfers
            # to this thread, so the protected operation can safely continue.
            $acquired = $true
        }
        if (-not $acquired) { throw "Timed out waiting for EncodeOptimizer history lock for '$CacheRoot'." }
        return (& $ScriptBlock)
    } finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Add-EOHistoryEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CacheRoot,[Parameter(Mandatory)]$Entry,[int]$MaximumEntries=500)

    Invoke-EOHistoryCriticalSection -CacheRoot $CacheRoot -ScriptBlock {
        $history = [System.Collections.Generic.List[object]]::new()
        foreach ($existing in @(Read-EOHistory $CacheRoot)) { $history.Add($existing) }
        $copy = [ordered]@{}
        foreach ($property in $Entry.PSObject.Properties) { $copy[$property.Name] = $property.Value }
        $copy.RecordedAt = [DateTimeOffset]::UtcNow.ToString('o')
        $history.Add([pscustomobject]$copy)
        while ($history.Count -gt [math]::Max(1,$MaximumEntries)) { $history.RemoveAt(0) }
        Write-EOJsonAtomically -Path (Get-EOHistoryPath $CacheRoot) -Value @($history)
    } | Out-Null
}

function Get-EOHistorySeed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CacheRoot,
        [Parameter(Mandatory)][string]$Encoder,
        [Parameter(Mandatory)][string]$Codec,
        [Parameter(Mandatory)][string]$ResolutionClass,
        [Parameter(Mandatory)][string]$FpsClass,
        [Parameter(Mandatory)][int]$BitDepth,
        [Parameter(Mandatory)][string]$HdrKind,
        [int]$MaximumMatches=25
    )
    $matches = @(Read-EOHistory $CacheRoot | Where-Object {
        [bool]$_.Verified -and
        [string]$_.Encoder -eq $Encoder -and [string]$_.Codec -eq $Codec -and
        [string]$_.ResolutionClass -eq $ResolutionClass -and [string]$_.FpsClass -eq $FpsClass -and
        [int]$_.BitDepth -eq $BitDepth -and [string]$_.HdrKind -eq $HdrKind -and
        $null -ne $_.SelectedQuality
    } | Select-Object -Last $MaximumMatches)
    if ($matches.Count -eq 0) { return $null }
    $qualities = @($matches | ForEach-Object { [int]$_.SelectedQuality } | Sort-Object)
    $middle = [int][math]::Floor(($qualities.Count - 1) / 2.0)
    if (($qualities.Count % 2) -eq 1) { return [int]$qualities[$middle] }
    return [int][math]::Round(($qualities[$middle] + $qualities[$middle+1]) / 2.0, [MidpointRounding]::AwayFromZero)
}

Export-ModuleMember -Function Get-EOSourceFingerprint,Get-EOCacheKey,Read-EOCacheEntry,Write-EOCacheEntry,Add-EOHistoryEntry,Get-EOHistorySeed
