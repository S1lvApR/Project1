[CmdletBinding()]
param(
    [string]$Device = "auto",
    [switch]$Json,
    [string]$ProjectRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Import-DoctorEnvironment {
    $modulePath = Join-Path $PSScriptRoot "lib\ProjectEnvironment.psm1"

    try {
        Import-Module $modulePath -Force -ErrorAction Stop
    } catch {
        throw "Doctor environment module could not be loaded."
    }
}

function Resolve-DoctorProjectRoot {
    param([AllowEmptyString()][string]$ProjectRoot)

    if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
        return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
    }

    $resolvedRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
    if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
        throw "ProjectRoot does not exist: $resolvedRoot"
    }

    return $resolvedRoot
}

function Assert-DoctorDeviceValue {
    param([Parameter(Mandatory = $true)][string]$Device)

    if (@("auto", "gpu", "cpu") -notcontains $Device) {
        throw "Device must be one of auto, gpu, or cpu."
    }
}

function Resolve-DoctorContainedPath {
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

function Assert-DoctorNoReparsePointTraversal {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $resolvedRoot = Resolve-DoctorContainedPath -RootPath $RootPath -Path $RootPath -Description "Project root"
    $resolvedPath = Resolve-DoctorContainedPath -RootPath $RootPath -Path $Path -Description "Mutable target"

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
            throw "Mutable path traversal through reparse point is not allowed: $currentPath"
        }
    }
}

function Resolve-DoctorPaths {
    param([Parameter(Mandatory = $true)][string]$RootPath)

    $backendRoot = Resolve-DoctorContainedPath -RootPath $RootPath -Path (Join-Path $RootPath "backend") -Description "Backend root"
    $frontendRoot = Resolve-DoctorContainedPath -RootPath $RootPath -Path (Join-Path $RootPath "frontend") -Description "Frontend root"
    $runtimeRoot = Resolve-DoctorContainedPath -RootPath $RootPath -Path (Join-Path $RootPath ".runtime") -Description "Runtime root"
    $modelsRoot = Resolve-DoctorContainedPath -RootPath $RootPath -Path (Join-Path $RootPath "models") -Description "Models root"
    $manifestPath = Resolve-DoctorContainedPath -RootPath $RootPath -Path (Join-Path $RootPath "scripts\config\bootstrap-manifest.json") -Description "Bootstrap manifest"
    $envPath = Resolve-DoctorContainedPath -RootPath $RootPath -Path (Join-Path $backendRoot ".env") -Description "Backend environment file"
    $venvRoot = Resolve-DoctorContainedPath -RootPath $RootPath -Path (Join-Path $backendRoot ".venv") -Description "Backend venv root"
    $localPythonPath = Resolve-DoctorContainedPath -RootPath $RootPath -Path (Join-Path $runtimeRoot "python\python.exe") -Description "Local Python runtime"
    $localNodePath = Resolve-DoctorContainedPath -RootPath $RootPath -Path (Join-Path $runtimeRoot "node\node.exe") -Description "Local Node runtime"
    $localNpmPath = Resolve-DoctorContainedPath -RootPath $RootPath -Path (Join-Path $runtimeRoot "node\npm.cmd") -Description "Local npm runtime"
    $venvPythonPath = Resolve-DoctorContainedPath -RootPath $RootPath -Path (Join-Path $venvRoot "Scripts\python.exe") -Description "Backend venv Python"
    $frontendLockPath = Resolve-DoctorContainedPath -RootPath $RootPath -Path (Join-Path $frontendRoot "package-lock.json") -Description "Frontend package lock"
    $nodeModulesPath = Resolve-DoctorContainedPath -RootPath $RootPath -Path (Join-Path $frontendRoot "node_modules") -Description "Frontend node_modules"

    return [pscustomobject]@{
        Root = $RootPath
        BackendRoot = $backendRoot
        FrontendRoot = $frontendRoot
        RuntimeRoot = $runtimeRoot
        ModelsRoot = $modelsRoot
        ManifestPath = $manifestPath
        EnvPath = $envPath
        VenvRoot = $venvRoot
        LocalPythonPath = $localPythonPath
        LocalNodePath = $localNodePath
        LocalNpmPath = $localNpmPath
        VenvPythonPath = $venvPythonPath
        FrontendLockPath = $frontendLockPath
        NodeModulesPath = $nodeModulesPath
    }
}

function New-DoctorCheckResult {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet("PASS", "WARN", "FAIL")][string]$Status,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][bool]$Required
    )

    return [pscustomobject]@{
        name = $Name
        status = $Status
        message = $Message
        required = $Required
    }
}

