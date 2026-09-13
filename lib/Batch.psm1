Set-StrictMode -Version Latest

function Get-EOMediaFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Recurse,
        [string[]]$Extensions=@('.mp4','.m4v','.mov','.mkv','.webm','.avi','.ts','.m2ts','.mts','.mpg','.mpeg','.wmv','.flv','.ogv')
    )

    $item=Get-Item -LiteralPath $Path -ErrorAction Stop
    if (-not $item.PSIsContainer) {
        if ($Extensions -contains $item.Extension.ToLowerInvariant()) { return @($item) }
        return @()
    }

    $normalized=@($Extensions | ForEach-Object { if ($_.StartsWith('.')) { $_.ToLowerInvariant() } else { ('.'+$_).ToLowerInvariant() } })
    $files=Get-ChildItem -LiteralPath $item.FullName -File -Recurse:$Recurse
    return @($files | Where-Object {
        $name=$_.Name.ToLowerInvariant()
        $normalized -contains $_.Extension.ToLowerInvariant() -and
        $name -notmatch '\.optimized(?:\.\d+)?\.' -and
        $name -notmatch '\.partial\.[^.]+\.'
    } | Sort-Object FullName)
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

Export-ModuleMember -Function Get-EOMediaFiles,New-EOBatchPlan
