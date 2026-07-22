[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet("auto", "gpu", "cpu")]
    [string]$Device = "auto",
    [switch]$SkipRuntimeDownload,
    [switch]$SkipModels,
    [switch]$ForceConfig,
    [switch]$Start,
    [switch]$PlanOnly,
    [string]$ProjectRoot,
    [string]$NvidiaSmiAvailable,
    [string]$OsArchitectureOverride,
    [Nullable[decimal]]$FreeSpaceGbOverride,
    [switch]$DisablePathRuntimeProbe
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$modulePath = Join-Path $PSScriptRoot "lib\ProjectEnvironment.psm1"
Import-Module $modulePath -Force

function Use-Tls12 {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
}

function ConvertTo-OptionalBoolean {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    switch ($Value.Trim().ToLowerInvariant()) {
        '$true' { return $true }
        'true' { return $true }
        '1' { return $true }
        '$false' { return $false }
        'false' { return $false }
        '0' { return $false }
        default {
            throw "NvidiaSmiAvailable override must be true or false."
        }
    }
}

function Resolve-StableRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $normalizedRoot = [System.IO.Path]::GetFullPath($RootPath).TrimEnd("\")
    $normalizedPath = [System.IO.Path]::GetFullPath($Path)
    if ($normalizedPath.Equals($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return "."
    }

    $relative = $normalizedPath.Substring($normalizedRoot.Length).TrimStart("\")
    return $relative.Replace("\", "/")
}

function Resolve-ContainedPath {
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

function Assert-NoReparsePointTraversal {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $resolvedRoot = Resolve-ContainedPath -RootPath $RootPath -Path $RootPath -Description "Project root"
    $resolvedPath = Resolve-ContainedPath -RootPath $RootPath -Path $Path -Description "Mutable target"

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

function Resolve-ProjectPaths {
    param([Parameter(Mandatory = $true)][string]$RootPath)

    $runtimeRoot = Resolve-ContainedPath -RootPath $RootPath -Path (Join-Path $RootPath ".runtime") -Description "Runtime root"
    $downloadsRoot = Resolve-ContainedPath -RootPath $RootPath -Path (Join-Path $runtimeRoot "downloads") -Description "Runtime downloads root"
    $pythonRoot = Resolve-ContainedPath -RootPath $RootPath -Path (Join-Path $runtimeRoot "python") -Description "Python runtime root"
    $nodeRoot = Resolve-ContainedPath -RootPath $RootPath -Path (Join-Path $runtimeRoot "node") -Description "Node runtime root"
    $nodeTempRoot = Resolve-ContainedPath -RootPath $RootPath -Path (Join-Path $runtimeRoot "tmp") -Description "Node temp root"
    $modelsRoot = Resolve-ContainedPath -RootPath $RootPath -Path (Join-Path $RootPath "models") -Description "Models root"
    $backendRoot = Resolve-ContainedPath -RootPath $RootPath -Path (Join-Path $RootPath "backend") -Description "Backend root"
    $frontendRoot = Resolve-ContainedPath -RootPath $RootPath -Path (Join-Path $RootPath "frontend") -Description "Frontend root"
    $venvRoot = Resolve-ContainedPath -RootPath $RootPath -Path (Join-Path $backendRoot ".venv") -Description "Virtual environment root"
    $envPath = Resolve-ContainedPath -RootPath $RootPath -Path (Join-Path $backendRoot ".env") -Description "Backend environment file"
    $manifestPath = Resolve-ContainedPath -RootPath $RootPath -Path (Join-Path $RootPath "scripts\config\bootstrap-manifest.json") -Description "Bootstrap manifest"
    $doctorPath = Resolve-ContainedPath -RootPath $RootPath -Path (Join-Path $RootPath "scripts\doctor.ps1") -Description "Doctor script"
    $startPath = Resolve-ContainedPath -RootPath $RootPath -Path (Join-Path $RootPath "scripts\start.ps1") -Description "Start script"

    return [pscustomobject]@{
        Root = $RootPath
        RuntimeRoot = $runtimeRoot
        DownloadsRoot = $downloadsRoot
        PythonRoot = $pythonRoot
        NodeRoot = $nodeRoot
        NodeTempRoot = $nodeTempRoot
        ModelsRoot = $modelsRoot
        BackendRoot = $backendRoot
        FrontendRoot = $frontendRoot
        VenvRoot = $venvRoot
        EnvPath = $envPath
        ManifestPath = $manifestPath
        DoctorPath = $doctorPath
        StartPath = $startPath
    }
}

function Assert-ProjectRoot {
    param([Parameter(Mandatory = $true)][string]$RootPath)

    if ([string]::IsNullOrWhiteSpace($RootPath)) {
        throw "ProjectRoot must not be empty."
    }

    $resolvedRoot = [System.IO.Path]::GetFullPath($RootPath)
    if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
        throw "ProjectRoot does not exist: $resolvedRoot"
    }

    return $resolvedRoot
}

function Assert-WindowsX64 {
    param([string]$ArchitectureOverride)

    $isWindows = $true
    $architecture = $null

    if ($PSBoundParameters.ContainsKey("ArchitectureOverride") -and -not [string]::IsNullOrWhiteSpace($ArchitectureOverride)) {
        $architecture = $ArchitectureOverride.Trim().ToLowerInvariant()
    } else {
        $isWindows = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
        $architecture = if ([System.Environment]::Is64BitOperatingSystem) { "x64" } else { "x86" }
    }

    if (-not $isWindows -or $architecture -notin @("x64", "amd64")) {
        throw "bootstrap-windows.ps1 requires Windows x64."
    }
}

function Get-FreeSpaceBytes {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Nullable[decimal]]$FreeSpaceOverrideGb
    )

    if ($PSBoundParameters.ContainsKey("FreeSpaceOverrideGb") -and $null -ne $FreeSpaceOverrideGb) {
        return [int64]([decimal]$FreeSpaceOverrideGb * 1GB)
    }

    $item = Get-Item -LiteralPath $RootPath -ErrorAction Stop
    if ($null -ne $item.PSDrive -and $item.PSDrive.Free -ge 0) {
        return [int64]$item.PSDrive.Free
    }

    $root = [System.IO.Path]::GetPathRoot($RootPath)
    $driveInfo = New-Object System.IO.DriveInfo($root)
    return [int64]$driveInfo.AvailableFreeSpace
}

function Assert-DiskRequirement {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$SelectedDevice,
        [Nullable[decimal]]$FreeSpaceOverrideGb
    )

    $requiredGb = if ($SelectedDevice -eq "gpu") { 12 } else { 6 }
    $availableBytes = Get-FreeSpaceBytes -RootPath $RootPath -FreeSpaceOverrideGb $FreeSpaceOverrideGb
    $requiredBytes = [int64]$requiredGb * 1GB
    if ($availableBytes -lt $requiredBytes) {
        throw "bootstrap-windows.ps1 requires at least $requiredGb GB free for $SelectedDevice mode."
    }
}

function Test-NvidiaSupport {
    param([AllowNull()]$AvailabilityOverride)

    if ($PSBoundParameters.ContainsKey("AvailabilityOverride") -and $null -ne $AvailabilityOverride) {
        return [bool]$AvailabilityOverride
    }

    return $null -ne (Get-Command "nvidia-smi.exe" -ErrorAction SilentlyContinue)
}

function Get-RequirementsPath {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Paths,
        [Parameter(Mandatory = $true)][string]$SelectedDevice
    )

    $requirementsPath = if ($SelectedDevice -eq "gpu") {
        Join-Path $Paths.BackendRoot "requirements-gpu.txt"
    } else {
        Join-Path $Paths.BackendRoot "requirements-cpu.txt"
    }

    return Resolve-ContainedPath -RootPath $Paths.Root -Path $requirementsPath -Description "Requirements file"
}