function Get-DoctorSystemFacts {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $driveInfo = New-Object System.IO.DriveInfo([System.IO.Path]::GetPathRoot($ProjectRoot))
    $freeSpaceBytes = [int64]$driveInfo.AvailableFreeSpace

    return [pscustomobject]@{
        IsWindows = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
        Architecture = if ([System.Environment]::Is64BitOperatingSystem) { "x64" } else { "x86" }
        FreeSpaceBytes = $freeSpaceBytes
    }
}

function Assert-DoctorRuntimeExecutablePath {
    param(
        [Parameter(Mandatory = $true)][string]$ExecutablePath,
        [string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RuntimeName
    )

    $resolvedPath = [System.IO.Path]::GetFullPath($ExecutablePath)
    $hasProjectRoot = -not [string]::IsNullOrWhiteSpace($ProjectRoot)
    $isContained = $hasProjectRoot -and (Test-PathInsideRoot -RootPath $ProjectRoot -Path $resolvedPath)

    if ($isContained) {
        $resolvedRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
        if (-not $resolvedPath.Equals($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
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
                    throw "$RuntimeName executable path must not traverse a reparse point: $currentPath"
                }
            }
        }

        return $resolvedPath
    }

    if (Test-Path -LiteralPath $resolvedPath -PathType Leaf) {
        $item = Get-Item -LiteralPath $resolvedPath -Force -ErrorAction Stop
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$RuntimeName executable path must not be a reparse point: $resolvedPath"
        }
    }

    return $resolvedPath
}

function Get-DoctorExactPythonVersion {
    param(
        [Parameter(Mandatory = $true)][string]$PythonPath,
        [string]$ProjectRoot,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 15
    )

    $resolvedPythonPath = Assert-DoctorRuntimeExecutablePath -ExecutablePath $PythonPath -ProjectRoot $ProjectRoot -RuntimeName "Python"
    $command = "import sys; print('{0}.{1}.{2}'.format(sys.version_info[0], sys.version_info[1], sys.version_info[2]))"
    $result = Invoke-CheckedCommand -FilePath $resolvedPythonPath -ArgumentList @("-c", $command) -TimeoutSeconds $TimeoutSeconds
    return $result.StdOut.Trim()
}

function Get-DoctorExactNodeVersion {
    param(
        [Parameter(Mandatory = $true)][string]$NodePath,
        [string]$ProjectRoot,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 15
    )

    $resolvedNodePath = Assert-DoctorRuntimeExecutablePath -ExecutablePath $NodePath -ProjectRoot $ProjectRoot -RuntimeName "Node"
    $result = Invoke-CheckedCommand -FilePath $resolvedNodePath -ArgumentList @("--version") -TimeoutSeconds $TimeoutSeconds
    return $result.StdOut.Trim().TrimStart("v")
}

function Get-DoctorExactNpmVersion {
    param(
        [Parameter(Mandatory = $true)][string]$NpmPath,
        [string]$ProjectRoot,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 15
    )

    $resolvedNpmPath = Assert-DoctorRuntimeExecutablePath -ExecutablePath $NpmPath -ProjectRoot $ProjectRoot -RuntimeName "npm"
    $result = Invoke-CheckedCommand -FilePath $resolvedNpmPath -ArgumentList @("--version") -WorkingDirectory $ProjectRoot -TimeoutSeconds $TimeoutSeconds
    return $result.StdOut.Trim()
}

function Get-DoctorPythonInfo {
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][object]$Manifest
    )

    $expectedVersion = [string]$Manifest.runtime.python.version
    $resolvedLocalPythonPath = $null
    if (Test-Path -LiteralPath $Paths.LocalPythonPath -PathType Leaf) {
        $resolvedLocalPythonPath = Assert-DoctorRuntimeExecutablePath -ExecutablePath $Paths.LocalPythonPath -ProjectRoot $Paths.Root -RuntimeName "Python"
    }

    if (Test-Path -LiteralPath $Paths.VenvPythonPath -PathType Leaf) {
        $resolvedPythonPath = Assert-DoctorRuntimeExecutablePath -ExecutablePath $Paths.VenvPythonPath -ProjectRoot $Paths.Root -RuntimeName "Python"
        $version = Get-DoctorExactPythonVersion -PythonPath $resolvedPythonPath -ProjectRoot $Paths.Root -TimeoutSeconds 15
        return [pscustomobject]@{
            Version = $version
            Path = $resolvedPythonPath
            Source = "backend-venv"
        }
    }

    if ($null -ne $resolvedLocalPythonPath) {
        $version = Get-DoctorExactPythonVersion -PythonPath $resolvedLocalPythonPath -ProjectRoot $Paths.Root -TimeoutSeconds 15
        return [pscustomobject]@{
            Version = $version
            Path = $resolvedLocalPythonPath
            Source = "project-local"
        }
    }

    throw "No compatible Python runtime was found. Expected project-local Python $expectedVersion or backend/.venv."
}

