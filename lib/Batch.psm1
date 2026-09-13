Set-StrictMode -Version Latest

function Get-EOBatchRootDirectory {
    param([Parameter(Mandatory)][string]$InputRoot)

    $rootItem = Get-Item -LiteralPath $InputRoot -ErrorAction Stop
    if ($rootItem.PSIsContainer) { return $rootItem.FullName }
    return $rootItem.Directory.FullName
}

function Get-EOBatchRelativePath {
    param(
        [Parameter(Mandatory)][string]$InputPath,
        [Parameter(Mandatory)][string]$InputRoot
    )

    $inputFull = [IO.Path]::GetFullPath($InputPath)
    $rootDirectory = Get-EOBatchRootDirectory -InputRoot $InputRoot
    $relative = [IO.Path]::GetRelativePath($rootDirectory,$inputFull)
    if ($relative -eq '..' -or $relative.StartsWith('..' + [IO.Path]::DirectorySeparatorChar) -or $relative.StartsWith('..' + [IO.Path]::AltDirectorySeparatorChar)) {
        throw "Input '$inputFull' is outside batch root '$rootDirectory'."
    }
    return $relative
}

function Test-EOBatchWildcardMatch {
    param(
        [Parameter(Mandatory)][string]$Value,
        [AllowNull()][string[]]$Patterns,
        [switch]$DefaultWhenEmpty
    )

    if ($null -eq $Patterns -or @($Patterns).Count -eq 0) { return [bool]$DefaultWhenEmpty }
    $normalizedValue = $Value.Replace('/','\')
    foreach ($pattern in @($Patterns)) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        $normalizedPattern = ([string]$pattern).Replace('/','\')
        $wildcard = [System.Management.Automation.WildcardPattern]::new($normalizedPattern,[System.Management.Automation.WildcardOptions]::IgnoreCase)
        if ($wildcard.IsMatch($normalizedValue)) { return $true }
    }
    return $false
}

function Get-EOMediaFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Recurse,
        [string[]]$Include,
        [string[]]$Exclude,
        [string[]]$Extensions=@('.mp4','.m4v','.mov','.mkv','.webm','.avi','.ts','.m2ts','.mts','.mpg','.mpeg','.wmv','.flv','.ogv')
    )

    $item=Get-Item -LiteralPath $Path -ErrorAction Stop
    $normalized=@($Extensions | ForEach-Object { if ($_.StartsWith('.')) { $_.ToLowerInvariant() } else { ('.'+$_).ToLowerInvariant() } })

    if (-not $item.PSIsContainer) {
        if ($normalized -notcontains $item.Extension.ToLowerInvariant()) { return @() }
        $relative=$item.Name
        if (-not (Test-EOBatchWildcardMatch -Value $relative -Patterns $Include -DefaultWhenEmpty)) { return @() }
        if (Test-EOBatchWildcardMatch -Value $relative -Patterns $Exclude) { return @() }
        return @($item)
    }

    $root=$item.FullName
    $files=Get-ChildItem -LiteralPath $root -File -Recurse:$Recurse
    return @($files | Where-Object {
        $name=$_.Name.ToLowerInvariant()
        if ($normalized -notcontains $_.Extension.ToLowerInvariant()) { return $false }
        if ($name -match '\.optimized(?:\.\d+)?\.' -or $name -match '\.partial\.[^.]+\.') { return $false }

        $relative=[IO.Path]::GetRelativePath($root,$_.FullName)
        if (-not (Test-EOBatchWildcardMatch -Value $relative -Patterns $Include -DefaultWhenEmpty)) { return $false }
        if (Test-EOBatchWildcardMatch -Value $relative -Patterns $Exclude) { return $false }
        return $true
    } | Sort-Object FullName)
}

function Get-EOBatchTargetDirectory {
    param(
        [Parameter(Mandatory)][string]$InputPath,
        [Parameter(Mandatory)][string]$InputRoot,
        [AllowNull()][string]$OutputDirectory
    )

    $rootDirectory=Get-EOBatchRootDirectory -InputRoot $InputRoot
    $targetRoot=if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $rootDirectory } else { [IO.Path]::GetFullPath($OutputDirectory) }
    $relative=Get-EOBatchRelativePath -InputPath $InputPath -InputRoot $InputRoot
    $relativeDirectory=[IO.Path]::GetDirectoryName($relative)
    $targetDirectory=if ([string]::IsNullOrWhiteSpace($relativeDirectory)) { $targetRoot } else { Join-Path $targetRoot $relativeDirectory }
    New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
    return $targetDirectory
}

function Get-EOBatchOutputPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InputPath,
        [Parameter(Mandatory)][string]$InputRoot,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][string]$Extension
    )

    $targetDirectory=Get-EOBatchTargetDirectory -InputPath $InputPath -InputRoot $InputRoot -OutputDirectory $OutputDirectory
    $stem=[IO.Path]::GetFileNameWithoutExtension($InputPath)
    $normalizedExtension=if ($Extension.StartsWith('.')) { $Extension } else { '.'+$Extension }
    $candidate=Join-Path $targetDirectory ($stem+'.optimized'+$normalizedExtension)
    $suffix=2
    while (Test-Path -LiteralPath $candidate) {
        $candidate=Join-Path $targetDirectory ($stem+".optimized.$suffix"+$normalizedExtension)
        $suffix++
    }
    return $candidate
}