function Get-DefaultModels {
    param([Parameter(Mandatory = $true)]$Manifest)

    return @($Manifest.release.models | Where-Object {
        $purpose = [string]$_.purpose
        $purpose.Trim().ToLowerInvariant().StartsWith("default ")
    })
}

function New-DownloadPaths {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$DirectoryPath,
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $directory = Resolve-ContainedPath -RootPath $RootPath -Path $DirectoryPath -Description $Description
    $finalPath = Resolve-ContainedPath -RootPath $RootPath -Path (Join-Path $directory $FileName) -Description "$Description target"
    $partialPath = Resolve-ContainedPath -RootPath $RootPath -Path ($finalPath + ".partial") -Description "$Description partial target"

    return [pscustomobject]@{
        Directory = $directory
        FinalPath = $finalPath
        PartialPath = $partialPath
    }
}

function Remove-IfExists {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$RootPath
    )

    if ($PSBoundParameters.ContainsKey("RootPath")) {
        Assert-NoReparsePointTraversal -RootPath $RootPath -Path $Path
    }

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force -Recurse
    }
}

function Get-ValidatedCachedFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        Assert-FileHash -Path $Path -ExpectedSha256 $ExpectedSha256
        return $Path
    } catch {
        return $null
    }
}

function Invoke-DownloadWithHashValidation {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256,
        [Parameter(Mandatory = $true)][pscustomobject]$DownloadPaths
    )

    $uri = [System.Uri]$Url
    if (-not $uri.Scheme.Equals("https", [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Downloads must use HTTPS: $Url"
    }

    $cachedPath = Get-ValidatedCachedFile -Path $DownloadPaths.FinalPath -ExpectedSha256 $ExpectedSha256
    if ($null -ne $cachedPath) {
        return $cachedPath
    }

    Assert-NoReparsePointTraversal -RootPath $RootPath -Path $DownloadPaths.Directory
    Assert-NoReparsePointTraversal -RootPath $RootPath -Path $DownloadPaths.FinalPath
    Assert-NoReparsePointTraversal -RootPath $RootPath -Path $DownloadPaths.PartialPath
    Remove-IfExists -Path $DownloadPaths.PartialPath -RootPath $RootPath
    if (-not (Test-Path -LiteralPath $DownloadPaths.Directory -PathType Container)) {
        Assert-NoReparsePointTraversal -RootPath $RootPath -Path $DownloadPaths.Directory
        New-Item -ItemType Directory -Path $DownloadPaths.Directory -Force | Out-Null
    }

    $attemptCount = 3
    $lastError = $null

    for ($attempt = 1; $attempt -le $attemptCount; $attempt++) {
        try {
            Assert-NoReparsePointTraversal -RootPath $RootPath -Path $DownloadPaths.Directory
            Assert-NoReparsePointTraversal -RootPath $RootPath -Path $DownloadPaths.PartialPath
            Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $DownloadPaths.PartialPath -TimeoutSec 300 -ErrorAction Stop | Out-Null
            Assert-FileHash -Path $DownloadPaths.PartialPath -ExpectedSha256 $ExpectedSha256

            if (Test-Path -LiteralPath $DownloadPaths.FinalPath) {
                Assert-NoReparsePointTraversal -RootPath $RootPath -Path $DownloadPaths.FinalPath
                Remove-Item -LiteralPath $DownloadPaths.FinalPath -Force
            }

            Assert-NoReparsePointTraversal -RootPath $RootPath -Path $DownloadPaths.PartialPath
            Assert-NoReparsePointTraversal -RootPath $RootPath -Path $DownloadPaths.FinalPath
            Move-Item -LiteralPath $DownloadPaths.PartialPath -Destination $DownloadPaths.FinalPath -Force
            return $DownloadPaths.FinalPath
        } catch {
            $lastError = $_
            Remove-IfExists -Path $DownloadPaths.PartialPath -RootPath $RootPath
            if ($attempt -lt $attemptCount) {
                Start-Sleep -Seconds $attempt
            }
        }
    }

    throw "Failed to download '$Url' after $attemptCount attempts. $($lastError.Exception.Message)"
}

function Get-ExactPythonVersion {
    param([Parameter(Mandatory = $true)][string]$PythonPath)

    $command = "import sys; print('{0}.{1}.{2}'.format(sys.version_info[0], sys.version_info[1], sys.version_info[2]))"
    $result = Invoke-CheckedCommand -FilePath $PythonPath -ArgumentList @("-c", $command)
    return $result.StdOut.Trim()
}

function Get-PythonArchitecture {
    param([Parameter(Mandatory = $true)][string]$PythonPath)

    $command = "import struct; print(struct.calcsize('P') * 8)"
    $result = Invoke-CheckedCommand -FilePath $PythonPath -ArgumentList @("-c", $command)
    $architecture = 0
    if (-not [int]::TryParse($result.StdOut.Trim(), [ref]$architecture) -or $architecture -notin @(32, 64)) {
        throw "Python runtime at '$PythonPath' returned an invalid architecture."
    }
    return $architecture
}

function Get-ExactNodeVersion {
    param([Parameter(Mandatory = $true)][string]$NodePath)

    $result = Invoke-CheckedCommand -FilePath $NodePath -ArgumentList @("--version")
    return $result.StdOut.Trim().TrimStart("v")
}

function Test-NpmRuntime {
    param(
        [Parameter(Mandatory = $true)][string]$NpmPath,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )

    try {
        $result = Invoke-CheckedCommand -FilePath $NpmPath -ArgumentList @("--version") -WorkingDirectory $WorkingDirectory -TimeoutSeconds 30
        return -not [string]::IsNullOrWhiteSpace($result.StdOut)
    } catch {
        return $false
    }
}

function Install-PythonRuntimeAtomically {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Paths,
        [Parameter(Mandatory = $true)][string]$InstallerPath,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion,
        [scriptblock]$InstallerInvoker = {
            param($InstallerPath, $TargetDir)
            $installArguments = @(
                "/quiet",
                "InstallAllUsers=0",
                "PrependPath=0",
                "Include_launcher=0",
                "Include_test=0",
                "TargetDir=$TargetDir"
            )
            Invoke-CheckedCommand -FilePath $InstallerPath -ArgumentList $installArguments -TimeoutSeconds 900 | Out-Null
        },
        [scriptblock]$PythonVersionResolver = {
            param($PythonPath)
            Get-ExactPythonVersion -PythonPath $PythonPath
        }
    )

    Assert-NoReparsePointTraversal -RootPath $Paths.Root -Path $Paths.RuntimeRoot
    if (-not (Test-Path -LiteralPath $Paths.RuntimeRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $Paths.RuntimeRoot -Force | Out-Null
    }

    $stagingRoot = Resolve-ContainedPath -RootPath $Paths.Root -Path (Join-Path $Paths.RuntimeRoot ("python-stage-" + [System.Guid]::NewGuid().ToString("N"))) -Description "Python staging root"
    $backupRoot = Resolve-ContainedPath -RootPath $Paths.Root -Path (Join-Path $Paths.RuntimeRoot ("python-backup-" + [System.Guid]::NewGuid().ToString("N"))) -Description "Python backup root"
    Assert-NoReparsePointTraversal -RootPath $Paths.Root -Path $stagingRoot
    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null

    $backupCreated = $false
    $movedIntoTarget = $false

    try {
        & $InstallerInvoker $InstallerPath $stagingRoot

        $stagedPythonPath = Resolve-ContainedPath -RootPath $Paths.Root -Path (Join-Path $stagingRoot "python.exe") -Description "Staged Python executable"
        if (-not (Test-Path -LiteralPath $stagedPythonPath -PathType Leaf)) {
            throw "Python installation did not produce '$stagedPythonPath'."
        }

        $stagedVersion = & $PythonVersionResolver $stagedPythonPath
        if ($stagedVersion -ne $ExpectedVersion) {
            throw "Python version mismatch. Expected $ExpectedVersion but found $stagedVersion."
        }

        if (Test-Path -LiteralPath $Paths.PythonRoot -PathType Container) {
            Assert-NoReparsePointTraversal -RootPath $Paths.Root -Path $Paths.PythonRoot
            Move-Item -LiteralPath $Paths.PythonRoot -Destination $backupRoot
            $backupCreated = $true
        }

        Move-Item -LiteralPath $stagingRoot -Destination $Paths.PythonRoot
        $movedIntoTarget = $true

        $finalPythonPath = Resolve-ContainedPath -RootPath $Paths.Root -Path (Join-Path $Paths.PythonRoot "python.exe") -Description "Local Python executable"
        if (-not (Test-Path -LiteralPath $finalPythonPath -PathType Leaf)) {
            throw "Python installation did not produce '$finalPythonPath'."
        }

        $installedVersion = & $PythonVersionResolver $finalPythonPath
        if ($installedVersion -ne $ExpectedVersion) {
            throw "Python version mismatch. Expected $ExpectedVersion but found $installedVersion."
        }

        if ($backupCreated -and (Test-Path -LiteralPath $backupRoot -PathType Container)) {
            try {
                Remove-IfExists -Path $backupRoot -RootPath $Paths.Root
            } catch {
                Write-Warning "The new Python runtime is valid, but the previous runtime backup could not be removed from '$backupRoot': $($_.Exception.Message)"
            }
            $backupCreated = $false
        }

        return $finalPythonPath
    } catch {
        if ($movedIntoTarget -and (Test-Path -LiteralPath $Paths.PythonRoot -PathType Container)) {
            Remove-IfExists -Path $Paths.PythonRoot -RootPath $Paths.Root
        }

        if ($backupCreated -and (Test-Path -LiteralPath $backupRoot -PathType Container)) {
            Move-Item -LiteralPath $backupRoot -Destination $Paths.PythonRoot
        }

        throw
    } finally {
        if (Test-Path -LiteralPath $stagingRoot -PathType Container) {
            Remove-IfExists -Path $stagingRoot -RootPath $Paths.Root
        }

        if ($backupCreated -and (Test-Path -LiteralPath $backupRoot -PathType Container)) {
            Remove-IfExists -Path $backupRoot -RootPath $Paths.Root
        }
    }
}

function Install-NodeRuntimeAtomically {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Paths,
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion,
        [scriptblock]$NodeVersionResolver = {
            param($NodePath)
            Get-ExactNodeVersion -NodePath $NodePath
        }
    )

    Assert-NoReparsePointTraversal -RootPath $Paths.Root -Path $Paths.RuntimeRoot
    if (-not (Test-Path -LiteralPath $Paths.RuntimeRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $Paths.RuntimeRoot -Force | Out-Null
    }

    Assert-NoReparsePointTraversal -RootPath $Paths.Root -Path $Paths.NodeTempRoot
    if (-not (Test-Path -LiteralPath $Paths.NodeTempRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $Paths.NodeTempRoot -Force | Out-Null
    }

    $stagingRoot = Resolve-ContainedPath -RootPath $Paths.Root -Path (Join-Path $Paths.NodeTempRoot ("node-stage-" + [System.Guid]::NewGuid().ToString("N"))) -Description "Node staging root"
    $backupRoot = Resolve-ContainedPath -RootPath $Paths.Root -Path (Join-Path $Paths.RuntimeRoot ("node-backup-" + [System.Guid]::NewGuid().ToString("N"))) -Description "Node backup root"
    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null

    $backupCreated = $false
    $movedIntoTarget = $false
    $versionFolderName = "node-v$ExpectedVersion-win-x64"

    try {
        Expand-Archive -LiteralPath $ZipPath -DestinationPath $stagingRoot -Force
        $stagedNodeRoot = Resolve-ContainedPath -RootPath $Paths.Root -Path (Join-Path $stagingRoot $versionFolderName) -Description "Expanded Node runtime"
        if (-not (Test-Path -LiteralPath $stagedNodeRoot -PathType Container)) {
            throw "Node runtime archive did not contain '$versionFolderName'."
        }

        $stagedNodePath = Resolve-ContainedPath -RootPath $Paths.Root -Path (Join-Path $stagedNodeRoot "node.exe") -Description "Staged Node executable"
        $stagedNpmPath = Resolve-ContainedPath -RootPath $Paths.Root -Path (Join-Path $stagedNodeRoot "npm.cmd") -Description "Staged npm command"
        if (-not (Test-Path -LiteralPath $stagedNodePath -PathType Leaf)) {
            throw "Node installation did not produce '$stagedNodePath'."
        }

        if (-not (Test-Path -LiteralPath $stagedNpmPath -PathType Leaf)) {
            throw "Node installation did not produce '$stagedNpmPath'."
        }

        $stagedVersion = & $NodeVersionResolver $stagedNodePath
        if ($stagedVersion -ne $ExpectedVersion) {
            throw "Node version mismatch. Expected $ExpectedVersion but found $stagedVersion."
        }

        if (Test-Path -LiteralPath $Paths.NodeRoot -PathType Container) {
            Move-Item -LiteralPath $Paths.NodeRoot -Destination $backupRoot
            $backupCreated = $true
        }

        Move-Item -LiteralPath $stagedNodeRoot -Destination $Paths.NodeRoot
        $movedIntoTarget = $true

        $finalNodePath = Resolve-ContainedPath -RootPath $Paths.Root -Path (Join-Path $Paths.NodeRoot "node.exe") -Description "Local Node executable"
        $finalNpmPath = Resolve-ContainedPath -RootPath $Paths.Root -Path (Join-Path $Paths.NodeRoot "npm.cmd") -Description "Local npm command"
        if (-not (Test-Path -LiteralPath $finalNodePath -PathType Leaf)) {
            throw "Node installation did not produce '$finalNodePath'."
        }

        if (-not (Test-Path -LiteralPath $finalNpmPath -PathType Leaf)) {
            throw "Node installation did not produce '$finalNpmPath'."
        }

        $installedVersion = & $NodeVersionResolver $finalNodePath
        if ($installedVersion -ne $ExpectedVersion) {
            throw "Node version mismatch. Expected $ExpectedVersion but found $installedVersion."
        }

        if ($backupCreated -and (Test-Path -LiteralPath $backupRoot -PathType Container)) {
            Remove-IfExists -Path $backupRoot -RootPath $Paths.Root
        }

        return [pscustomobject]@{
            NodePath = $finalNodePath
            NpmPath = $finalNpmPath
        }
    } catch {
        if ($movedIntoTarget -and (Test-Path -LiteralPath $Paths.NodeRoot -PathType Container)) {
            Remove-IfExists -Path $Paths.NodeRoot -RootPath $Paths.Root
        }

        if ($backupCreated -and (Test-Path -LiteralPath $backupRoot -PathType Container)) {
            Move-Item -LiteralPath $backupRoot -Destination $Paths.NodeRoot
        }

        throw
    } finally {
        Remove-IfExists -Path $stagingRoot -RootPath $Paths.Root
        if ($backupCreated -and (Test-Path -LiteralPath $backupRoot -PathType Container)) {
            Remove-IfExists -Path $backupRoot -RootPath $Paths.Root
        }
    }
}

function Get-PythonCommandFromPath {
    param([switch]$DisableProbe)

    if ($DisableProbe) {
        return $null
    }

    $command = Get-Command "python.exe" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
        $command = Get-Command "python" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    }

    if ($null -eq $command) {
        return $null
    }

    return $command.Source
}

function Get-PythonCommandsFromRegistry {
    param(
        [switch]$DisableProbe,
        [scriptblock]$RegistryVersionKeyReader = {
            param($RegistryRoot)
            return @(Get-ChildItem -LiteralPath $RegistryRoot -ErrorAction Stop)
        },
        [scriptblock]$RegistryInstallPathReader = {
            param($VersionKey)

            $installPathKey = Join-Path $VersionKey.PSPath "InstallPath"
            $installItem = Get-Item -LiteralPath $installPathKey -ErrorAction Stop
            $installProperties = Get-ItemProperty -LiteralPath $installPathKey -ErrorAction Stop
            $registeredPaths = New-Object System.Collections.Generic.List[string]
            $executablePathProperty = $installProperties.PSObject.Properties["ExecutablePath"]
            if ($null -ne $executablePathProperty -and -not [string]::IsNullOrWhiteSpace([string]$executablePathProperty.Value)) {
                $registeredPaths.Add([string]$executablePathProperty.Value)
            }

            $installDirectory = [string]$installItem.GetValue("")
            if (-not [string]::IsNullOrWhiteSpace($installDirectory)) {
                $registeredPaths.Add((Join-Path $installDirectory "python.exe"))
            }
            return @($registeredPaths)
        }
    )

    if ($DisableProbe) {
        return @()
    }

    $registryRoots = @(
        "Registry::HKEY_CURRENT_USER\Software\Python\PythonCore",
        "Registry::HKEY_LOCAL_MACHINE\Software\Python\PythonCore",
        "Registry::HKEY_LOCAL_MACHINE\Software\WOW6432Node\Python\PythonCore"
    )
    $candidates = New-Object System.Collections.Generic.List[string]
    $seen = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($registryRoot in $registryRoots) {
        try {
            $versionKeys = @(& $RegistryVersionKeyReader $registryRoot)
        } catch {
            continue
        }

        foreach ($versionKey in $versionKeys) {
            try {
                $registeredPaths = @(& $RegistryInstallPathReader $versionKey)
            } catch {
                continue
            }

            foreach ($registeredPath in $registeredPaths) {
                try {
                    if ((Test-Path -LiteralPath $registeredPath -PathType Leaf -ErrorAction Stop) -and $seen.Add($registeredPath)) {
                        $candidates.Add($registeredPath)
                    }
                } catch {
                    continue
                }
            }
        }
    }

    return @($candidates)
}

function Find-CompatiblePythonRuntime {
    param(
        [Parameter(Mandatory = $true)][string]$ExpectedVersion,
        [switch]$DisableProbe
    )

    if ($DisableProbe) {
        return $null
    }

    $pathPython = Get-PythonCommandFromPath
    if (-not [string]::IsNullOrWhiteSpace([string]$pathPython)) {
        try {
            if (((Get-ExactPythonVersion -PythonPath $pathPython) -eq $ExpectedVersion) -and ((Get-PythonArchitecture -PythonPath $pathPython) -eq 64)) {
                return [string]$pathPython
            }
        } catch {
        }
    }

    try {
        $registeredCandidates = @(Get-PythonCommandsFromRegistry)
    } catch {
        $registeredCandidates = @()
    }

    $seen = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in $registeredCandidates) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
            continue
        }
        if (-not $seen.Add($candidate)) {
            continue
        }

        try {
            if (((Get-ExactPythonVersion -PythonPath $candidate) -eq $ExpectedVersion) -and ((Get-PythonArchitecture -PythonPath $candidate) -eq 64)) {
                return $candidate
            }
        } catch {
        }
    }

    return $null
}