function Get-DoctorNodeInfo {
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][object]$Manifest
    )

    if (Test-Path -LiteralPath $Paths.LocalNodePath -PathType Leaf) {
        if (-not (Test-Path -LiteralPath $Paths.LocalNpmPath -PathType Leaf)) {
            throw "Project-local Node runtime is missing npm.cmd in '$([System.IO.Path]::GetDirectoryName($Paths.LocalNodePath))'."
        }

        $resolvedNodePath = Assert-DoctorRuntimeExecutablePath -ExecutablePath $Paths.LocalNodePath -ProjectRoot $Paths.Root -RuntimeName "Node"
        $resolvedNpmPath = Assert-DoctorRuntimeExecutablePath -ExecutablePath $Paths.LocalNpmPath -ProjectRoot $Paths.Root -RuntimeName "npm"
        $version = Get-DoctorExactNodeVersion -NodePath $resolvedNodePath -ProjectRoot $Paths.Root -TimeoutSeconds 15
        $npmVersion = Get-DoctorExactNpmVersion -NpmPath $resolvedNpmPath -ProjectRoot $Paths.Root -TimeoutSeconds 15
        return [pscustomobject]@{
            Version = $version
            Path = $resolvedNodePath
            NpmPath = $resolvedNpmPath
            NpmVersion = $npmVersion
            Source = "project-local"
        }
    }

    $nodeCommand = Get-Command "node.exe" -ErrorAction SilentlyContinue
    if ($null -ne $nodeCommand -and -not [string]::IsNullOrWhiteSpace($nodeCommand.Source)) {
        $nodePath = [System.IO.Path]::GetFullPath($nodeCommand.Source)
        $npmPath = Join-Path (Split-Path -Parent $nodePath) "npm.cmd"
        if (-not (Test-Path -LiteralPath $npmPath -PathType Leaf)) {
            throw "PATH Node runtime at '$nodePath' is missing sibling npm.cmd."
        }

        $resolvedNodePath = Assert-DoctorRuntimeExecutablePath -ExecutablePath $nodePath -ProjectRoot $Paths.Root -RuntimeName "Node"
        $resolvedNpmPath = Assert-DoctorRuntimeExecutablePath -ExecutablePath $npmPath -ProjectRoot $Paths.Root -RuntimeName "npm"
        $version = Get-DoctorExactNodeVersion -NodePath $resolvedNodePath -ProjectRoot $Paths.Root -TimeoutSeconds 15
        $npmVersion = Get-DoctorExactNpmVersion -NpmPath $resolvedNpmPath -ProjectRoot $Paths.Root -TimeoutSeconds 15
        return [pscustomobject]@{
            Version = $version
            Path = $resolvedNodePath
            NpmPath = $resolvedNpmPath
            NpmVersion = $npmVersion
            Source = "path-node"
        }
    }

    throw "No compatible Node runtime was found. Expected project-local .runtime\\node or PATH node.exe."
}

function Invoke-DoctorPipCheck {
    param(
        [Parameter(Mandatory = $true)][string]$PythonPath,
        [Parameter(Mandatory = $true)][string]$BackendRoot,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 15
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $PythonPath
    $startInfo.Arguments = "-m pip check"
    $startInfo.WorkingDirectory = $BackendRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try {
                if (-not $process.HasExited) {
                    $process.Kill()
                }
            } catch {
            }

            [void]$process.WaitForExit(5000)
            try {
                [void]$stdoutTask.GetAwaiter().GetResult()
                [void]$stderrTask.GetAwaiter().GetResult()
            } catch {
            }

            throw "pip check timed out."
        }

        $process.WaitForExit()
        [void]$stdoutTask.GetAwaiter().GetResult()
        [void]$stderrTask.GetAwaiter().GetResult()
        $message = if ($process.ExitCode -eq 0) { "pip check passed." } else { "pip check failed." }

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Message = $message
        }
    } finally {
        $process.Dispose()
    }
}

