[CmdletBinding()]
param(
    [string]$ProjectRoot,
    [ValidateRange(1, 300)][int]$TimeoutSeconds = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Import-StopEnvironment {
    $modulePath = Join-Path $PSScriptRoot "lib\ProjectEnvironment.psm1"

    try {
        Import-Module $modulePath -Force -ErrorAction Stop
    } catch {
        throw "Stop environment module could not be loaded."
    }
}

function Resolve-StopProjectRoot {
    param([AllowEmptyString()][string]$ProjectRoot)

    if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
        $ProjectRoot = Join-Path $PSScriptRoot ".."
    }

    $resolvedRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
    if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
        throw "Project root does not exist."
    }

    return $resolvedRoot
}

function ConvertTo-StopNormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if ($fullPath.Length -gt 3 -and ($fullPath.EndsWith("\") -or $fullPath.EndsWith("/"))) {
        return $fullPath.TrimEnd("\", "/")
    }

    return $fullPath
}

function Resolve-StopContainedPath {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-PathInsideRoot -RootPath $RootPath -Path $resolvedPath)) {
        throw "$Description must stay within the project root."
    }

    return $resolvedPath
}

function Assert-StopNoReparsePointTraversal {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $resolvedRoot = Resolve-StopContainedPath -RootPath $RootPath -Path $RootPath -Description "Project root"
    $resolvedPath = Resolve-StopContainedPath -RootPath $RootPath -Path $Path -Description "State file"

    if ($resolvedPath.Equals($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return
    }

    $relativePath = $resolvedPath.Substring($resolvedRoot.Length).TrimStart("\")
    $currentPath = $resolvedRoot
    foreach ($segment in @($relativePath.Split("\"))) {
        if ([string]::IsNullOrWhiteSpace($segment)) {
            continue
        }

        $currentPath = Join-Path $currentPath $segment
        if (-not (Test-Path -LiteralPath $currentPath)) {
            continue
        }

        $item = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "State file path uses a reparse point."
        }
    }
}

function Get-StopStatePath {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][ValidateSet("backend", "frontend")][string]$Role
    )

    return Resolve-StopContainedPath -RootPath $RootPath -Path (Join-Path $RootPath ".runtime\state\$Role.json") -Description "$Role state file"
}

function Test-StopIntegerValue {
    param([Parameter(Mandatory = $true)]$Value)

    $integerTypes = @(
        [byte], [sbyte], [int16], [uint16], [int32], [uint32], [int64], [uint64]
    )

    return ($integerTypes -contains $Value.GetType()) -and ($Value -gt 0)
}

function Read-StopStateRecord {
    param(
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][string]$Role,
        [Parameter(Mandatory = $true)][string]$ProjectRoot
    )

    try {
        $raw = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 -ErrorAction Stop
        $record = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "$Role state record is invalid."
    }

    foreach ($field in @("schemaVersion", "pid", "executablePath", "startTimeUtc", "commandLine", "projectRoot", "role")) {
        if ($null -eq $record.PSObject.Properties[$field]) {
            throw "$Role state record is invalid."
        }
    }

    if (-not (Test-StopIntegerValue -Value $record.schemaVersion) -or [int]$record.schemaVersion -ne 1) {
        throw "$Role state record is invalid."
    }

    if (-not (Test-StopIntegerValue -Value $record.pid)) {
        throw "$Role state record is invalid."
    }

    foreach ($field in @("executablePath", "startTimeUtc", "commandLine", "projectRoot", "role")) {
        $value = $record.$field
        if (-not ($value -is [string]) -or [string]::IsNullOrWhiteSpace($value)) {
            throw "$Role state record is invalid."
        }
    }

    try {
        if (-not ([string]$record.startTimeUtc).EndsWith("Z", [System.StringComparison]::Ordinal)) {
            throw "roundtrip-utc-required"
        }

        $parsedStartTimeUtc = [datetime]::ParseExact(
            [string]$record.startTimeUtc,
            "o",
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind
        )
        if ($parsedStartTimeUtc.Kind -ne [System.DateTimeKind]::Utc) {
            throw "roundtrip-utc-required"
        }

        if ($parsedStartTimeUtc.ToString("o") -ne [string]$record.startTimeUtc) {
            throw "roundtrip-utc-required"
        }
    } catch {
        throw "$Role state record is invalid."
    }

    if (-not $record.role.Equals($Role, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Role state record is invalid."
    }

    $resolvedRecordedRoot = ConvertTo-StopNormalizedPath -Path $record.projectRoot
    $resolvedProjectRoot = ConvertTo-StopNormalizedPath -Path $ProjectRoot
    if (-not $resolvedRecordedRoot.Equals($resolvedProjectRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Role state record project root mismatch."
    }

    return [pscustomobject]@{
        schemaVersion = 1
        pid = [int]$record.pid
        executablePath = [string]$record.executablePath
        startTimeUtc = [string]$record.startTimeUtc
        commandLine = [string]$record.commandLine
        projectRoot = $resolvedRecordedRoot
        role = [string]$record.role
    }
}

function New-StopQuarantinePath {
    param(
        [Parameter(Mandatory = $true)][string]$StateDirectory,
        [Parameter(Mandatory = $true)][string]$StateLeaf
    )

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($StateLeaf)
    $extension = [System.IO.Path]::GetExtension($StateLeaf)
    $suffix = [System.Guid]::NewGuid().ToString("N")
    return Join-Path $StateDirectory "$baseName.quarantine.$suffix$extension"
}

function Remove-StopStateRecord {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [scriptblock]$QuarantinePathProvider = { param($StateDirectory, $StateLeaf) New-StopQuarantinePath -StateDirectory $StateDirectory -StateLeaf $StateLeaf },
        [scriptblock]$MoveAction = { param($LiteralPath, $Destination) Move-Item -LiteralPath $LiteralPath -Destination $Destination -Force -ErrorAction Stop },
        [scriptblock]$DeleteAction = { param($LiteralPath) Remove-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop }
    )

    Assert-StopNoReparsePointTraversal -RootPath $RootPath -Path $StatePath
    if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
        $stateDirectory = Split-Path -Parent $StatePath
        $stateLeaf = Split-Path -Leaf $StatePath
        Assert-StopNoReparsePointTraversal -RootPath $RootPath -Path $stateDirectory
        $quarantinePath = & $QuarantinePathProvider $stateDirectory $stateLeaf
        $resolvedQuarantinePath = Resolve-StopContainedPath -RootPath $RootPath -Path $quarantinePath -Description "Quarantine state file"
        $resolvedStateDirectory = ConvertTo-StopNormalizedPath -Path $stateDirectory
        if (-not (ConvertTo-StopNormalizedPath -Path (Split-Path -Parent $resolvedQuarantinePath)).Equals($resolvedStateDirectory, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Quarantine state file must stay within the state directory."
        }

        Assert-StopNoReparsePointTraversal -RootPath $RootPath -Path $resolvedQuarantinePath
        & $MoveAction $StatePath $resolvedQuarantinePath
        Assert-StopNoReparsePointTraversal -RootPath $RootPath -Path $stateDirectory
        Assert-StopNoReparsePointTraversal -RootPath $RootPath -Path $resolvedQuarantinePath
        if (-not (Test-Path -LiteralPath $resolvedQuarantinePath -PathType Leaf)) {
            throw "Quarantine state file was not created."
        }

        & $DeleteAction $resolvedQuarantinePath
    }
}

function Get-StopProcessHandle {
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    return Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
}

function Get-StopActualIdentity {
    param([Parameter(Mandatory = $true)]$ProcessHandle)

    return Get-ProjectProcessIdentity -ProcessId $ProcessHandle.Id
}

function Test-StopRecordedIdentity {
    param(
        [Parameter(Mandatory = $true)][psobject]$RecordedIdentity,
        [Parameter(Mandatory = $true)]$ProcessHandle,
        [Parameter(Mandatory = $true)]$ActualIdentity
    )

    return Test-ProjectProcessIdentity -RecordedIdentity $RecordedIdentity -ProcessId $ProcessHandle.Id
}

function Stop-ManagedRole {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][ValidateSet("backend", "frontend")][string]$Role,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [scriptblock]$ProcessProvider = { param($ProcessId) Get-StopProcessHandle -ProcessId $ProcessId },
        [scriptblock]$IdentityProvider = { param($ProcessHandle) Get-StopActualIdentity -ProcessHandle $ProcessHandle },
        [scriptblock]$IdentityComparer = { param($RecordedIdentity, $ProcessHandle, $ActualIdentity) Test-StopRecordedIdentity -RecordedIdentity $RecordedIdentity -ProcessHandle $ProcessHandle -ActualIdentity $ActualIdentity },
        [scriptblock]$KillAction = { param($ProcessHandle) $ProcessHandle.Kill() },
        [scriptblock]$WaitAction = { param($ProcessHandle, $TimeoutSeconds) return $ProcessHandle.WaitForExit($TimeoutSeconds * 1000) }
    )

    $statePath = Get-StopStatePath -RootPath $RootPath -Role $Role
    Assert-StopNoReparsePointTraversal -RootPath $RootPath -Path $statePath

    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return [pscustomobject]@{
            Success = $true
            Message = "${Role}: no state record."
        }
    }

    $record = Read-StopStateRecord -StatePath $statePath -Role $Role -ProjectRoot $RootPath
    $process = & $ProcessProvider $record.pid
    if ($null -eq $process) {
        Remove-StopStateRecord -RootPath $RootPath -StatePath $statePath
        return [pscustomobject]@{
            Success = $true
            Message = "${Role}: stale record removed."
        }
    }

    $initialStartTimeUtc = $process.StartTime.ToUniversalTime()
    $actualIdentity = & $IdentityProvider $process
    $recordedIdentity = [pscustomobject]@{
        Pid = $record.pid
        ExecutablePath = $record.executablePath
        StartTimeUtc = $record.startTimeUtc
        CommandLine = $record.commandLine
    }

    if (-not (& $IdentityComparer $recordedIdentity $process $actualIdentity)) {
        return [pscustomobject]@{
            Success = $false
            Message = "${Role}: identity mismatch."
        }
    }

    $roleMarker = "project-role-$Role"
    if ($record.commandLine.IndexOf($RootPath, [System.StringComparison]::OrdinalIgnoreCase) -lt 0 -or
        $record.commandLine.IndexOf($roleMarker, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        return [pscustomobject]@{
            Success = $false
            Message = "${Role}: identity mismatch."
        }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$actualIdentity.CommandLine) -and
        ($actualIdentity.CommandLine.IndexOf($RootPath, [System.StringComparison]::OrdinalIgnoreCase) -lt 0 -or
         $actualIdentity.CommandLine.IndexOf($roleMarker, [System.StringComparison]::OrdinalIgnoreCase) -lt 0)) {
        return [pscustomobject]@{
            Success = $false
            Message = "${Role}: identity mismatch."
        }
    }

    $process.Refresh()
    if ($process.HasExited) {
        Remove-StopStateRecord -RootPath $RootPath -StatePath $statePath
        return [pscustomobject]@{
            Success = $true
            Message = "${Role}: stale record removed."
        }
    }

    if ($process.StartTime.ToUniversalTime() -ne $initialStartTimeUtc) {
        return [pscustomobject]@{
            Success = $false
            Message = "${Role}: identity mismatch."
        }
    }

    & $KillAction $process
    if (-not (& $WaitAction $process $TimeoutSeconds)) {
        return [pscustomobject]@{
            Success = $false
            Message = "${Role}: stop timed out."
        }
    }

    Remove-StopStateRecord -RootPath $RootPath -StatePath $statePath
    return [pscustomobject]@{
        Success = $true
        Message = "${Role}: stopped."
    }
}

function Invoke-StopMain {
    param(
        [string]$ProjectRoot,
        [int]$TimeoutSeconds = 15
    )

    $resolvedRoot = Resolve-StopProjectRoot -ProjectRoot $ProjectRoot
    $results = New-Object System.Collections.Generic.List[object]

    foreach ($role in @("backend", "frontend")) {
        try {
            $results.Add((Stop-ManagedRole -RootPath $resolvedRoot -Role $role -TimeoutSeconds $TimeoutSeconds))
        } catch {
            $results.Add([pscustomobject]@{
                Success = $false
                Message = "${role}: $($_.Exception.Message)"
            })
        }
    }

    $exitCode = if (@($results | Where-Object { -not $_.Success }).Count -gt 0) { 1 } else { 0 }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Messages = @($results | ForEach-Object { $_.Message })
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        Import-StopEnvironment
        $result = Invoke-StopMain -ProjectRoot $ProjectRoot -TimeoutSeconds $TimeoutSeconds
        foreach ($message in @($result.Messages)) {
            Write-Output $message
        }
        exit $result.ExitCode
    } catch {
        Write-Output "stop: $($_.Exception.Message)"
        exit 1
    }
}