function Get-NodeCommandFromPath {
    param([switch]$DisableProbe)

    if ($DisableProbe) {
        return $null
    }

    $command = Get-Command "node.exe" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
        $command = Get-Command "node" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    }

    if ($null -eq $command) {
        return $null
    }

    return $command.Source
}

function Get-NpmCommandFromPath {
    param([switch]$DisableProbe)

    if ($DisableProbe) {
        return $null
    }

    $command = Get-Command "npm.cmd" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
        return $null
    }

    return $command.Source
}

function Resolve-PythonRuntime {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Paths,
        [Parameter(Mandatory = $true)]$Manifest,
        [switch]$SkipDownload,
        [switch]$DisablePathProbe
    )

    $expectedVersion = [string]$Manifest.runtime.python.version
    $localPythonPath = Resolve-ContainedPath -RootPath $Paths.Root -Path (Join-Path $Paths.PythonRoot "python.exe") -Description "Local Python executable"

    if (Test-Path -LiteralPath $localPythonPath -PathType Leaf) {
        try {
            if ((Get-ExactPythonVersion -PythonPath $localPythonPath) -eq $expectedVersion) {
                return $localPythonPath
            }
        } catch {
        }
    }

    $externalPython = Find-CompatiblePythonRuntime -ExpectedVersion $expectedVersion -DisableProbe:$DisablePathProbe
    if ($null -ne $externalPython) {
        return $externalPython
    }

    if ($SkipDownload) {
        throw "SkipRuntimeDownload requires a compatible Python $expectedVersion runtime locally, on PATH, or in the CPython registry."
    }

    $downloadPaths = New-DownloadPaths -RootPath $Paths.Root -DirectoryPath $Paths.DownloadsRoot -FileName $Manifest.runtime.python.filename -Description "Python runtime download"
    $installerPath = Invoke-DownloadWithHashValidation -RootPath $Paths.Root -Url $Manifest.runtime.python.url -ExpectedSha256 $Manifest.runtime.python.sha256 -DownloadPaths $downloadPaths

    return Install-PythonRuntimeAtomically -Paths $Paths -InstallerPath $installerPath -ExpectedVersion $expectedVersion
}