function Get-EOBatchReportPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InputPath,
        [Parameter(Mandatory)][string]$InputRoot,
        [string]$OutputDirectory
    )

    $targetDirectory=Get-EOBatchTargetDirectory -InputPath $InputPath -InputRoot $InputRoot -OutputDirectory $OutputDirectory
    $stem=[IO.Path]::GetFileNameWithoutExtension($InputPath)
    return (Join-Path $targetDirectory ($stem+'.encodeoptimizer.json'))
}

function Get-EOBatchResumeSignature {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$SourceFingerprint,
        [Parameter(Mandatory)][string]$Profile,
        [Parameter(Mandatory)][string]$EncoderName,
        [string]$EncoderSignature='',
        [string]$PolicySignature='',
        [string]$VideoFilter='',
        [Parameter(Mandatory)][string]$FFmpegVersion,
        [string]$OutputRoot='',
        [bool]$AutoEncode=$false,
        [bool]$AllowHdr=$false,
        [bool]$AllowInterlaced=$false,
        [bool]$AllowSecondary=$false
    )

    $canonicalOutputRoot=if ([string]::IsNullOrWhiteSpace($OutputRoot)) { '' } else { [IO.Path]::GetFullPath($OutputRoot) }
    $canonical=[ordered]@{
        Version=1
        SourceHash=[string]$SourceFingerprint.Hash
        SourceSize=[long]$SourceFingerprint.Size
        Profile=[string]$Profile
        EncoderName=[string]$EncoderName
        EncoderSignature=[string]$EncoderSignature
        PolicySignature=[string]$PolicySignature
        VideoFilter=[string]$VideoFilter
        FFmpegVersion=[string]$FFmpegVersion
        OutputRoot=$canonicalOutputRoot
        AutoEncode=[bool]$AutoEncode
        AllowHdr=[bool]$AllowHdr
        AllowInterlaced=[bool]$AllowInterlaced
        AllowSecondary=[bool]$AllowSecondary
    }
    $json=$canonical | ConvertTo-Json -Compress -Depth 8
    $sha=[Security.Cryptography.SHA256]::Create()
    try {
        return ([Convert]::ToHexString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($json)))).ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-EOBatchResumeRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReportPath,
        [Parameter(Mandatory)][string]$Signature,
        [switch]$RequireValidatedOutput
    )

    if (-not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) { return $null }
    try {
        $report=Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json -Depth 100
    } catch {
        return $null
    }

    $batchProperty=$report.PSObject.Properties['BatchResume']
    if ($null -eq $batchProperty -or $null -eq $batchProperty.Value) { return $null }
    $batch=$batchProperty.Value
    $signatureProperty=$batch.PSObject.Properties['Signature']
    if ($null -eq $signatureProperty -or [string]$signatureProperty.Value -cne $Signature) { return $null }

    if ($RequireValidatedOutput) {
        $validatedProperty=$batch.PSObject.Properties['OutputValidated']
        $outputProperty=$batch.PSObject.Properties['OutputPath']
        if ($null -eq $validatedProperty -or -not [bool]$validatedProperty.Value) { return $null }
        if ($null -eq $outputProperty -or [string]::IsNullOrWhiteSpace([string]$outputProperty.Value)) { return $null }
        if (-not (Test-Path -LiteralPath ([string]$outputProperty.Value) -PathType Leaf)) { return $null }
    }

    return $report
}

function New-EOBatchPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items,
        [int]$GpuConcurrency=2,
        [int]$CpuConcurrency=1
    )

    $gpu=[System.Collections.Generic.List[object]]::new()
    $cpu=[System.Collections.Generic.List[object]]::new()
    $blocked=[System.Collections.Generic.List[object]]::new()

    foreach($item in @($Items)) {
        if ($item.PSObject.Properties['Blocked'] -and [bool]$item.Blocked) { $blocked.Add($item); continue }
        if ($item.PSObject.Properties['Hardware'] -and [bool]$item.Hardware) { $gpu.Add($item) } else { $cpu.Add($item) }
    }

    return [pscustomobject]@{
        GPU=@($gpu)
        CPU=@($cpu)
        Blocked=@($blocked)
        GpuConcurrency=[math]::Max(1,$GpuConcurrency)
        CpuConcurrency=[math]::Max(1,$CpuConcurrency)
        Total=@($Items).Count
    }
}

Export-ModuleMember -Function Get-EOMediaFiles,New-EOBatchPlan,Get-EOBatchOutputPath,Get-EOBatchReportPath,Get-EOBatchResumeSignature,Get-EOBatchResumeRecord