function Get-DoctorTorchInfo {
    param(
        [Parameter(Mandatory = $true)][string]$PythonPath,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 15
    )

    $command = @'
import json
try:
    import torch
    payload = {
        "version": getattr(torch, "__version__", None),
        "cuda_build": getattr(getattr(torch, "version", None), "cuda", None),
        "cuda_available": bool(torch.cuda.is_available()),
    }
except Exception as exc:
    payload = {"error": str(exc)}
print(json.dumps(payload))
'@
    $result = Invoke-CheckedCommand -FilePath $PythonPath -ArgumentList @("-c", $command) -TimeoutSeconds $TimeoutSeconds
    $payload = $result.StdOut.Trim() | ConvertFrom-Json
    if ($null -ne $payload.PSObject.Properties["error"]) {
        throw "Unable to inspect torch: $($payload.error)"
    }

    return [pscustomobject]@{
        Version = [string]$payload.version
        CudaBuild = if ($null -eq $payload.cuda_build) { $null } else { [string]$payload.cuda_build }
        CudaAvailable = [bool]$payload.cuda_available
    }
}

function Get-DoctorPortStatus {
    param([Parameter(Mandatory = $true)][int]$Port)

    $connections = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
    if (@($connections).Count -eq 0) {
        $listeners = @([System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object { $_.Port -eq $Port })
        if ($listeners.Count -gt 0) {
            return [pscustomobject]@{
                Occupied = $true
                ProcessId = $null
            }
        }

        return [pscustomobject]@{
            Occupied = $false
            ProcessId = $null
        }
    }

    return [pscustomobject]@{
        Occupied = $true
        ProcessId = [int]$connections[0].OwningProcess
    }
}

function Get-DoctorPortCheckResults {
    param([int[]]$Ports = @(8000, 5173))

    $results = @()
    foreach ($port in $Ports) {
        $status = Get-DoctorPortStatus -Port $port
        if ($status.Occupied) {
            $message = if ($null -ne $status.ProcessId) {
                "Port $port is already listening on PID $($status.ProcessId)."
            } else {
                "Port $port is already listening."
            }
            $results += New-DoctorCheckResult -Name "port-$port" -Status "WARN" -Message $message -Required $false
        } else {
            $results += New-DoctorCheckResult -Name "port-$port" -Status "PASS" -Message "Port $port is available." -Required $false
        }
    }

    return $results
}

function Read-DoctorEnvMap {
    param([Parameter(Mandatory = $true)][string]$Path)

    $content = Get-Content -LiteralPath $Path -Raw
    $map = @{}
    foreach ($line in @($content -split "`r?`n")) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
            continue
        }

        $separatorIndex = $trimmed.IndexOf("=")
        if ($separatorIndex -lt 1) {
            continue
        }

        $key = $trimmed.Substring(0, $separatorIndex).Trim()
        $value = $trimmed.Substring($separatorIndex + 1)
        $map[$key] = $value
    }

    return $map
}

function Resolve-DoctorSqlitePath {
    param(
        [Parameter(Mandatory = $true)][hashtable]$EnvMap,
        [Parameter(Mandatory = $true)][object]$Paths
    )

    $databaseUrl = [string]$EnvMap["DATABASE_URL"]
    if ([string]::IsNullOrWhiteSpace($databaseUrl) -or -not $databaseUrl.StartsWith("sqlite:///", [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "backend/.env must define a local sqlite DATABASE_URL."
    }

    $sqliteRelativePath = $databaseUrl.Substring("sqlite:///".Length)
    $sqlitePath = if ([System.IO.Path]::IsPathRooted($sqliteRelativePath)) {
        $sqliteRelativePath
    } else {
        Join-Path $Paths.BackendRoot $sqliteRelativePath
    }

    return Resolve-DoctorContainedPath -RootPath $Paths.Root -Path $sqlitePath -Description "SQLite database path"
}

function Get-DoctorModelTargets {
    param(
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][hashtable]$EnvMap,
        [Parameter(Mandatory = $true)][object]$Paths
    )

    $manifestModelsByFilename = @{}
    foreach ($model in @($Manifest.release.models)) {
        $manifestModelsByFilename[$model.filename] = $model
    }

    $targets = @()
    foreach ($model in @($Manifest.release.models | Where-Object { ([string]$_.purpose).Trim().ToLowerInvariant().StartsWith("default ") })) {
        $targets += [pscustomobject]@{
            ManifestModel = $model
            Path = Resolve-DoctorContainedPath -RootPath $Paths.Root -Path (Join-Path $Paths.ModelsRoot $model.filename) -Description "Default model path"
            Name = "model-$($model.filename)"
        }
    }

    foreach ($key in @("YOLO_MODEL_PATH", "GTSRB_MODEL_PATH")) {
        if (-not $EnvMap.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$EnvMap[$key])) {
            continue
        }

        $configuredPath = Resolve-DoctorContainedPath -RootPath $Paths.Root -Path (Join-Path $Paths.BackendRoot ([string]$EnvMap[$key])) -Description "$key model path"
        $filename = Split-Path -Leaf $configuredPath
        if (-not $manifestModelsByFilename.ContainsKey($filename)) {
            throw "$key points to '$filename', which is not declared in the bootstrap manifest."
        }

        if (@($targets | Where-Object { $_.Path -eq $configuredPath }).Count -eq 0) {
            $targets += [pscustomobject]@{
                ManifestModel = $manifestModelsByFilename[$filename]
                Path = $configuredPath
                Name = "model-$key"
            }
        }
    }

    return $targets
}