function Resolve-NodeRuntime {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Paths,
        [Parameter(Mandatory = $true)]$Manifest,
        [switch]$SkipDownload,
        [switch]$DisablePathProbe
    )

    $expectedVersion = [string]$Manifest.runtime.node.version
    $localNodePath = Resolve-ContainedPath -RootPath $Paths.Root -Path (Join-Path $Paths.NodeRoot "node.exe") -Description "Local Node executable"
    $localNpmPath = Resolve-ContainedPath -RootPath $Paths.Root -Path (Join-Path $Paths.NodeRoot "npm.cmd") -Description "Local npm command"

    if ((Test-Path -LiteralPath $localNodePath -PathType Leaf) -and (Test-Path -LiteralPath $localNpmPath -PathType Leaf)) {
        try {
            if (((Get-ExactNodeVersion -NodePath $localNodePath) -eq $expectedVersion) -and (Test-NpmRuntime -NpmPath $localNpmPath -WorkingDirectory $Paths.Root)) {
                return [pscustomobject]@{
                    NodePath = $localNodePath
                    NpmPath = $localNpmPath
                }
            }
        } catch {
        }
    }

    if ($SkipDownload) {
        $pathNode = Get-NodeCommandFromPath -DisableProbe:$DisablePathProbe
        if ($null -ne $pathNode -and (Get-ExactNodeVersion -NodePath $pathNode) -eq $expectedVersion) {
            $nodeDirectory = Split-Path -Parent $pathNode
            $pathNpm = Join-Path $nodeDirectory "npm.cmd"
            if (-not (Test-Path -LiteralPath $pathNpm -PathType Leaf)) {
                throw "SkipRuntimeDownload requires node.exe and npm.cmd from the same directory. Resolved node.exe at '$pathNode' but npm.cmd was not found beside it."
            }
            if (-not (Test-NpmRuntime -NpmPath $pathNpm -WorkingDirectory $Paths.Root)) {
                throw "SkipRuntimeDownload found Node $expectedVersion at '$pathNode', but the sibling npm.cmd could not execute successfully."
            }
            return [pscustomobject]@{
                NodePath = $pathNode
                NpmPath = $pathNpm
            }
        }

        throw "SkipRuntimeDownload requires compatible Node $expectedVersion and npm runtimes locally or on PATH."
    }

    $downloadPaths = New-DownloadPaths -RootPath $Paths.Root -DirectoryPath $Paths.DownloadsRoot -FileName $Manifest.runtime.node.filename -Description "Node runtime download"
    $zipPath = Invoke-DownloadWithHashValidation -RootPath $Paths.Root -Url $Manifest.runtime.node.url -ExpectedSha256 $Manifest.runtime.node.sha256 -DownloadPaths $downloadPaths

    return Install-NodeRuntimeAtomically -Paths $Paths -ZipPath $zipPath -ExpectedVersion $expectedVersion
}

function Install-BackendPythonEnvironment {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Paths,
        [Parameter(Mandatory = $true)][string]$PythonPath,
        [Parameter(Mandatory = $true)][string]$RequestedDevice,
        [Parameter(Mandatory = $true)][string]$InitialDevice,
        [Parameter(Mandatory = $true)][string]$CpuRequirementsPath,
        [Parameter(Mandatory = $true)][string]$GpuRequirementsPath,
        [scriptblock]$VenvCreator = {
            param($InterpreterPath, $TargetPath)
            Invoke-CheckedCommand -FilePath $InterpreterPath -ArgumentList @("-m", "venv", $TargetPath) -TimeoutSeconds 300 | Out-Null
        },
        [scriptblock]$RequirementsInstaller = {
            param($VenvPythonPath, $RequirementsPath, $WorkingDirectory)
            Install-PythonRequirements -PythonPath $VenvPythonPath -RequirementsPath $RequirementsPath -WorkingDirectory $WorkingDirectory
        },
        [scriptblock]$CudaSelfTester = {
            param($VenvPythonPath)
            Test-TorchCudaAvailable -PythonPath $VenvPythonPath
        }
    )

    $backupRoot = Resolve-ContainedPath -RootPath $Paths.Root -Path (Join-Path $Paths.BackendRoot (".venv-backup-" + [System.Guid]::NewGuid().ToString("N"))) -Description "Virtual environment backup root"
    $backupCreated = $false
    $selectedDevice = $InitialDevice
    $requirementsPath = if ($InitialDevice -eq "gpu") { $GpuRequirementsPath } else { $CpuRequirementsPath }

    if (Test-Path -LiteralPath $Paths.VenvRoot -PathType Container) {
        Assert-NoReparsePointTraversal -RootPath $Paths.Root -Path $Paths.VenvRoot
        Move-Item -LiteralPath $Paths.VenvRoot -Destination $backupRoot
        $backupCreated = $true
    }

    try {
        Assert-NoReparsePointTraversal -RootPath $Paths.Root -Path $Paths.VenvRoot
        & $VenvCreator $PythonPath $Paths.VenvRoot
        $venvPythonPath = Resolve-ContainedPath -RootPath $Paths.Root -Path (Join-Path $Paths.VenvRoot "Scripts\python.exe") -Description "Virtual environment python"
        if (-not (Test-Path -LiteralPath $venvPythonPath -PathType Leaf)) {
            throw "Virtual environment creation did not produce '$venvPythonPath'."
        }

        & $RequirementsInstaller $venvPythonPath $requirementsPath $Paths.BackendRoot

        if ($InitialDevice -eq "gpu") {
            $cudaAvailable = & $CudaSelfTester $venvPythonPath
            if (-not $cudaAvailable) {
                if ($RequestedDevice -eq "auto") {
                    Remove-IfExists -Path $Paths.VenvRoot -RootPath $Paths.Root
                    & $VenvCreator $PythonPath $Paths.VenvRoot
                    $venvPythonPath = Resolve-ContainedPath -RootPath $Paths.Root -Path (Join-Path $Paths.VenvRoot "Scripts\python.exe") -Description "Virtual environment python"
                    if (-not (Test-Path -LiteralPath $venvPythonPath -PathType Leaf)) {
                        throw "Virtual environment creation did not produce '$venvPythonPath'."
                    }

                    $selectedDevice = "cpu"
                    $requirementsPath = $CpuRequirementsPath
                    & $RequirementsInstaller $venvPythonPath $requirementsPath $Paths.BackendRoot
                } else {
                    throw "GPU mode requires torch CUDA self-test to succeed."
                }
            }
        }

        $result = [pscustomobject]@{
            VenvPythonPath = $venvPythonPath
            SelectedDevice = $selectedDevice
            RequirementsPath = $requirementsPath
        }

        if ($backupCreated -and (Test-Path -LiteralPath $backupRoot -PathType Container)) {
            try {
                Remove-IfExists -Path $backupRoot -RootPath $Paths.Root
            } catch {
                Write-Warning "The new backend environment is valid, but the previous environment backup could not be removed from '$backupRoot': $($_.Exception.Message)"
            }
            $backupCreated = $false
        }

        return $result
    } catch {
        $installationError = $_.Exception
        $cleanupError = $null
        $restoreError = $null

        if (Test-Path -LiteralPath $Paths.VenvRoot -PathType Container) {
            try {
                Remove-IfExists -Path $Paths.VenvRoot -RootPath $Paths.Root
            } catch {
                $cleanupError = $_.Exception
            }
        }

        if ($backupCreated -and (Test-Path -LiteralPath $backupRoot -PathType Container)) {
            if (-not (Test-Path -LiteralPath $Paths.VenvRoot)) {
                try {
                    Move-Item -LiteralPath $backupRoot -Destination $Paths.VenvRoot
                    $backupCreated = $false
                } catch {
                    $restoreError = $_.Exception
                }
            }
        }

        if ($null -ne $cleanupError -or $null -ne $restoreError) {
            $details = New-Object System.Collections.Generic.List[string]
            $details.Add("Backend environment installation failed: $($installationError.Message)")
            if ($null -ne $cleanupError) {
                $details.Add("Partial environment cleanup failed: $($cleanupError.Message)")
            }
            if ($null -ne $restoreError) {
                $details.Add("Previous environment restore failed: $($restoreError.Message)")
            }
            if (Test-Path -LiteralPath $backupRoot -PathType Container) {
                $details.Add("The previous environment is preserved at '$backupRoot'.")
            }
            throw ($details -join " ")
        }

        throw $installationError
    }
}