function Format-DoctorHumanOutput {
    param([Parameter(Mandatory = $true)][object[]]$Results)

    return (@($Results | ForEach-Object {
        "[{0}] {1}: {2}" -f $_.status, $_.name, $_.message
    }) -join [Environment]::NewLine)
}

function Format-DoctorJsonOutput {
    param([Parameter(Mandatory = $true)][object[]]$Results)

    return ($Results | ConvertTo-Json -Depth 6 -Compress)
}

function Get-DoctorFatalJsonMessage {
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    $message = [string]$ErrorRecord.Exception.Message
    $positionMessage = [string]$ErrorRecord.InvocationInfo.PositionMessage
    $scriptStackTrace = [string]$ErrorRecord.ScriptStackTrace
    if ($message.IndexOf("Device must be one of", [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        return "Device must be one of auto, gpu, or cpu."
    }

    if ($message.IndexOf("Doctor environment module", [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        return "Doctor environment module could not be loaded."
    }

    if ($message.IndexOf("manifest", [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        return "Bootstrap manifest could not be loaded or parsed."
    }

    if ($message.IndexOf("ConvertFrom-Json", [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        $positionMessage.IndexOf("bootstrap-manifest", [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        $scriptStackTrace.IndexOf("Read-BootstrapManifest", [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        return "Bootstrap manifest could not be loaded or parsed."
    }

    if ($message.IndexOf("ProjectRoot", [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        return "Project root is invalid."
    }

    return "Doctor setup failed."
}

function Get-DoctorProbeFailureMessage {
    param(
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)]$ErrorRecord
    )

    $message = [string]$ErrorRecord.Exception.Message
    switch ($Category) {
        "python" {
            if ($message.IndexOf("reparse point", [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                return "Python runtime path uses a reparse point."
            }
            if ($message.IndexOf("timed out", [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                return "Python runtime probe timed out."
            }
            return "Python runtime could not be validated."
        }
        "node" {
            if ($message.IndexOf("reparse point", [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                return "Node runtime path uses a reparse point."
            }
            if ($message.IndexOf("timed out", [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                return "Node runtime probe timed out."
            }
            return "Node runtime could not be validated."
        }
        "pip" {
            if ($message.IndexOf("timed out", [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                return "pip check timed out."
            }
            return "pip check could not be completed."
        }
        "torch" {
            if ($message.IndexOf("timed out", [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                return "torch inspection timed out."
            }
            return "torch inspection failed."
        }
        default {
            return "Doctor probe failed."
        }
    }
}

function Invoke-DoctorMain {
    param(
        [string]$Device = "auto",
        [string]$ProjectRoot
    )

    Assert-DoctorDeviceValue -Device $Device
    $resolvedRoot = Resolve-DoctorProjectRoot -ProjectRoot $ProjectRoot
    $paths = Resolve-DoctorPaths -RootPath $resolvedRoot
    $manifest = Read-BootstrapManifest -Path $paths.ManifestPath
    $results = New-Object System.Collections.Generic.List[object]

    foreach ($path in @($paths.ManifestPath, $paths.EnvPath, $paths.VenvRoot, $paths.FrontendLockPath, $paths.NodeModulesPath, $paths.ModelsRoot)) {
        if (Test-Path -LiteralPath $path) {
            Assert-DoctorNoReparsePointTraversal -RootPath $paths.Root -Path $path
        }
    }

    $systemFacts = Get-DoctorSystemFacts -ProjectRoot $resolvedRoot
    if ($systemFacts.IsWindows -and $systemFacts.Architecture -in @("x64", "amd64")) {
        $results.Add((New-DoctorCheckResult -Name "windows-x64" -Status "PASS" -Message "Windows x64 detected." -Required $true))
    } else {
        $results.Add((New-DoctorCheckResult -Name "windows-x64" -Status "FAIL" -Message "Windows x64 is required." -Required $true))
    }

    $requiredDiskGb = if ($Device -eq "gpu") { 12 } else { 6 }
    if ([int64]$systemFacts.FreeSpaceBytes -ge ([int64]$requiredDiskGb * 1GB)) {
        $results.Add((New-DoctorCheckResult -Name "disk-space" -Status "PASS" -Message "Disk space satisfies the $requiredDiskGb GB minimum." -Required $true))
    } else {
        $results.Add((New-DoctorCheckResult -Name "disk-space" -Status "FAIL" -Message "At least $requiredDiskGb GB of free space is required." -Required $true))
    }

    $pythonInfo = $null
    try {
        $pythonInfo = Get-DoctorPythonInfo -Paths $paths -Manifest $manifest
        $pythonStatus = if ($pythonInfo.Source -in @("project-local", "backend-venv")) { "PASS" } else { "WARN" }
        if ([string]$pythonInfo.Version -eq [string]$manifest.runtime.python.version) {
            $results.Add((New-DoctorCheckResult -Name "python-version" -Status $pythonStatus -Message "Python $($pythonInfo.Version) resolved from $($pythonInfo.Source)." -Required $true))
        } else {
            $results.Add((New-DoctorCheckResult -Name "python-version" -Status "FAIL" -Message "Python $($manifest.runtime.python.version) is required." -Required $true))
        }
    } catch {
        $results.Add((New-DoctorCheckResult -Name "python-version" -Status "FAIL" -Message (Get-DoctorProbeFailureMessage -Category "python" -ErrorRecord $_) -Required $true))
    }

    $nodeInfo = $null
    try {
        $nodeInfo = Get-DoctorNodeInfo -Paths $paths -Manifest $manifest
        $nodeStatus = if ($nodeInfo.Source -eq "project-local") { "PASS" } else { "WARN" }
        if ([string]$nodeInfo.Version -eq [string]$manifest.runtime.node.version) {
            $results.Add((New-DoctorCheckResult -Name "node-version" -Status $nodeStatus -Message "Node $($nodeInfo.Version) resolved from $($nodeInfo.Source)." -Required $true))
        } else {
            $results.Add((New-DoctorCheckResult -Name "node-version" -Status "FAIL" -Message "Node $($manifest.runtime.node.version) is required." -Required $true))
        }
    } catch {
        $results.Add((New-DoctorCheckResult -Name "node-version" -Status "FAIL" -Message (Get-DoctorProbeFailureMessage -Category "node" -ErrorRecord $_) -Required $true))
    }

    if (Test-Path -LiteralPath $paths.VenvPythonPath -PathType Leaf) {
        $results.Add((New-DoctorCheckResult -Name "backend-venv" -Status "PASS" -Message "backend/.venv Python is present." -Required $true))
    } else {
        $results.Add((New-DoctorCheckResult -Name "backend-venv" -Status "FAIL" -Message "backend/.venv Python is missing." -Required $true))
    }

    if ($null -ne $pythonInfo) {
        try {
            $pipCheck = Invoke-DoctorPipCheck -PythonPath $pythonInfo.Path -BackendRoot $paths.BackendRoot
            if ([int]$pipCheck.ExitCode -eq 0) {
                $results.Add((New-DoctorCheckResult -Name "pip-check" -Status "PASS" -Message "pip check passed." -Required $true))
            } else {
                $results.Add((New-DoctorCheckResult -Name "pip-check" -Status "FAIL" -Message "pip check failed." -Required $true))
            }
        } catch {
            $results.Add((New-DoctorCheckResult -Name "pip-check" -Status "FAIL" -Message (Get-DoctorProbeFailureMessage -Category "pip" -ErrorRecord $_) -Required $true))
        }
    } else {
        $results.Add((New-DoctorCheckResult -Name "pip-check" -Status "FAIL" -Message "pip check could not run because Python is unavailable." -Required $true))
    }

    $torchInfo = $null
    if ($null -ne $pythonInfo) {
        try {
            $torchInfo = Get-DoctorTorchInfo -PythonPath $pythonInfo.Path
            $torchVersion = [string]$torchInfo.Version
            $torchBuildStatus = "PASS"
            $torchBuildMessage = "torch build '$torchVersion' detected."
            $cudaStatus = "PASS"
            $cudaMessage = if ($torchInfo.CudaAvailable) { "CUDA is available." } else { "CUDA is not available." }

            switch ($Device) {
                "gpu" {
                    if ($torchVersion -notmatch '\+cu128$') {
                        $torchBuildStatus = "FAIL"
                        $torchBuildMessage = "GPU mode requires a torch +cu128 build."
                    }
                    if (-not $torchInfo.CudaAvailable) {
                        $cudaStatus = "FAIL"
                        $cudaMessage = "GPU mode requires CUDA availability."
                    }
                }
                "cpu" {
                    if ($torchVersion -match '\+cpu$') {
                        $torchBuildStatus = "PASS"
                        $torchBuildMessage = "CPU torch build '$torchVersion' detected."
                    } elseif ($torchVersion -match '\+cu\d+$') {
                        $torchBuildStatus = "WARN"
                        $torchBuildMessage = "CUDA torch build '$torchVersion' is usable for CPU inference but larger than a CPU-only wheel."
                    } else {
                        $torchBuildStatus = "FAIL"
                        $torchBuildMessage = "CPU mode requires a usable torch build."
                    }

                    if ($torchInfo.CudaAvailable) {
                        $cudaStatus = "WARN"
                        $cudaMessage = "CUDA is available; CPU inference remains usable."
                    }
                }
                default {
                    if ($torchVersion -match '\+cu128$' -and -not $torchInfo.CudaAvailable) {
                        $cudaStatus = "WARN"
                        $cudaMessage = "CUDA build detected, but CUDA is not currently available."
                    }
                }
            }

            $results.Add((New-DoctorCheckResult -Name "torch-build" -Status $torchBuildStatus -Message $torchBuildMessage -Required $true))
            $results.Add((New-DoctorCheckResult -Name "cuda-state" -Status $cudaStatus -Message $cudaMessage -Required $true))
            if ($Device -eq "auto") {
                $resolvedComputeDevice = if ($torchInfo.CudaAvailable) { "gpu" } else { "cpu" }
                $results.Add((New-DoctorCheckResult -Name "compute-device" -Status "PASS" -Message "Resolved compute device: $resolvedComputeDevice." -Required $true))
            }
        } catch {
            $results.Add((New-DoctorCheckResult -Name "torch-build" -Status "FAIL" -Message (Get-DoctorProbeFailureMessage -Category "torch" -ErrorRecord $_) -Required $true))
            $results.Add((New-DoctorCheckResult -Name "cuda-state" -Status "FAIL" -Message "CUDA state could not be determined." -Required $true))
            if ($Device -eq "auto") {
                $results.Add((New-DoctorCheckResult -Name "compute-device" -Status "FAIL" -Message "Compute device could not be resolved." -Required $true))
            }
        }
    } else {
        $results.Add((New-DoctorCheckResult -Name "torch-build" -Status "FAIL" -Message "torch inspection could not run because Python is unavailable." -Required $true))
        $results.Add((New-DoctorCheckResult -Name "cuda-state" -Status "FAIL" -Message "CUDA state could not be determined because Python is unavailable." -Required $true))
        if ($Device -eq "auto") {
            $results.Add((New-DoctorCheckResult -Name "compute-device" -Status "FAIL" -Message "Compute device could not be resolved because Python is unavailable." -Required $true))
        }
    }

    $frontendReady = (Test-Path -LiteralPath $paths.FrontendLockPath -PathType Leaf) -and (Test-Path -LiteralPath $paths.NodeModulesPath -PathType Container)
    if ($frontendReady) {
        $results.Add((New-DoctorCheckResult -Name "frontend-deps" -Status "PASS" -Message "Frontend lockfile and node_modules are present." -Required $true))
    } else {
        $results.Add((New-DoctorCheckResult -Name "frontend-deps" -Status "FAIL" -Message "Frontend package-lock.json and node_modules are required." -Required $true))
    }

    $envMap = $null
    try {
        if (-not (Test-Path -LiteralPath $paths.EnvPath -PathType Leaf)) {
            throw "backend/.env is missing."
        }

        $envMap = Read-DoctorEnvMap -Path $paths.EnvPath
        $envIssues = @()
        if ([string]$envMap["APP_MODE"] -ne "local") { $envIssues += "APP_MODE=local" }
        if (-not ([string]$envMap["DATABASE_URL"]).StartsWith("sqlite:///", [System.StringComparison]::OrdinalIgnoreCase)) { $envIssues += "sqlite DATABASE_URL" }
        if ([string]$envMap["REDIS_ENABLED"] -ne "false") { $envIssues += "REDIS_ENABLED=false" }
        if ([string]$envMap["MINIO_ENABLED"] -ne "false") { $envIssues += "MINIO_ENABLED=false" }
        if ([string]::IsNullOrWhiteSpace([string]$envMap["YOLO_MODEL_PATH"])) { $envIssues += "YOLO_MODEL_PATH" }
        if ([string]::IsNullOrWhiteSpace([string]$envMap["GTSRB_MODEL_PATH"])) { $envIssues += "GTSRB_MODEL_PATH" }
        $jwtSecret = [string]$envMap["JWT_SECRET_KEY"]
        if ([string]::IsNullOrWhiteSpace($jwtSecret) -or $jwtSecret -eq "generated-by-bootstrap") { $envIssues += "JWT_SECRET_KEY" }

        if ($envIssues.Count -eq 0) {
            $results.Add((New-DoctorCheckResult -Name "backend-env" -Status "PASS" -Message "backend/.env local configuration is present." -Required $true))
        } else {
            $results.Add((New-DoctorCheckResult -Name "backend-env" -Status "FAIL" -Message "backend/.env is missing required local settings." -Required $true))
        }
    } catch {
        $results.Add((New-DoctorCheckResult -Name "backend-env" -Status "FAIL" -Message "backend/.env local configuration could not be validated." -Required $true))
    }

    if ($null -ne $envMap) {
        try {
            $sqlitePath = Resolve-DoctorSqlitePath -EnvMap $envMap -Paths $paths
            $sqliteParent = Split-Path -Parent $sqlitePath
            if (Test-Path -LiteralPath $sqliteParent -PathType Container) {
                $results.Add((New-DoctorCheckResult -Name "sqlite-parent" -Status "PASS" -Message "SQLite parent directory exists." -Required $true))
            } else {
                $results.Add((New-DoctorCheckResult -Name "sqlite-parent" -Status "FAIL" -Message "SQLite parent directory is missing." -Required $true))
            }
        } catch {
            $results.Add((New-DoctorCheckResult -Name "sqlite-parent" -Status "FAIL" -Message "SQLite parent directory could not be validated." -Required $true))
        }
    } else {
        $results.Add((New-DoctorCheckResult -Name "sqlite-parent" -Status "FAIL" -Message "SQLite parent directory could not be validated because backend/.env is invalid." -Required $true))
    }

    if ($null -ne $envMap) {
        try {
            foreach ($target in @(Get-DoctorModelTargets -Manifest $manifest -EnvMap $envMap -Paths $paths)) {
                if (-not (Test-Path -LiteralPath $target.Path -PathType Leaf)) {
                    $results.Add((New-DoctorCheckResult -Name $target.Name -Status "FAIL" -Message "Required model file is missing." -Required $true))
                    continue
                }

                Assert-DoctorNoReparsePointTraversal -RootPath $paths.Root -Path $target.Path
                try {
                    Assert-FileHash -Path $target.Path -ExpectedSha256 $target.ManifestModel.sha256
                    $results.Add((New-DoctorCheckResult -Name $target.Name -Status "PASS" -Message "Model hash matches the bootstrap manifest." -Required $true))
                } catch {
                    $results.Add((New-DoctorCheckResult -Name $target.Name -Status "FAIL" -Message "Model hash does not match the bootstrap manifest." -Required $true))
                }
            }
        } catch {
            $results.Add((New-DoctorCheckResult -Name "configured-models" -Status "FAIL" -Message "Configured model paths could not be validated." -Required $true))
        }
    } else {
        $results.Add((New-DoctorCheckResult -Name "configured-models" -Status "FAIL" -Message "Model configuration could not be validated because backend/.env is invalid." -Required $true))
    }

    foreach ($portResult in @(Get-DoctorPortCheckResults)) {
        $results.Add($portResult)
    }

    $exitCode = if (@($results | Where-Object { $_.required -and $_.status -eq "FAIL" }).Count -gt 0) { 1 } else { 0 }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Results = $results.ToArray()
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($Json) {
        try {
            Import-DoctorEnvironment
            $result = Invoke-DoctorMain -Device $Device -ProjectRoot $ProjectRoot
            Write-Output (Format-DoctorJsonOutput -Results $result.Results)
            exit $result.ExitCode
        } catch {
            $fatalResult = New-DoctorCheckResult -Name "setup" -Status "FAIL" -Message (Get-DoctorFatalJsonMessage -ErrorRecord $_) -Required $true
            Write-Output (Format-DoctorJsonOutput -Results @($fatalResult))
            exit 1
        }
    } else {
        Import-DoctorEnvironment
        $result = Invoke-DoctorMain -Device $Device -ProjectRoot $ProjectRoot
        Write-Output (Format-DoctorHumanOutput -Results $result.Results)
        exit $result.ExitCode
    }
}