function Install-PythonRequirements {
    param(
        [Parameter(Mandatory = $true)][string]$PythonPath,
        [Parameter(Mandatory = $true)][string]$RequirementsPath,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )

    Invoke-CheckedCommand -FilePath $PythonPath -ArgumentList @("-m", "pip", "install", "--upgrade", "pip==26.1.2", "setuptools==81.0.0") -WorkingDirectory $WorkingDirectory -TimeoutSeconds 600 | Out-Null
    Invoke-CheckedCommand -FilePath $PythonPath -ArgumentList @("-m", "pip", "install", "-r", $RequirementsPath) -WorkingDirectory $WorkingDirectory -TimeoutSeconds 3600 | Out-Null
    Invoke-CheckedCommand -FilePath $PythonPath -ArgumentList @("-m", "pip", "check") -WorkingDirectory $WorkingDirectory -TimeoutSeconds 300 | Out-Null
}

function Test-TorchCudaAvailable {
    param([Parameter(Mandatory = $true)][string]$PythonPath)

    $command = "import torch; print('true' if torch.cuda.is_available() else 'false')"
    $result = Invoke-CheckedCommand -FilePath $PythonPath -ArgumentList @("-c", $command) -TimeoutSeconds 120
    return $result.StdOut.Trim().ToLowerInvariant() -eq "true"
}

function Invoke-NpmInstall {
    param(
        [Parameter(Mandatory = $true)][string]$NpmPath,
        [Parameter(Mandatory = $true)][string]$FrontendRoot
    )

    Invoke-CheckedCommand -FilePath $NpmPath -ArgumentList @("ci") -WorkingDirectory $FrontendRoot -TimeoutSeconds 1800 | Out-Null
}

function Ensure-ModelFiles {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Paths,
        [Parameter(Mandatory = $true)]$Models
    )

    foreach ($model in @($Models)) {
        Assert-NoReparsePointTraversal -RootPath $Paths.Root -Path $Paths.ModelsRoot
        $downloadPaths = New-DownloadPaths -RootPath $Paths.Root -DirectoryPath $Paths.ModelsRoot -FileName $model.filename -Description "Model download"
        Invoke-DownloadWithHashValidation -RootPath $Paths.Root -Url $model.url -ExpectedSha256 $model.sha256 -DownloadPaths $downloadPaths | Out-Null
    }
}

function Ensure-EnvFile {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Paths,
        [Parameter(Mandatory = $true)][string]$SelectedDevice,
        [switch]$Force
    )

    if ((Test-Path -LiteralPath $Paths.EnvPath -PathType Leaf) -and -not $Force) {
        return
    }

    $parent = Split-Path -Parent $Paths.EnvPath
    Assert-NoReparsePointTraversal -RootPath $Paths.Root -Path $Paths.EnvPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $content = New-LocalEnvContent -JwtSecretKey (New-SecureToken) -YoloDevice $SelectedDevice -GtsrbDevice $SelectedDevice
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Paths.EnvPath, $content, $utf8NoBom)
}

function Ensure-LocalDataDirectory {
    param([Parameter(Mandatory = $true)][pscustomobject]$Paths)

    $dataPath = Resolve-ContainedPath -RootPath $Paths.Root -Path (Join-Path $Paths.BackendRoot "data") -Description "Local backend data directory"
    Assert-NoReparsePointTraversal -RootPath $Paths.Root -Path $dataPath
    if (-not (Test-Path -LiteralPath $dataPath -PathType Container)) {
        New-Item -ItemType Directory -Path $dataPath -Force | Out-Null
    }
}

function Invoke-OptionalScript {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 300
    )

    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        return
    }

    $powershellPath = Join-Path $PSHOME "powershell.exe"
    Invoke-CheckedCommand -FilePath $powershellPath -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $ScriptPath
    ) -WorkingDirectory $ProjectRoot -TimeoutSeconds $TimeoutSeconds | Out-Null
}

function New-Plan {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Paths,
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$RequestedDevice,
        [Parameter(Mandatory = $true)][string]$SelectedDevice,
        [Parameter(Mandatory = $true)][string]$RequirementsPath,
        [switch]$SkipModelsRequested,
        [switch]$ForceConfigRequested,
        [switch]$StartRequested,
        [switch]$SkipRuntimeDownloadRequested,
        [switch]$PlanMode
    )

    $defaultModels = if ($SkipModelsRequested) { @() } else { @(Get-DefaultModels -Manifest $Manifest) }
    $configAction = if ($ForceConfigRequested) { "replace" } else { "create-if-missing" }
    $runtimeStrategy = if ($SkipRuntimeDownloadRequested) { "reuse-compatible-local-or-path" } else { "reuse-or-download-install" }

    return [ordered]@{
        planOnly = [bool]$PlanMode
        projectRoot = $Paths.Root
        requestedDevice = $RequestedDevice
        selectedDevice = $SelectedDevice
        runtime = [ordered]@{
            strategy = $runtimeStrategy
            python = [ordered]@{
                version = [string]$Manifest.runtime.python.version
                targetPath = ".runtime/python/python.exe"
            }
            node = [ordered]@{
                version = [string]$Manifest.runtime.node.version
                targetPath = ".runtime/node/node.exe"
                npmPath = ".runtime/node/npm.cmd"
            }
        }
        requirementsFile = Resolve-StableRelativePath -RootPath $Paths.Root -Path $RequirementsPath
        frontend = [ordered]@{
            workingDirectory = Resolve-StableRelativePath -RootPath $Paths.Root -Path $Paths.FrontendRoot
            installCommand = "npm ci"
        }
        models = @($defaultModels | ForEach-Object {
            [ordered]@{
                filename = [string]$_.filename
                url = [string]$_.url
            }
        })
        config = [ordered]@{
            action = $configAction
            path = Resolve-StableRelativePath -RootPath $Paths.Root -Path $Paths.EnvPath
        }
        doctor = [ordered]@{
            action = "run-if-present"
            script = Resolve-StableRelativePath -RootPath $Paths.Root -Path $Paths.DoctorPath
        }
        start = [ordered]@{
            enabled = [bool]$StartRequested
            action = if ($StartRequested) { "run-after-doctor-if-present" } else { "not-requested" }
            script = Resolve-StableRelativePath -RootPath $Paths.Root -Path $Paths.StartPath
        }
    }
}

function Invoke-BootstrapWorkflow {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidateSet("auto", "gpu", "cpu")]
        [string]$Device = "auto",
        [switch]$SkipRuntimeDownload,
        [switch]$SkipModels,
        [switch]$ForceConfig,
        [switch]$Start,
        [switch]$PlanOnly,
        [string]$ProjectRoot,
        [string]$NvidiaSmiAvailable,
        [string]$OsArchitectureOverride,
        [Nullable[decimal]]$FreeSpaceGbOverride,
        [switch]$DisablePathRuntimeProbe
    )

    Use-Tls12
    if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
        $ProjectRoot = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $PSCommandPath) ".."))
    }

    $resolvedProjectRoot = Assert-ProjectRoot -RootPath $ProjectRoot
    $paths = Resolve-ProjectPaths -RootPath $resolvedProjectRoot
    $manifest = Read-BootstrapManifest -Path $paths.ManifestPath
    $hasNvidia = Test-NvidiaSupport -AvailabilityOverride (ConvertTo-OptionalBoolean -Value $NvidiaSmiAvailable)
    $requestedDevice = $Device.Trim().ToLowerInvariant()
    $selectedDevice = Resolve-DeviceMode -RequestedMode $requestedDevice -HasNvidia $hasNvidia

    Assert-WindowsX64 -ArchitectureOverride $OsArchitectureOverride
    Assert-DiskRequirement -RootPath $resolvedProjectRoot -SelectedDevice $selectedDevice -FreeSpaceOverrideGb $FreeSpaceGbOverride

    $requirementsPath = Get-RequirementsPath -Paths $paths -SelectedDevice $selectedDevice
    $planMode = [bool]($PlanOnly -or $WhatIfPreference)
    $plan = New-Plan -Paths $paths -Manifest $manifest -RequestedDevice $requestedDevice -SelectedDevice $selectedDevice -RequirementsPath $requirementsPath -SkipModelsRequested:$SkipModels -ForceConfigRequested:$ForceConfig -StartRequested:$Start -SkipRuntimeDownloadRequested:$SkipRuntimeDownload -PlanMode:$planMode

    $shouldExecute = if ($WhatIfPreference) {
        $false
    } else {
        $PSCmdlet.ShouldProcess($resolvedProjectRoot, "Bootstrap Windows project")
    }

    if ($PlanOnly -or -not $shouldExecute) {
        return [pscustomobject]@{
            Plan = $plan
            PlanOnly = $true
        }
    }

    $pythonPath = Resolve-PythonRuntime -Paths $paths -Manifest $manifest -SkipDownload:$SkipRuntimeDownload -DisablePathProbe:$DisablePathRuntimeProbe
    $nodeRuntime = Resolve-NodeRuntime -Paths $paths -Manifest $manifest -SkipDownload:$SkipRuntimeDownload -DisablePathProbe:$DisablePathRuntimeProbe
    $backendEnvironment = Install-BackendPythonEnvironment -Paths $paths -PythonPath $pythonPath -RequestedDevice $requestedDevice -InitialDevice $selectedDevice -CpuRequirementsPath (Join-Path $paths.BackendRoot "requirements-cpu.txt") -GpuRequirementsPath (Join-Path $paths.BackendRoot "requirements-gpu.txt")
    $selectedDevice = $backendEnvironment.SelectedDevice

    Invoke-NpmInstall -NpmPath $nodeRuntime.NpmPath -FrontendRoot $paths.FrontendRoot

    if (-not $SkipModels) {
        Ensure-ModelFiles -Paths $paths -Models (Get-DefaultModels -Manifest $manifest)
    }

    Ensure-EnvFile -Paths $paths -SelectedDevice $selectedDevice -Force:$ForceConfig
    Ensure-LocalDataDirectory -Paths $paths
    Invoke-OptionalScript -ScriptPath $paths.DoctorPath -ProjectRoot $paths.Root
    if ($Start) {
        Invoke-OptionalScript -ScriptPath $paths.StartPath -ProjectRoot $paths.Root
    }

    return [pscustomobject]@{
        Plan = $plan
        PlanOnly = $false
        SelectedDevice = $selectedDevice
    }
}

if ($MyInvocation.InvocationName -ne ".") {
    try {
        $workflowResult = Invoke-BootstrapWorkflow -Device $Device -SkipRuntimeDownload:$SkipRuntimeDownload -SkipModels:$SkipModels -ForceConfig:$ForceConfig -Start:$Start -PlanOnly:$PlanOnly -ProjectRoot $ProjectRoot -NvidiaSmiAvailable $NvidiaSmiAvailable -OsArchitectureOverride $OsArchitectureOverride -FreeSpaceGbOverride $FreeSpaceGbOverride -DisablePathRuntimeProbe:$DisablePathRuntimeProbe
        if ($workflowResult.PlanOnly) {
            $workflowResult.Plan | ConvertTo-Json -Depth 6
            exit 0
        }

        exit 0
    } catch {
        [Console]::Error.WriteLine($_.Exception.Message)
        exit 1
    }
}
